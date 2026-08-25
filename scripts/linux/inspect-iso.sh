#!/bin/sh
set -efu

export LC_ALL=C
export LANG=C
umask 077

MODE=${1:-}
INPUTS_FILE=/workspace/builder/inputs.json
TOOL_EVIDENCE=/work/inspection-commands.json.items
TRUSTED_KEYS=/work/trusted-keys.sha256
OWNED_ROOT=
AUDIT_OUTPUT=
AUDIT_COMMITTED=0

fail() {
    code=$1
    shift
    printf '%s: %s\n' "$code" "$*" >&2
    exit 1
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$AUDIT_COMMITTED" -ne 1 ] && [ -n "$AUDIT_OUTPUT" ]; then
        rm -f -- "$AUDIT_OUTPUT" "$AUDIT_OUTPUT.partial" 2>/dev/null || true
    fi
    if [ -n "$OWNED_ROOT" ] && [ -d "$OWNED_ROOT" ] && [ ! -L "$OWNED_ROOT" ]; then
        case "$OWNED_ROOT" in
            /work/*|/tmp/*) rm -rf -- "$OWNED_ROOT" ;;
            *) printf '%s\n' 'INSPECTION_CLEANUP_REFUSED: scratch root is outside the approved runtime roots' >&2 ;;
        esac
    fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

require_regular() {
    [ -f "$1" ] || fail INSPECTION_INPUT_MISSING "required regular file is absent"
    [ ! -L "$1" ] || fail INSPECTION_INPUT_LINK "required input may not be a link"
    [ -s "$1" ] || fail INSPECTION_INPUT_EMPTY "required input is empty"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

file_bytes() {
    stat -c '%s' "$1"
}

json_scalar() {
    key=$1
    file=$2
    awk -v wanted="\"$key\"" '
        index($0, wanted) {
            line=$0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]*,?[[:space:]]*$/, "", line)
            gsub(/^"|"$/, "", line)
            print line
            exit
        }
    ' "$file"
}

tool_field() {
    format=$1
    field=$2
    awk -v object="\"$format\"" -v wanted="\"$field\"" '
        index($0, object) && /[{][[:space:]]*$/ { inside=1; next }
        inside && /^[[:space:]]*}[,]?[[:space:]]*$/ { exit }
        inside && index($0, wanted) {
            line=$0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]*,?[[:space:]]*$/, "", line)
            gsub(/^"|"$/, "", line)
            print line
            exit
        }
    ' "$INPUTS_FILE"
}

evidence_field() {
    format=$1
    field=$2
    awk -v object="\"format\": \"$format\"" -v wanted="\"$field\"" '
        index($0, object) { inside=1 }
        inside && index($0, wanted) {
            line=$0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]*,?[[:space:]]*$/, "", line)
            gsub(/^"|"$/, "", line)
            print line
            exit
        }
        inside && /^[[:space:]]*}[,]?[[:space:]]*$/ { exit }
    ' "$TOOL_EVIDENCE"
}

prepare_owned_root() {
    requested=$1
    [ -n "$requested" ] || fail INSPECTION_SCRATCH_INVALID "scratch path is empty"
    case "$requested" in /work/*|/tmp/*) ;; *) fail INSPECTION_SCRATCH_INVALID "scratch must be below /work or /tmp" ;; esac
    [ ! -e "$requested" ] && [ ! -L "$requested" ] || fail INSPECTION_SCRATCH_EXISTS "scratch path already exists"
    parent=${requested%/*}
    [ -n "$parent" ] || parent=/
    [ -d "$parent" ] && [ ! -L "$parent" ] || fail INSPECTION_SCRATCH_PARENT_INVALID "scratch parent is not an owned real directory"
    mkdir -m 0700 -- "$requested" || fail INSPECTION_SCRATCH_CREATE_FAILED "fresh scratch root could not be created"
    canonical_parent=$(cd "$parent" && pwd -P)
    base=${requested##*/}
    OWNED_ROOT=$canonical_parent/$base
    [ -d "$OWNED_ROOT" ] && [ ! -L "$OWNED_ROOT" ] || fail INSPECTION_SCRATCH_CREATE_FAILED "scratch root canonicalization failed"
    STATE_FILE=$OWNED_ROOT/counters
    printf '%s\n' \
        'members=0' \
        'regular_files=0' \
        'containers=0' \
        'expanded_bytes=0' \
        'materializations=0' \
        'observed_depth=0' > "$STATE_FILE"
}

counter_get() {
    key=$1
    sed -n "s/^$key=//p" "$STATE_FILE"
}

counter_set() {
    key=$1
    value=$2
    awk -F= -v wanted="$key" -v replacement="$value" '
        $1 == wanted { print wanted "=" replacement; next }
        { print }
    ' "$STATE_FILE" > "$STATE_FILE.partial"
    mv "$STATE_FILE.partial" "$STATE_FILE"
}

load_policy() {
    require_regular "$INPUTS_FILE"
    MAX_DEPTH=$(json_scalar max_depth "$INPUTS_FILE")
    MAX_MEMBERS=$(json_scalar max_members "$INPUTS_FILE")
    MAX_PATH_BYTES=$(json_scalar max_path_bytes "$INPUTS_FILE")
    MAX_FILE_BYTES=$(json_scalar max_file_bytes "$INPUTS_FILE")
    MAX_TOTAL_EXPANDED_BYTES=$(json_scalar max_total_expanded_bytes "$INPUTS_FILE")
    case "$MAX_DEPTH:$MAX_MEMBERS:$MAX_PATH_BYTES:$MAX_FILE_BYTES:$MAX_TOTAL_EXPANDED_BYTES" in
        *[!0-9:]*|'') fail INSPECTION_POLICY_INVALID "inspection limits must be positive decimal integers" ;;
    esac
    [ "$MAX_DEPTH" -ge 8 ] || fail INSPECTION_POLICY_WEAK "maximum depth is weaker than 8"
    [ "$MAX_MEMBERS" -ge 200000 ] || fail INSPECTION_POLICY_WEAK "member budget is weaker than 200000"
    [ "$MAX_PATH_BYTES" -ge 4096 ] || fail INSPECTION_POLICY_WEAK "path budget is weaker than 4096"
    [ "$MAX_FILE_BYTES" -ge 1073741824 ] || fail INSPECTION_POLICY_WEAK "single-file budget is weaker than 1 GiB"
    [ "$MAX_TOTAL_EXPANDED_BYTES" -ge 4294967296 ] || fail INSPECTION_POLICY_WEAK "expanded-byte budget is weaker than 4 GiB"
    grep -F '"materialized_types": ["regular"]' "$INPUTS_FILE" >/dev/null \
        || fail INSPECTION_POLICY_INVALID "only regular materialization is permitted"
    grep -F '"follow_links": false' "$INPUTS_FILE" >/dev/null \
        || fail INSPECTION_POLICY_INVALID "link following must be disabled"
}

