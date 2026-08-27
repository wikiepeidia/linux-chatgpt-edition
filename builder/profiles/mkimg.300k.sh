profile_300k_bootstrap() {
    profile_virt
    _300k_apks=; for _300k_package in $apks; do [ "$_300k_package" = alpine-base ] || _300k_apks="$_300k_apks $_300k_package"; done
    apks="alpine-baselayout alpine-conf apk-tools busybox busybox-mdev-openrc busybox-openrc busybox-suid musl-utils openrc$_300k_apks"
    unset _300k_apks _300k_package
    profile_abbrev="300k"
    image_name="300k-bootstrap"
    title="300K Linux Bootstrap"
    desc="Pinned build-pipeline proof; not the final runtime."
}

profile_300k_deadline() {
    profile_virt
    arch="x86_64"
    hostname="300k"
    apkovl="genapkovl-300k.sh"
    apks="$apks alpine-base doas eudev font-terminus mesa-dri-gallium openbox tcl tk xf86-input-libinput xinit xorg-server xterm"
    profile_abbrev="300kdl"
    image_name="300k-deadline"
    title="300K Linux Deadline MVP"
    desc="Unofficial offline parody desktop with a real local terminal."
}
