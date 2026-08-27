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
install -d -m 0755 "$stage/etc" "$stage/etc/apk" "$stage/etc/doas.d" "$stage/etc/local.d" "$stage/etc/profile.d" "$stage/etc/runlevels"
install -d -m 0755 "$stage/etc/runlevels/sysinit" "$stage/etc/runlevels/boot" "$stage/etc/runlevels/default" "$stage/etc/runlevels/shutdown"
install -d -m 0755 "$stage/home" "$stage/home/chatgpt" "$stage/home/chatgpt/.config" "$stage/home/chatgpt/.config/openbox"
install -d -m 0755 "$stage/usr" "$stage/usr/local" "$stage/usr/local/bin" "$stage/usr/local/lib" "$stage/usr/local/lib/300k" "$stage/usr/local/sbin"

install_file() {
    mode=$1
    relative=$2
    source=$source_root/$relative
    destination=$stage/$relative
    [ -f "$source" ] || { printf 'missing overlay source: %s\n' "$relative" >&2; exit 68; }
    install -D -m "$mode" "$source" "$destination"
}

rc_add() {
    service=$1
    runlevel=$2
    ln -s "/etc/init.d/$service" "$stage/etc/runlevels/$runlevel/$service"
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

printf '%s\n' "$hostname" > "$stage/etc/hostname"
chmod 0644 "$stage/etc/hostname"
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

rc_add devfs sysinit
rc_add dmesg sysinit
rc_add udev sysinit
rc_add udev-trigger sysinit
rc_add udev-settle sysinit
rc_add modloop sysinit
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add udev-postmount default
rc_add local default
rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown
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
    -C "$stage" -cf - etc home usr | gzip -9n > "$output_tmp"
chmod 0644 "$output_tmp"
mv -f -- "$output_tmp" "$output"
printf '%s\n' "$output"