assert_toolchain_identity() {
    require_regular "$TOOL_EVIDENCE"
    require_regular "$TRUSTED_KEYS"
    seen=0
    for format in gzip xz zstd lz4 cpio squashfs iso tar apk; do
        expected_package=$(tool_field "$format" package)
        expected_command=$(tool_field "$format" command)
        [ -n "$expected_package" ] && [ -n "$expected_command" ] \
            || fail INSPECTION_TOOLCHAIN_CONFIG_INVALID "$format package/path is absent"
        [ -x "$expected_command" ] \
            || fail INSPECTION_TOOLCHAIN_COMMAND_MISSING "$format configured executable is unavailable"
        actual_package=$(evidence_field "$format" package)
        actual_command=$(evidence_field "$format" command)
        actual_hash=$(evidence_field "$format" command_sha256)
        retained_verified=$(evidence_field "$format" retained_apk_verified)
        [ "$actual_package" = "$expected_package" ] \
            || fail INSPECTION_TOOLCHAIN_PACKAGE_DRIFT "$format package differs from the serialized contract"
        [ "$actual_command" = "$expected_command" ] \
            || fail INSPECTION_TOOLCHAIN_PATH_DRIFT "$format path differs from the serialized contract"
        [ "$actual_hash" = "$(sha256_file "$expected_command")" ] \
            || fail INSPECTION_TOOLCHAIN_BINARY_DRIFT "$format executable bytes changed after evidence collection"
        [ "$retained_verified" = true ] \
            || fail INSPECTION_TOOLCHAIN_REPOSITORY_GAP "$format executable lacks retained-APK evidence"
        seen=$((seen + 1))
    done
    [ "$seen" -eq 9 ] || fail INSPECTION_TOOLCHAIN_SET_INVALID "closed inspection command set is incomplete"
}

scan_text_value() {
    value=$1
    printf '%s\n' "$value" | grep -Eiq \
        '(^|/)(id_(rsa|dsa|ecdsa|ed25519)|known_hosts|authorized_keys|seed[.]iso|cloud-init[.]iso|management-key|build-request[.]private|[^/]+[.]rsa|[^/]+[.]env)($|/)|(^|/)(run/300k-secrets|etc/ssh/ssh_host_[^/]+_key)($|/)|(^|[^A-Za-z0-9_])([A-Za-z]:\\Users\\|\\\\[^\\]+\\[^\\]+)|wikiepeidia' \
        && fail INSPECTION_SECRET_NAME "decoded name or link target matches a private-management pattern"
    return 0
}

scan_regular_bytes() {
    file=$1
    logical=$2
    scan_text_value "$logical"
    private_pattern='BEGIN [A-Z0-9 ]*PRIVATE KEY'
    credential_pattern='(FICT[A-Z0-9_]*SECRET_TOKEN|OPENAI_API_KEY|AWS_SECRET_ACCESS_KEY|GITHUB_TOKEN|PASSWORD)[=:][[:space:]]*[A-Za-z0-9_./+~-]{12,}'
    host_pattern='([A-Za-z]:\\Users\\|\\\\[^\\[:space:]]+\\[^\\[:space:]]+|/run/300k-secrets|wikiepeidia)'
    if grep -aEiq "$private_pattern|$credential_pattern|$host_pattern" "$file"; then
        fail INSPECTION_SECRET_FOUND "decoded regular bytes contain a private credential or host-management marker"
    fi
    case "$logical" in
        */.SIGN.RSA.*.rsa.pub)
            # APK v2 signature members use a public-key-looking suffix but
            # contain only a signature blob. Their enclosing APK bytes were
            # already admitted by the verified retained-repository manifest.
            ;;
        *.rsa.pub)
            basename=${logical##*/}
            hash=$(sha256_file "$file")
            grep -F "$hash  $basename" "$TRUSTED_KEYS" >/dev/null \
                || fail INSPECTION_PUBLIC_KEY_UNAPPROVED "public APK key is outside the exact closed allowlist"
            ;;
        *.rsa|*.key|*.p12|*.pfx|*.jks|*.kdbx)
            fail INSPECTION_PRIVATE_EXTENSION "decoded regular file has a private-key extension"
            ;;
    esac
}

assert_decoder_log_clean() {
    format=$1
    log=$2
    if [ "$format" = iso9660 ]; then
        expected_banner=$(evidence_field iso version)
        [ -n "$expected_banner" ] || fail INSPECTION_TOOLCHAIN_VERSION_MISSING "locked xorriso version evidence is absent"
        expected=$log.expected
        printf '%s\n\n' "$expected_banner" > "$expected"
        [ ! -s "$log" ] || cmp "$log" "$expected" >/dev/null \
            || fail INSPECTION_DECODER_WARNING "xorriso stderr differs from the exact locked framed banner"
        : > "$log"
    fi
    [ ! -s "$log" ] || fail INSPECTION_DECODER_WARNING "$format decoder emitted warning or parser residue"
}

