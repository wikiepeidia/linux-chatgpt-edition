#!/bin/sh
set -eu

export LC_ALL=C
umask 077

[ "$#" -eq 7 ] || { printf '%s\n' 'DEADLINE_INSPECTION_USAGE: expected iso hash bytes tool-evidence json layout' >&2; exit 64; }
iso=$1
expected_sha=$2
expected_bytes=$3
tool_evidence=$4
output_json=$5
output_layout=$6
unused_guard=$7

# The final two fixed output names deliberately expose the atomic filenames.
case "$output_json" in */deadline-inspection.json) ;; *) printf '%s\n' 'DEADLINE_INSPECTION_OUTPUT_INVALID: deadline-inspection.json required' >&2; exit 65 ;; esac
case "$output_layout" in */boot-layout.txt) ;; *) printf '%s\n' 'DEADLINE_INSPECTION_OUTPUT_INVALID: boot-layout.txt required' >&2; exit 65 ;; esac
[ "$unused_guard" = deadline-fast-structural ] || { printf '%s\n' 'DEADLINE_INSPECTION_SCOPE_INVALID' >&2; exit 65; }

fail() {
    code=$1
    shift
    printf '%s: %s\n' "$code" "$*" >&2
    exit 1
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
file_bytes() { stat -c '%s' "$1"; }
require_file() { [ -f "$1" ] && [ -s "$1" ] || fail DEADLINE_INSPECTION_FILE_MISSING "required file is absent or empty"; }

evidence_value() {
    field=$1
    awk -v object='"format": "iso"' -v wanted="\"$field\"" '
        index($0, object) { inside=1 }
        inside && index($0, wanted) {
            line=$0; sub(/^[^:]*:[[:space:]]*/, "", line); sub(/[[:space:]]*,?[[:space:]]*$/, "", line); gsub(/^"|"$/, "", line); print line; exit
        }
        inside && /^[[:space:]]*}[,]?[[:space:]]*$/ { exit }
    ' "$tool_evidence"
}

assert_xorriso_stderr() {
    log=$1
    label=$2
    banner=$(evidence_value stderr_banner)
    framing=$(evidence_value stderr_banner_framing)
    bytes=$(evidence_value stderr_banner_bytes)
    hash=$(evidence_value stderr_banner_sha256)
    [ "$framing" = lf-lf ] || fail DEADLINE_XORRISO_IDENTITY_INVALID "$label framing changed"
    expected=$log.expected
    printf '%s\n\n' "$banner" > "$expected"
    [ "$(file_bytes "$expected")" = "$bytes" ] || fail DEADLINE_XORRISO_IDENTITY_INVALID "$label banner bytes changed"
    [ "$(sha256_file "$expected")" = "$hash" ] || fail DEADLINE_XORRISO_IDENTITY_INVALID "$label banner hash changed"
    [ ! -s "$log" ] || cmp "$log" "$expected" >/dev/null || fail DEADLINE_XORRISO_STDERR_INVALID "$label emitted unexpected stderr"
}

run_xorriso() {
    label=$1
    output=$2
    shift 2
    errors=$output.stderr
    status=0
    /usr/bin/xorriso -report_about WARNING -indev "$iso" "$@" > "$output" 2> "$errors" || status=$?
    assert_xorriso_stderr "$errors" "$label"
    [ "$status" -eq 0 ] || fail DEADLINE_XORRISO_FAILED "$label failed"
    [ -s "$output" ] || fail DEADLINE_XORRISO_EMPTY "$label returned no evidence"
}

require_file "$iso"
require_file "$tool_evidence"
case "$expected_sha" in *[!0-9a-f]*|'') fail DEADLINE_ISO_HASH_INVALID "expected ISO hash is malformed" ;; esac
[ "${#expected_sha}" -eq 64 ] || fail DEADLINE_ISO_HASH_INVALID "expected ISO hash length is invalid"
case "$expected_bytes" in ''|0|*[!0-9]*) fail DEADLINE_ISO_BYTES_INVALID "expected ISO byte count is invalid" ;; esac
[ "$(sha256_file "$iso")" = "$expected_sha" ] || fail DEADLINE_ISO_HASH_MISMATCH "ISO hash changed before inspection"
[ "$(file_bytes "$iso")" = "$expected_bytes" ] || fail DEADLINE_ISO_BYTES_MISMATCH "ISO byte count changed before inspection"

