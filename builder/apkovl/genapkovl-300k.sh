#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' 'usage: genapkovl-300k.sh <hostname>' >&2
    exit 64
fi

hostname=$1
case $hostname in
    ''|*[!a-z0-9-]*|-*|*-|*--*)
        printf '%s\n' 'invalid hostname' >&2
        exit 65
        ;;
esac
[ "${#hostname}" -le 63 ] || { printf '%s\n' 'invalid hostname' >&2; exit 65; }

case ${SOURCE_DATE_EPOCH:-} in
    ''|*[!0-9]*) printf '%s\n' 'SOURCE_DATE_EPOCH must be a non-negative integer' >&2; exit 66 ;;
esac

umask 077
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source_root=$script_dir/rootfs
[ -d "$source_root" ] || { printf '%s\n' 'overlay source is missing' >&2; exit 67; }

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/300k-apkovl.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_root"
}
trap 'cleanup' EXIT
trap 'exit 130' INT TERM HUP

stage=$temporary_root/root
install -d -m 0755 "$stage"

install_file() {
    mode=$1
    relative=$2
    source=$source_root/$relative
    destination=$stage/$relative
    [ -f "$source" ] || { printf 'missing overlay source: %s\n' "$relative" >&2; exit 68; }
    install -D -m "$mode" "$source" "$destination"
}

install_file 0644 etc/inittab
install_file 0755 etc/local.d/300k.start
install_file 0644 etc/profile.d/300k-session.sh
install_file 0400 etc/doas.d/300k.conf
install_file 0755 home/chatgpt/.xinitrc
install_file 0644 home/chatgpt/.config/openbox/rc.xml
install_file 0755 usr/local/bin/300k-runtime
install_file 0755 usr/local/sbin/300k-power
install_file 0644 usr/local/lib/300k/content.tcl
install_file 0644 usr/local/lib/300k/ui.tcl

install -d -m 0755 "$stage/etc/apk" "$stage/etc/runlevels/default" "$stage/etc/runlevels/sysinit" "$stage/usr/local/bin"
cat > "$temporary_root/world.unsorted" <<'PACKAGES'
alpine-base
doas
eudev
font-terminus
mesa-dri-gallium
openbox
tcl
tk
xf86-input-libinput
xinit
xorg-server
xterm
PACKAGES
LC_ALL=C sort -u "$temporary_root/world.unsorted" > "$stage/etc/apk/world"
chmod 0644 "$stage/etc/apk/world"

ln -s /etc/init.d/local "$stage/etc/runlevels/default/local"
ln -s /etc/init.d/udev "$stage/etc/runlevels/sysinit/udev"
ln -s /etc/init.d/udev-trigger "$stage/etc/runlevels/sysinit/udev-trigger"
ln -s /etc/init.d/udev-settle "$stage/etc/runlevels/sysinit/udev-settle"
ln -s 300k-runtime "$stage/usr/local/bin/300k-autologin"

output=$PWD/$hostname.apkovl.tar.gz
output_tmp=$temporary_root/$hostname.apkovl.tar.gz
LC_ALL=C tar \
    --sort=name \
    --format=ustar \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mtime=@$SOURCE_DATE_EPOCH \
    -C "$stage" -cf - . | gzip -9n > "$output_tmp"
chmod 0644 "$output_tmp"
mv -f -- "$output_tmp" "$output"
printf '%s\n' "$output"