assert_root_confined_path() {
    destination=$1
    case "$destination" in "$OWNED_ROOT"/materialized/[0-9]*.partial|"$OWNED_ROOT"/materialized/[0-9]*) ;; *) fail INSPECTION_DESTINATION_ESCAPE "generated destination escaped scratch" ;; esac
    parent=${destination%/*}
    [ -d "$parent" ] && [ ! -L "$parent" ] \
        || fail INSPECTION_PARENT_INVALID "generated destination parent is not a real directory"
    canonical_parent=$(cd "$parent" && pwd -P)
    [ "$canonical_parent" = "$OWNED_ROOT/materialized" ] \
        || fail INSPECTION_DESTINATION_ESCAPE "generated destination parent canonicalized outside scratch"
    [ ! -e "$destination" ] && [ ! -L "$destination" ] \
        || fail INSPECTION_DESTINATION_EXISTS "exclusive generated destination already exists"
}

validate_graph_file() {
    manifest=$1
    current_members=$(counter_get members)
    current_bytes=$(counter_get expanded_bytes)
    summary=$OWNED_ROOT/graph-summary
    awk -F '\t' \
        -v max_path="$MAX_PATH_BYTES" \
        -v max_members="$MAX_MEMBERS" \
        -v max_file="$MAX_FILE_BYTES" \
        -v max_total="$MAX_TOTAL_EXPANDED_BYTES" \
        -v current_members="$current_members" \
        -v current_bytes="$current_bytes" '
        function die(message) { print message > "/dev/stderr"; bad=1; exit 2 }
        function parent(path, at) { at=match(path, /\/[^\/]*$/); return at ? substr(path,1,at-1) : "." }
        function resolve(path, target, base,n,i,part,out,top) {
            if (target ~ /^\// || target ~ /[[:cntrl:]]/ || target ~ /\\/) return "!"
            base=parent(path)
            n=split((base == "." ? target : base "/" target), part, "/")
            top=0
            for (i=1; i<=n; i++) {
                if (part[i] == "" || part[i] == ".") continue
                if (part[i] == "..") { if (top == 0) return "!"; top--; continue }
                stack[++top]=part[i]
            }
            if (top == 0) return "!"
            out=stack[1]
            for (i=2; i<=top; i++) out=out "/" stack[i]
            for (i=1; i<=top; i++) delete stack[i]
            return out
        }
        NF != 5 { die("manifest field count is ambiguous") }
        {
            id=$1; type=$2; size=$3; path=$4; target=(NF >= 5 ? $5 : "")
            if (id !~ /^[A-Za-z0-9._:+-]+$/ || seen_id[id]++) die("duplicate or unsafe stable source identifier")
            if (type !~ /^[dflh]$/) die("unsupported member type")
            if (path == "" || path == "." || path ~ /^\// || path ~ /\/\// || path ~ /(^|\/)\.\.?($|\/)/ || path ~ /(^|\/)-/ || path ~ /[[:cntrl:]]/ || path ~ /\\/ || path ~ /[^A-Za-z0-9._+@%\/:,=-]/) die("unsafe member path")
            if (length(path) > max_path) die("member path exceeds configured bound")
            if (seen_path[path]++) die("duplicate canonical member path or type conflict")
            paths[path]=type
            member_path[id]=path
            member_type[id]=type
            if (type == "f") {
                if (size !~ /^[0-9]+$/) die("regular member size is not decimal")
                if (size + 0 > max_file + 0) die("regular member exceeds single-file bound")
                declared += size
                regulars++
            } else if (size != "0") die("non-regular member declares bytes")
            if (type ~ /^[lh]$/) {
                if (target == "" || length(target) > max_path) die("link target is empty or overlong")
                canonical=resolve(path,target)
                if (canonical == "!") die("link target escapes or is malformed")
                link_target[path]=canonical
            } else if (target != "") die("non-link has a link target")
            members++
        }
        END {
            if (bad) exit 2
            if (members == 0) die("manifest is empty")
            if (current_members + members > max_members) die("member-count bound exceeded")
            if (current_bytes + declared > max_total) die("declared expanded-byte bound exceeded")
            for (path in paths) {
                p=parent(path)
                while (p != ".") {
                    if (!(p in paths) || paths[p] != "d") die("member ancestor is absent or not a directory")
                    p=parent(p)
                }
            }
            for (path in link_target) {
                target=link_target[path]
                if (!(target in paths)) die("link target is not present in the complete graph")
                if (paths[path] == "h" && paths[target] != "f") die("hardlink target is not a regular file")
                delete chain
                cursor=path
                while (cursor in link_target) {
                    if (chain[cursor]++) die("cyclic link graph")
                    cursor=link_target[cursor]
                }
            }
            print members, regulars, declared
        }
    ' "$manifest" > "$summary" || fail INSPECTION_GRAPH_REJECTED "complete member graph failed preflight"
    set -- $(cat "$summary")
    counter_set members $((current_members + $1))
    tab=$(printf '\t')
    while IFS="$tab" read -r id type size path target; do
        scan_text_value "$path"
        [ -z "${target:-}" ] || scan_text_value "$target"
    done < "$manifest"
}

preflight_graph() {
    validate_graph_file "$1"
}

stream_regular_member() {
    kind=$1
    container=$2
    member=$3
    expected_size=$4
    next=$(( $(counter_get materializations) + 1 ))
    mkdir -p -m 0700 -- "$OWNED_ROOT/materialized"
    [ -d "$OWNED_ROOT/materialized" ] && [ ! -L "$OWNED_ROOT/materialized" ] \
        || fail INSPECTION_PARENT_INVALID "materialization root is not a real directory"
    partial=$OWNED_ROOT/materialized/$next.partial
    final=$OWNED_ROOT/materialized/$next
    assert_root_confined_path "$partial"
    remaining=$((MAX_TOTAL_EXPANDED_BYTES - $(counter_get expanded_bytes)))
    [ "$remaining" -gt 0 ] || fail INSPECTION_TOTAL_LIMIT "no expanded-byte allowance remains"
    [ "$remaining" -le "$MAX_FILE_BYTES" ] || remaining=$MAX_FILE_BYTES
    blocks=$((remaining / 512))
    [ "$blocks" -gt 0 ] || fail INSPECTION_STREAM_LIMIT "remaining bounded sink allowance is below one block"
    error_log=$OWNED_ROOT/decoder-error
    : > "$error_log"
    status=0
    case "$kind" in
        iso9660)
            iso_command=$(tool_field iso command)
            (ulimit -f "$blocks"; "$iso_command" -report_about WARNING -osirrox on -indev "$container" -concat overwrite - "/$member" --) \
                > "$partial" 2>"$error_log" || status=$?
            ;;
        tar|apk)
            tar_command=$(tool_field tar command)
            (ulimit -f "$blocks"; "$tar_command" -ixOf "$container" "$member") \
                > "$partial" 2>"$error_log" || status=$?
            ;;
        cpio)
            cpio_command=$(tool_field cpio command)
            (ulimit -f "$blocks"; "$cpio_command" --extract --to-stdout --quiet "$member" < "$container") \
                > "$partial" 2>"$error_log" || status=$?
            ;;
        squashfs)
            squash_command=$(tool_field squashfs command)
            (ulimit -f "$blocks"; "$squash_command" -cat "$container" "$member") \
                > "$partial" 2>"$error_log" || status=$?
            ;;
        *) fail INSPECTION_FORMAT_UNSUPPORTED "member stream format is unsupported" ;;
    esac
    [ "$status" -eq 0 ] || fail INSPECTION_DECODE_FAILED "$kind regular-member decoder failed"
    assert_decoder_log_clean "$kind" "$error_log"
    [ -f "$partial" ] && [ ! -L "$partial" ] || fail INSPECTION_OUTPUT_TYPE "decoder output is not one regular file"
    actual=$(file_bytes "$partial")
    [ "$actual" -eq "$expected_size" ] || fail INSPECTION_SIZE_MISMATCH "$kind regular-member size differs from its preflight declaration"
    [ "$actual" -le "$remaining" ] || fail INSPECTION_STREAM_LIMIT "decoder exceeded its reserved bounded sink"
    expanded=$(( $(counter_get expanded_bytes) + actual ))
    [ "$expanded" -le "$MAX_TOTAL_EXPANDED_BYTES" ] || fail INSPECTION_TOTAL_LIMIT "expanded-byte allowance exceeded"
    mv "$partial" "$final"
    counter_set expanded_bytes "$expanded"
    counter_set regular_files $(( $(counter_get regular_files) + 1 ))
    counter_set materializations "$next"
    printf '%s\n' "$final"
}

decode_compressed() {
    format=$1
    source=$2
    logical=$3
    next=$(( $(counter_get materializations) + 1 ))
    mkdir -p -m 0700 -- "$OWNED_ROOT/materialized"
    partial=$OWNED_ROOT/materialized/$next.partial
    final=$OWNED_ROOT/materialized/$next
    assert_root_confined_path "$partial"
    remaining=$((MAX_TOTAL_EXPANDED_BYTES - $(counter_get expanded_bytes)))
    [ "$remaining" -le "$MAX_FILE_BYTES" ] || remaining=$MAX_FILE_BYTES
    blocks=$((remaining / 512))
    [ "$blocks" -gt 0 ] || fail INSPECTION_STREAM_LIMIT "no bounded decoder allowance remains"
    command=$(tool_field "$format" command)
    error_log=$OWNED_ROOT/decoder-error
    : > "$error_log"
    status=0
    case "$format" in
        gzip) (ulimit -f "$blocks"; "$command" -dc -- "$source") > "$partial" 2>"$error_log" || status=$? ;;
        xz) (ulimit -f "$blocks"; "$command" -dc -- "$source") > "$partial" 2>"$error_log" || status=$? ;;
        zstd) (ulimit -f "$blocks"; "$command" -q -dc -- "$source") > "$partial" 2>"$error_log" || status=$? ;;
        lz4) (ulimit -f "$blocks"; "$command" -q -d -c -- "$source") > "$partial" 2>"$error_log" || status=$? ;;
        *) fail INSPECTION_FORMAT_UNSUPPORTED "compressed decoder is unsupported" ;;
    esac
    [ "$status" -eq 0 ] || fail INSPECTION_DECODE_FAILED "$format decoder failed"
    [ ! -s "$error_log" ] || fail INSPECTION_DECODER_WARNING "$format decoder emitted trailing-data or warning output"
    [ -f "$partial" ] && [ ! -L "$partial" ] || fail INSPECTION_OUTPUT_TYPE "compressed decoder output is not a regular file"
    actual=$(file_bytes "$partial")
    [ "$actual" -le "$remaining" ] || fail INSPECTION_STREAM_LIMIT "compressed decoder exceeded the reserved allowance"
    expanded=$(( $(counter_get expanded_bytes) + actual ))
    mv "$partial" "$final"
    counter_set expanded_bytes "$expanded"
    counter_set regular_files $(( $(counter_get regular_files) + 1 ))
    counter_set materializations "$next"
    scan_regular_bytes "$final" "$logical"
    printf '%s\n' "$final"
}

magic_hex() {
    od -An -tx1 -N "$2" "$1" | tr -d ' \n'
}

detect_format() {
    file=$1
    prefix=$(magic_hex "$file" 6)
    case "$prefix" in
        1f8b*) printf '%s\n' gzip; return ;;
        fd377a585a00*) printf '%s\n' xz; return ;;
        28b52ffd*) printf '%s\n' zstd; return ;;
        04224d18*) printf '%s\n' lz4; return ;;
        303730373031*|303730373032*) printf '%s\n' cpio; return ;;
        68737173*) printf '%s\n' squashfs; return ;;
    esac
    tar_magic=$(dd if="$file" bs=1 skip=257 count=5 2>/dev/null || true)
    [ "$tar_magic" != ustar ] || { printf '%s\n' tar; return; }
    iso_magic=$(dd if="$file" bs=1 skip=32769 count=5 2>/dev/null || true)
    [ "$iso_magic" != CD001 ] || { printf '%s\n' iso9660; return; }
    printf '%s\n' leaf
}

role_for_path() {
    path=$1
    case "$path" in
        *.iso) printf '%s\n' iso ;;
        *.apk) printf '%s\n' apk ;;
        *apkovl*.tar.gz|*apkovl*.tgz) printf '%s\n' apkovl ;;
        */initramfs-*|initramfs-*) printf '%s\n' initramfs ;;
        */modloop-*|modloop-*) printf '%s\n' modloop ;;
        *.tar|*.tar.gz|*.tgz) printf '%s\n' archive ;;
        *.cpio|*.cpio.gz|*.cpio.xz|*.cpio.zst|*.cpio.lz4) printf '%s\n' cpio-chain ;;
        *.sqfs|*.squashfs) printf '%s\n' modloop ;;
        *.gz|*.xz|*.zst|*.zstd|*.lz4) printf '%s\n' compressed ;;
        *) printf '%s\n' auto ;;
    esac
}