work=${TMPDIR:-/tmp}/300k-deadline-inspection.$$
mkdir -m 0700 "$work"
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
listing=$work/iso-list.txt
plain=$work/el-torito-plain.txt
mkisofs=$work/el-torito-mkisofs.txt
pvd=$work/pvd.txt
system=$work/system-area.txt
run_xorriso iso-list "$listing" -find / -exec lsdl
run_xorriso el-torito-plain "$plain" -report_el_torito plain
run_xorriso el-torito-mkisofs "$mkisofs" -report_el_torito as_mkisofs
run_xorriso pvd "$pvd" -pvd_info
run_xorriso system-area "$system" -report_system_area plain

for required_path in \
    /boot/vmlinuz-virt \
    /boot/initramfs-virt \
    /300k.apkovl.tar.gz \
    /apks/x86_64/APKINDEX.tar.gz \
    /boot/syslinux/isolinux.bin \
    /efi/boot/bootx64.efi
do
    count=$(grep -F " '$required_path'" "$listing" | grep -c '^-' || true)
    [ "$count" -eq 1 ] || fail DEADLINE_ISO_PATH_MISSING "$required_path is absent, duplicated, or not regular"
done
grep -F " '/boot/syslinux/boot.cat'" "$listing" >/dev/null || fail DEADLINE_BIOS_CATALOG_MISSING "/boot/syslinux/boot.cat is absent"
grep -F 'El Torito cat path : /boot/syslinux/boot.cat' "$plain" >/dev/null || fail DEADLINE_BIOS_RECORD_MISSING "BIOS catalog record is absent"
grep -E 'El Torito boot img :[[:space:]]+1[[:space:]]+BIOS[[:space:]]+y' "$plain" >/dev/null || fail DEADLINE_BIOS_RECORD_MISSING "bootable BIOS record is absent"
grep -E 'El Torito boot img :[[:space:]]+2[[:space:]]+UEFI[[:space:]]+y' "$plain" >/dev/null || fail DEADLINE_UEFI_RECORD_MISSING "bootable UEFI structural record is absent"
grep -F 'El Torito img path :   1  /boot/syslinux/isolinux.bin' "$plain" >/dev/null || fail DEADLINE_BIOS_LOADER_MISSING "BIOS loader record is absent"
grep -F 'El Torito img path :   2  /boot/grub/efi.img' "$plain" >/dev/null || fail DEADLINE_UEFI_IMAGE_MISSING "/boot/grub/efi.img record is absent"
grep -F -- "-c '/boot/syslinux/boot.cat'" "$mkisofs" >/dev/null || fail DEADLINE_BIOS_CATALOG_MISSING "mkisofs BIOS catalog option is absent"
grep -F -- "-b '/boot/syslinux/isolinux.bin'" "$mkisofs" >/dev/null || fail DEADLINE_BIOS_LOADER_MISSING "mkisofs BIOS loader option is absent"
grep -F -- "-e '/boot/grub/efi.img'" "$mkisofs" >/dev/null || fail DEADLINE_UEFI_IMAGE_MISSING "mkisofs UEFI image option is absent"

layout_partial=$output_layout.partial
: > "$layout_partial"
cat "$pvd" "$plain" "$mkisofs" "$system" >> "$layout_partial"
[ -s "$layout_partial" ] || fail DEADLINE_LAYOUT_EMPTY "boot layout evidence is empty"

# Atomic result path: deadline-inspection.json.partial -> deadline-inspection.json.
json_partial=$output_json.partial
cat > "$json_partial" <<EOF
{
  "schema": "DeadlineIsoInspection",
  "schema_version": 1,
  "scope": "deadline-fast-structural",
  "iso_sha256": "$expected_sha",
  "iso_bytes": $expected_bytes,
  "required_paths": [
    "/boot/vmlinuz-virt",
    "/boot/initramfs-virt",
    "/300k.apkovl.tar.gz",
    "/apks/x86_64/APKINDEX.tar.gz",
    "/boot/syslinux/isolinux.bin",
    "/efi/boot/bootx64.efi"
  ],
  "bios": {"catalog": "/boot/syslinux/boot.cat", "loader": "/boot/syslinux/isolinux.bin", "bootable": true},
  "uefi": {"image": "/boot/grub/efi.img", "loader": "/efi/boot/bootx64.efi", "structural_bootable": true},
  "recursive_content_audit": "not-executed",
  "runtime_uefi_boot": "not-executed",
  "result": "pass"
}
EOF
[ "$(sha256_file "$iso")" = "$expected_sha" ] || fail DEADLINE_ISO_HASH_MISMATCH "ISO hash changed during inspection"
[ "$(file_bytes "$iso")" = "$expected_bytes" ] || fail DEADLINE_ISO_BYTES_MISMATCH "ISO byte count changed during inspection"
mv "$layout_partial" "$output_layout"
mv "$json_partial" "$output_json"