make_iso_manifest() {
    iso=$1
    manifest=$2
    raw=$OWNED_ROOT/iso-list.raw
    errors=$OWNED_ROOT/iso-list.errors
    iso_command=$(tool_field iso command)
    "$iso_command" -report_about WARNING -indev "$iso" -find / -exec lsdl \
        > "$raw" 2> "$errors" || fail INSPECTION_ISO_LIST_FAILED "xorriso could not list the complete ISO graph"
    assert_decoder_log_clean iso9660 "$errors"
    awk '
        function clean(value) { gsub(/^\047|\047$/, "", value); sub(/^\//, "", value); sub(/^\.\//, "", value); return value }
        /^[bcdlps-][rwxStTs-]{9}[[:space:]]/ {
            type=substr($1,1,1); size=(type == "-" ? $5 : 0); target=""
            if (type == "-") type="f"; else if (type == "d") type="d"; else if (type == "l") type="l"; else { print "unsupported ISO type" > "/dev/stderr"; exit 2 }
            if (type == "l") { if ($(NF-1) != "->") { print "ambiguous ISO link" > "/dev/stderr"; exit 2 }; target=clean($NF); path=clean($(NF-2)) }
            else path=clean($NF)
            if (path == "") next
            printf "iso:%08d\t%s\t%s\t%s\t%s\n", ++id, type, size, path, target
            next
        }
        NF { print "ISO parser residue" > "/dev/stderr"; exit 2 }
        END { if (id == 0) exit 2 }
    ' "$raw" > "$manifest" || fail INSPECTION_ISO_MANIFEST_INVALID "xorriso listing was ambiguous or unsupported"
}

make_tar_manifest() {
    archive=$1
    manifest=$2
    raw=$OWNED_ROOT/tar-list.raw
    errors=$OWNED_ROOT/tar-list.errors
    tar_command=$(tool_field tar command)
    "$tar_command" -itvf "$archive" > "$raw" 2> "$errors" \
        || fail INSPECTION_TAR_LIST_FAILED "tar could not list the complete archive"
    [ ! -s "$errors" ] || fail INSPECTION_DECODER_WARNING "tar emitted a listing warning"
    awk '
        function clean(value) { sub(/^\.\//, "", value); sub(/\/$/, "", value); return value }
        NF {
            rawtype=substr($1,1,1); type=""; target=""; path=$NF
            if (rawtype == "-") { type="f"; size=$3 }
            else if (rawtype == "d") { type="d"; size=0 }
            else if (rawtype == "l") { type="l"; size=0; if ($(NF-1) != "->") exit 2; target=$NF; path=$(NF-2) }
            else if (rawtype == "h") { type="h"; size=0; target=$NF; path=$(NF-3) }
            else exit 2
            path=clean(path); target=clean(target)
            if (path == "") next
            printf "tar:%08d\t%s\t%s\t%s\t%s\n", ++id, type, size, path, target
        }
        END { if (id == 0) exit 2 }
    ' "$raw" > "$manifest" || fail INSPECTION_TAR_MANIFEST_INVALID "tar listing was ambiguous or unsupported"
}

make_cpio_manifest() {
    archive=$1
    manifest=$2
    raw=$OWNED_ROOT/cpio-list.raw
    errors=$OWNED_ROOT/cpio-list.errors
    cpio_command=$(tool_field cpio command)
    "$cpio_command" --list --verbose --quiet < "$archive" > "$raw" 2> "$errors" \
        || fail INSPECTION_CPIO_LIST_FAILED "cpio could not list the complete archive"
    [ ! -s "$errors" ] || fail INSPECTION_DECODER_WARNING "cpio emitted a listing warning"
    awk '
        function clean(value) { sub(/^\.\//, "", value); sub(/\/$/, "", value); return value }
        NF {
            rawtype=substr($1,1,1); target=""; path=$NF
            if (rawtype == "-") { type="f"; size=$5 }
            else if (rawtype == "d") { type="d"; size=0 }
            else if (rawtype == "l") { type="l"; size=0; if ($(NF-1) != "->") exit 2; target=$NF; path=$(NF-2) }
            else exit 2
            path=clean(path); target=clean(target)
            if (path == "") next
            printf "cpio:%08d\t%s\t%s\t%s\t%s\n", ++id, type, size, path, target
        }
        END { if (id == 0) exit 2 }
    ' "$raw" > "$manifest" || fail INSPECTION_CPIO_MANIFEST_INVALID "cpio listing was ambiguous or unsupported"
}

make_squashfs_manifest() {
    archive=$1
    manifest=$2
    raw=$OWNED_ROOT/squash-list.raw
    errors=$OWNED_ROOT/squash-list.errors
    command=$(tool_field squashfs command)
    "$command" -lls -no-progress "$archive" > "$raw" 2> "$errors" \
        || fail INSPECTION_SQUASHFS_LIST_FAILED "unsquashfs could not list the complete filesystem"
    [ ! -s "$errors" ] || fail INSPECTION_DECODER_WARNING "unsquashfs emitted a listing warning"
    awk '
        function clean(value) { sub(/^squashfs-root\/?/, "", value); sub(/\/$/, "", value); return value }
        /^[bcdlps-][rwxStTs-]{9}[[:space:]]/ {
            rawtype=substr($1,1,1); target=""; path=$NF
            if (rawtype == "-") { type="f"; size=$3 }
            else if (rawtype == "d") { type="d"; size=0 }
            else if (rawtype == "l") { type="l"; size=0; if ($(NF-1) != "->") exit 2; target=$NF; path=$(NF-2) }
            else exit 2
            path=clean(path); target=clean(target)
            if (path == "") next
            printf "squashfs:%08d\t%s\t%s\t%s\t%s\n", ++id, type, size, path, target
            next
        }
        NF { exit 2 }
        END { if (id == 0) exit 2 }
    ' "$raw" > "$manifest" || fail INSPECTION_SQUASHFS_MANIFEST_INVALID "SquashFS listing was ambiguous or unsupported"
}

inspect_archive_members() {
    kind=$1
    archive=$2
    logical=$3
    depth=$4
    manifest=$OWNED_ROOT/manifest-$(( $(counter_get containers) + 1 ))
    case "$kind" in
        iso9660) make_iso_manifest "$archive" "$manifest" ;;
        tar|apk) make_tar_manifest "$archive" "$manifest" ;;
        cpio) make_cpio_manifest "$archive" "$manifest" ;;
        squashfs) make_squashfs_manifest "$archive" "$manifest" ;;
        *) fail INSPECTION_FORMAT_UNSUPPORTED "container manifest format is unsupported" ;;
    esac
    preflight_graph "$manifest"
    counter_set containers $(( $(counter_get containers) + 1 ))
    tab=$(printf '\t')
    while IFS="$tab" read -r id type size member target; do
        [ "$type" = f ] || continue
        materialized=$(stream_regular_member "$kind" "$archive" "$member" "$size")
        scan_regular_bytes "$materialized" "$logical/$member"
        role=$(role_for_path "$member")
        inspect_file "$materialized" "$logical/$member" $((depth + 1)) "$role"
    done < "$manifest"
}

inspect_file() {
    file=$1
    logical=$2
    depth=$3
    role=$4
    [ "$depth" -le "$MAX_DEPTH" ] || fail INSPECTION_DEPTH_LIMIT "nested decoder depth exceeded"
    observed=$(counter_get observed_depth)
    [ "$depth" -le "$observed" ] || counter_set observed_depth "$depth"
    require_regular "$file"
    format=$(detect_format "$file")
    case "$role:$format" in
        iso:iso9660|apk:gzip|apk:tar|apkovl:gzip|apkovl:tar|initramfs:gzip|initramfs:xz|initramfs:zstd|initramfs:lz4|initramfs:cpio|modloop:squashfs|modloop:gzip|modloop:xz|modloop:zstd|modloop:lz4|archive:tar|archive:gzip|cpio-chain:cpio|cpio-chain:gzip|cpio-chain:xz|cpio-chain:zstd|cpio-chain:lz4|compressed:gzip|compressed:xz|compressed:zstd|compressed:lz4|auto:*) ;;
        *) fail INSPECTION_EXPECTED_ROLE_MISMATCH "$logical does not decode as its required Alpine role" ;;
    esac
    case "$format" in
        gzip|xz|zstd|lz4)
            decoded=$(decode_compressed "$format" "$file" "$logical.decoded")
            case "$role" in
                apk|apkovl|initramfs|modloop|cpio-chain) next_role=$role ;;
                archive) next_role=archive ;;
                *) next_role=auto ;;
            esac
            inspect_file "$decoded" "$logical.decoded" $((depth + 1)) "$next_role"
            ;;
        iso9660|tar|cpio|squashfs)
            inspect_archive_members "$format" "$file" "$logical" "$depth"
            ;;
        leaf)
            case "$role" in auto) : ;; *) fail INSPECTION_UNSUPPORTED_MAGIC "$logical ended before its required container role" ;; esac
            ;;
        *) fail INSPECTION_FORMAT_UNSUPPORTED "magic detector returned an unsupported format" ;;
    esac
}

write_iso_audit() {
    iso=$1
    output=$2
    manifest=$3
    iso_hash=$(sha256_file "$iso")
    iso_bytes=$(file_bytes "$iso")
    bios=false
    uefi=false
    tab=$(printf '\t')
    grep -Eq "${tab}(f|d)${tab}[0-9]+${tab}(boot/)?(isolinux|syslinux)(/|$)" "$manifest" && bios=true || true
    grep -Eq "${tab}(f|d)${tab}[0-9]+${tab}EFI/BOOT(/|$)" "$manifest" && uefi=true || true
    trusted_key_count=$(wc -l < "$TRUSTED_KEYS" | tr -d ' ')
    evidence_hash=$(sha256_file "$TOOL_EVIDENCE")
    [ "$(cat /work/inspector-self-test.passed 2>/dev/null || true)" = passed ] \
        || fail INSPECTION_SELF_TEST_EVIDENCE_MISSING "hostile fixture self-test did not complete before audit"
    cat > "$output.partial" <<EOF
{
  "schema": "IsoAudit",
  "schema_version": 1,
  "iso_sha256": "$iso_hash",
  "iso_bytes": $iso_bytes,
  "inspection_toolchain_sha256": "$evidence_hash",
  "accepted_decoders": ["gzip", "xz", "zstd", "lz4", "cpio", "squashfs", "iso", "tar", "apk"],
  "limits": {
    "max_depth": $MAX_DEPTH,
    "max_members": $MAX_MEMBERS,
    "max_path_bytes": $MAX_PATH_BYTES,
    "max_file_bytes": $MAX_FILE_BYTES,
    "max_total_expanded_bytes": $MAX_TOTAL_EXPANDED_BYTES
  },
  "counts": {
    "members": $(counter_get members),
    "regular_files": $(counter_get regular_files),
    "containers": $(counter_get containers),
    "expanded_bytes": $(counter_get expanded_bytes),
    "max_observed_depth": $(counter_get observed_depth)
  },
  "structural_boot_findings": {"bios_tree_present": $bios, "uefi_tree_present": $uefi, "classification": "structural"},
  "public_key_allowance": {"closed_key_count": $trusted_key_count, "manifest_sha256": "$(sha256_file "$TRUSTED_KEYS")"},
  "preflight_before_materialization": true,
  "links_materialized": false,
  "hostile_fixture_self_test": true,
  "result": "pass"
}
EOF
    require_regular "$output.partial"
    mv "$output.partial" "$output"
    AUDIT_COMMITTED=1
}

inspect_iso_artifact() {
    iso=$1
    output=$2
    require_regular "$iso"
    [ ! -e "$output" ] && [ ! -L "$output" ] || fail INSPECTION_AUDIT_EXISTS "audit destination already exists"
    AUDIT_OUTPUT=$output
    assert_toolchain_identity
    inspect_file "$iso" image.iso 0 iso
    top_manifest=$(find "$OWNED_ROOT" -maxdepth 1 -type f -name 'manifest-*' | LC_ALL=C sort | head -n 1)
    require_regular "$top_manifest"
    write_iso_audit "$iso" "$output" "$top_manifest"
}

fixture_reset_state() {
    printf '%s\n' \
        'members=0' 'regular_files=0' 'containers=0' 'expanded_bytes=0' 'materializations=0' 'observed_depth=0' > "$STATE_FILE"
}

expect_probe_failure() {
    expected=$1
    file=$2
    role=$3
    label=$4
    fixture_reset_state
    error=$OWNED_ROOT/$label.error
    if (inspect_file "$file" "$label" 0 "$role") > /dev/null 2> "$error"; then
        fail SELF_TEST_VACUOUS "$label hostile fixture was accepted"
    fi
    if ! grep -F "$expected" "$error" >/dev/null; then
        actual=$(sed -n 's/^\([A-Z][A-Z0-9_]*\):.*/\1/p' "$error" | head -n 1)
        [ -n "$actual" ] || actual=NO_DIAGNOSTIC
        fail SELF_TEST_WRONG_FAILURE "$label expected $expected but got $actual"
    fi
}

create_iso_fixture() {
    label=$1
    output=$2
    source=$3
    iso_command=$(tool_field iso command)
    errors=$OWNED_ROOT/$label-create.errors
    "$iso_command" -as mkisofs -quiet -output "$output" "$source" 2> "$errors" \
        || fail SELF_TEST_FIXTURE_INVALID "$label ISO fixture creation failed"
    assert_decoder_log_clean iso9660 "$errors"
}

make_secret_file() {
    output=$1
    marker_left=FICT
    marker_right='IONAL_300K_SECRET_TOKEN='
    printf '%s%s%s\n' "$marker_left" "$marker_right" '0123456789ABCDEF0123456789ABCDEF' > "$output"
}

run_hostile_fixture_self_test() {
    root=$OWNED_ROOT/selftest
    mkdir -m 0700 "$root" "$root/content" "$root/iso-root" "$root/iso-root/boot" "$root/iso-root/apks" "$root/iso-root/apks/x86_64"
    make_secret_file "$root/content/secret.txt"
    printf '%s\n' '300K clean decoded fixture' > "$root/content/clean.txt"
    marker=$(cat "$root/content/secret.txt")
    gzip_command=$(tool_field gzip command)
    xz_command=$(tool_field xz command)
    zstd_command=$(tool_field zstd command)
    lz4_command=$(tool_field lz4 command)
    tar_command=$(tool_field tar command)
    cpio_command=$(tool_field cpio command)
    "$gzip_command" -n -c -- "$root/content/secret.txt" > "$root/secret.gz"
    "$xz_command" -zc --check=crc32 -- "$root/content/secret.txt" > "$root/secret.xz"
    "$zstd_command" -q -c -- "$root/content/secret.txt" > "$root/secret.zst"
    "$lz4_command" -q -c -- "$root/content/secret.txt" > "$root/secret.lz4"
    for compressed_secret_fixture in "$root/secret.gz" "$root/secret.xz" "$root/secret.zst" "$root/secret.lz4"; do
        if grep -aF "$marker" "$compressed_secret_fixture" >/dev/null; then fail SELF_TEST_FIXTURE_INVALID "compressed secret fixture leaked plaintext into outer bytes"; fi
        expect_probe_failure INSPECTION_SECRET_FOUND "$compressed_secret_fixture" compressed "compressed-$(basename "$compressed_secret_fixture")"
    done

    mkdir "$root/apkovl" "$root/cpio" "$root/tar"
    cp "$root/content/secret.txt" "$root/apkovl/payload"
    (cd "$root/apkovl" && "$tar_command" -cf "$root/apkovl.tar" payload)
    "$gzip_command" -n -c -- "$root/apkovl.tar" > "$root/secret.apkovl.tar.gz"
    expect_probe_failure INSPECTION_SECRET_FOUND "$root/secret.apkovl.tar.gz" apkovl apkovl

    cp "$root/content/secret.txt" "$root/cpio/payload"
    (cd "$root/cpio" && printf '%s\n' payload | "$cpio_command" --create --format=newc --reproducible --quiet) > "$root/initramfs.cpio"
    "$gzip_command" -n -c -- "$root/initramfs.cpio" > "$root/initramfs-secret"
    expect_probe_failure INSPECTION_SECRET_FOUND "$root/initramfs-secret" initramfs initramfs-cpio

    cp "$root/secret.gz" "$root/tar/payload.gz"
    (cd "$root/tar" && "$tar_command" -cf "$root/secret.tar" payload.gz)
    expect_probe_failure INSPECTION_SECRET_FOUND "$root/secret.tar" archive tar

    "$gzip_command" -n -c -- "$root/secret.tar" > "$root/secret.apk"
    expect_probe_failure INSPECTION_SECRET_FOUND "$root/secret.apk" apk apk

    mkdir "$root/squash"
    cp "$root/content/secret.txt" "$root/squash/payload"
    /usr/bin/mksquashfs "$root/squash" "$root/modloop-secret" -noappend -no-xattrs -all-time 0 -quiet >/dev/null
    expect_probe_failure INSPECTION_SECRET_FOUND "$root/modloop-secret" modloop squashfs

    mkdir "$root/secret-iso"
    cp "$root/secret.gz" "$root/secret-iso/payload.gz"
    create_iso_fixture secret "$root/secret.iso" "$root/secret-iso"
    if grep -aF "$marker" "$root/secret.iso" >/dev/null; then fail SELF_TEST_FIXTURE_INVALID "ISO secret fixture contains the raw marker"; fi
    expect_probe_failure INSPECTION_SECRET_FOUND "$root/secret.iso" iso iso9660

    cp "$root/content/clean.txt" "$root/iso-root/boot/vmlinuz-test"
    cp "$root/initramfs.cpio" "$root/clean.cpio"
    "$gzip_command" -n -c -- "$root/clean.cpio" > "$root/iso-root/boot/initramfs-test"
    mkdir "$root/clean-squash"
    cp "$root/content/clean.txt" "$root/clean-squash/payload"
    /usr/bin/mksquashfs "$root/clean-squash" "$root/iso-root/boot/modloop-test" -noappend -no-xattrs -all-time 0 -quiet >/dev/null
    cp "$root/content/clean.txt" "$root/tar/clean"
    (cd "$root/tar" && "$tar_command" -cf "$root/clean.tar" clean)
    "$gzip_command" -n -c -- "$root/clean.tar" > "$root/iso-root/apks/x86_64/clean.apk"
    "$gzip_command" -n -c -- "$root/clean.tar" > "$root/iso-root/clean.apkovl.tar.gz"
    cp /etc/apk/keys/300k.rsa.pub "$root/iso-root/apks/300k.rsa.pub"
    create_iso_fixture clean "$root/clean.iso" "$root/iso-root"
    clean_scratch=$root/clean-audit-scratch
    clean_audit=$root/clean-audit.json
    # The child clean-audit probe is itself part of the hostile suite. A later
    # fixture failure aborts the build, and the buildroot is discarded.
    printf '%s\n' passed > /work/inspector-self-test.passed
    "$0" audit "$root/clean.iso" "$clean_scratch" "$clean_audit"
    grep -F "\"iso_sha256\": \"$(sha256_file "$root/clean.iso")\"" "$clean_audit" >/dev/null \
        || fail SELF_TEST_CLEAN_AUDIT_INVALID "clean fixture audit is not tied to its exact ISO"
    grep -F '"result": "pass"' "$clean_audit" >/dev/null \
        || fail SELF_TEST_CLEAN_AUDIT_INVALID "clean fixture did not produce a pass result"

    printf '\037\213malformed' > "$root/malformed.gz"
    expect_probe_failure INSPECTION_DECODE_FAILED "$root/malformed.gz" compressed decode-error
    printf '%s\n' 'unsupported magic and trailing unparsed payload' > "$root/unsupported.tar"
    expect_probe_failure INSPECTION_EXPECTED_ROLE_MISMATCH "$root/unsupported.tar" archive unsupported-magic

    sandbox=$root/hostile-sandbox
    probe=$sandbox/probe
    mkdir "$sandbox" "$probe"
    outside_scratch_sentinel=$sandbox/outside_scratch_sentinel
    printf '%s\n' 'outside scratch sentinel' > "$outside_scratch_sentinel"
    sentinel_before=$(sha256_file "$outside_scratch_sentinel")
    stat -c '%f:%s:%Y' "$outside_scratch_sentinel" > "$sandbox/metadata.before"
    find "$sandbox" -mindepth 1 -maxdepth 1 ! -name probe -printf '%f\t%y\t%s\n' | LC_ALL=C sort > "$sandbox/inventory.before"
    for hostile in absolute traversal control-character device FIFO socket escaping-symlink escaping-hardlink cyclic-link link-parent duplicate-type oversized pathname member-count total-expanded-byte; do
        manifest=$probe/$hostile.manifest
        case "$hostile" in
            absolute) printf 'x\tf\t1\t/escape\t\n' > "$manifest" ;;
            traversal) printf 'x\tf\t1\t../escape\t\n' > "$manifest" ;;
            control-character) printf 'x\tf\t1\tbad\001name\t\n' > "$manifest" ;;
            device) printf 'x\tc\t0\tdevice\t\n' > "$manifest" ;;
            FIFO) printf 'x\tp\t0\tpipe\t\n' > "$manifest" ;;
            socket) printf 'x\ts\t0\tsocket\t\n' > "$manifest" ;;
            escaping-symlink) printf 'x\tl\t0\tlink\t../../outside_scratch_sentinel\n' > "$manifest" ;;
            escaping-hardlink) printf 'x\th\t0\tlink\t../../outside_scratch_sentinel\n' > "$manifest" ;;
            cyclic-link) printf 'a\tl\t0\ta\tb\nb\tl\t0\tb\ta\n' > "$manifest" ;;
            link-parent) printf 'a\tl\t0\ta\tb\nb\tf\t1\tb\t\nc\tf\t1\ta/c\t\n' > "$manifest" ;;
            duplicate-type) printf 'a\tf\t1\ta\t\nb\td\t0\ta\t\n' > "$manifest" ;;
            oversized) printf 'x\tf\t%s\tlarge\t\n' $((MAX_FILE_BYTES + 1)) > "$manifest" ;;
            pathname) awk -v n=$((MAX_PATH_BYTES + 1)) 'BEGIN { printf "x\tf\t1\t"; for(i=0;i<n;i++) printf "a"; print "\t" }' > "$manifest" ;;
            member-count) printf 'a\td\t0\ta\t\nb\tf\t1\ta/b\t\nc\tf\t1\ta/c\t\n' > "$manifest" ;;
            total-expanded-byte) printf 'x\tf\t11\tlarge\t\n' > "$manifest" ;;
        esac
        fixture_reset_state
        old_members=$MAX_MEMBERS
        old_total=$MAX_TOTAL_EXPANDED_BYTES
        [ "$hostile" != member-count ] || MAX_MEMBERS=2
        [ "$hostile" != total-expanded-byte ] || MAX_TOTAL_EXPANDED_BYTES=10
        if (preflight_graph "$manifest") > /dev/null 2> "$probe/$hostile.error"; then
            fail SELF_TEST_VACUOUS "$hostile graph was accepted"
        fi
        MAX_MEMBERS=$old_members
        MAX_TOTAL_EXPANDED_BYTES=$old_total
        [ "$(counter_get materializations)" -eq 0 ] || fail SELF_TEST_PREMATERIALIZED "$hostile graph materialized before rejection"
    done
    [ "$(sha256_file "$outside_scratch_sentinel")" = "$sentinel_before" ] \
        || fail SELF_TEST_ESCAPE "hostile graph changed the adjacent sentinel bytes"
    stat -c '%f:%s:%Y' "$outside_scratch_sentinel" > "$sandbox/metadata.after"
    find "$sandbox" -mindepth 1 -maxdepth 1 ! -name probe -printf '%f\t%y\t%s\n' | LC_ALL=C sort > "$sandbox/inventory.after"
    cmp "$sandbox/metadata.before" "$sandbox/metadata.after" >/dev/null \
        || fail SELF_TEST_ESCAPE "hostile graph changed adjacent sentinel metadata"
    # Inventory snapshots include their own snapshot filenames, so compare the
    # stable sentinel record directly as well as every pre-existing sibling.
    grep -F 'outside_scratch_sentinel' "$sandbox/inventory.before" > "$sandbox/stable.before"
    grep -F 'outside_scratch_sentinel' "$sandbox/inventory.after" > "$sandbox/stable.after"
    cmp "$sandbox/stable.before" "$sandbox/stable.after" >/dev/null \
        || fail SELF_TEST_ESCAPE "hostile graph changed the outside-scratch inventory"

    fixture_reset_state
    if (inspect_file "$root/content/clean.txt" depth-limit $((MAX_DEPTH + 1)) auto) > /dev/null 2> "$root/depth.error"; then
        fail SELF_TEST_VACUOUS "depth-limit fixture was accepted"
    fi
    grep -F INSPECTION_DEPTH_LIMIT "$root/depth.error" >/dev/null \
        || fail SELF_TEST_WRONG_FAILURE "depth-limit fixture failed for an unrelated reason"

    printf '%s\n' '300K_INSPECTOR_SELF_TEST_PASS layers=iso9660,apkovl,initramfs,cpio,squashfs,apk,tar,gzip,xz,zstd,lz4 guards=path,type,links,decode,magic,depth,members,file,total,sentinel'
}

run_inspector_self_test() {
    assert_toolchain_identity
    run_hostile_fixture_self_test
}

case "$MODE" in
    audit)
        [ "$#" -eq 4 ] || fail INSPECTION_ARGUMENTS_INVALID "usage: inspect-iso.sh audit <iso> <scratch> <output-json>"
        ISO_FILE=$2
        SCRATCH=$3
        OUTPUT=$4
        load_policy
        prepare_owned_root "$SCRATCH"
        inspect_iso_artifact "$ISO_FILE" "$OUTPUT"
        ;;
    self-test)
        [ "$#" -eq 2 ] || fail INSPECTION_ARGUMENTS_INVALID "usage: inspect-iso.sh self-test <scratch>"
        load_policy
        prepare_owned_root "$2"
        run_inspector_self_test
        ;;
    *) fail INSPECTION_MODE_INVALID "expected audit or self-test" ;;
esac
