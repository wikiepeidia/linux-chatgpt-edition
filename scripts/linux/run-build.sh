#!/bin/sh
set -eu

export LC_ALL=C
export LANG=C
umask 077

MODE=${1:-}
REQUEST_FILE=${2:-}
INPUTS_FILE=/workspace/builder/inputs.json
EXPORT_ROOT=/export
WORK_ROOT=/work
CACHE_ROOT=/var/lib/300k-cache
SECRET_ROOT=/run/300k-secrets
SERIAL_DEVICE=/dev/ttyS0

fail() {
    code=$1
    shift
    printf '%s: %s\n' "$code" "$*" >&2
    if [ -w "$SERIAL_DEVICE" ]; then printf '300K_BUILD_FAILED %s\n' "$code" > "$SERIAL_DEVICE"; fi
    exit 1
}

milestone() {
    printf '%s\n' "$*"
    if [ -w "$SERIAL_DEVICE" ]; then printf '%s\n' "$*" > "$SERIAL_DEVICE"; fi
}

require_file() {
    [ -f "$1" ] || fail BUILD_INPUT_MISSING "required input is absent"
    [ -s "$1" ] || fail BUILD_INPUT_EMPTY "required input is empty"
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

json_array_lines() {
    key=$1
    file=$2
    awk -v wanted="\"$key\"" '
        index($0, wanted) { inside=1; next }
        inside && /]/ { exit }
        inside {
            line=$0
            gsub(/^[[:space:]]*"|",?[[:space:]]*$/, "", line)
            if (length(line) > 0) print line
        }
    ' "$file"
}

repository_value() {
    repo_name=$1
    field=$2
    awk -v repo="\"name\": \"$repo_name\"" -v wanted="\"$field\"" '
        index($0, repo) { found=1 }
        found && index($0, wanted) {
            line=$0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            sub(/[[:space:]]*,?[[:space:]]*$/, "", line)
            gsub(/^"|"$/, "", line)
            print line
            exit
        }
    ' "$INPUTS_FILE"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/[[:cntrl:]]/ /g'
}

require_public_contract() {
    require_file "$INPUTS_FILE"
    require_file "$REQUEST_FILE"
    [ "$(json_scalar release "$INPUTS_FILE")" = 3.24.1 ] || fail INPUT_RELEASE_MISMATCH "Alpine release is not 3.24.1"
    [ "$(json_scalar arch "$INPUTS_FILE")" = x86_64 ] || fail INPUT_ARCH_MISMATCH "target architecture is not x86_64"
    [ "$(json_scalar commit "$INPUTS_FILE")" = 52643b7a176095362fd87fe73cdb994cb2e5ffae ] || fail INPUT_APORTS_MISMATCH "aports commit changed"
    grep -F '"gzip=1.14-r2"' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "gzip pin missing"
    grep -F '"xz=5.8.3-r0"' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "xz pin missing"
    grep -F '"zstd=1.5.7-r2"' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "zstd pin missing"
    grep -F '"lz4=1.10.0-r1"' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "lz4 pin missing"
    grep -F '"cpio=2.15-r0"' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "cpio pin missing"
    grep -F '"decoder": ["/usr/bin/xorriso", "-osirrox", "on:o_excl_on", "-indev"]' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "ISO decoder contract changed"
}

download_file() {
    url=$1
    output=$2
    rm -f "$output.partial"
    wget -q -T 120 -O "$output.partial" "$url" || fail NETWORK_DOWNLOAD_FAILED "official HTTPS download failed"
    [ -s "$output.partial" ] || fail NETWORK_DOWNLOAD_EMPTY "official HTTPS download was empty"
    mv "$output.partial" "$output"
}

download_and_verify_indexes() {
    destination=$1
    mkdir -p "$destination"
    main_url=$(repository_value main url)
    community_url=$(repository_value community url)
    main_hash=$(repository_value main apkindex_sha256)
    community_hash=$(repository_value community apkindex_sha256)
    download_file "$main_url/x86_64/APKINDEX.tar.gz" "$destination/APKINDEX.main.tar.gz"
    download_file "$community_url/x86_64/APKINDEX.tar.gz" "$destination/APKINDEX.community.tar.gz"
    [ "$(sha256_file "$destination/APKINDEX.main.tar.gz")" = "$main_hash" ] || fail APKINDEX_DRIFT "main APKINDEX bytes differ from the committed pin"
    [ "$(sha256_file "$destination/APKINDEX.community.tar.gz")" = "$community_hash" ] || fail APKINDEX_DRIFT "community APKINDEX bytes differ from the committed pin"
}

verify_repository_snapshot() {
    repository=$1
    manifest=$repository/repository.sha256
    require_file "$manifest"
    seen=0
    while IFS='  ' read -r expected basename; do
        [ -n "$expected" ] || continue
        case "$expected" in *[!0-9a-f]*|'') fail REPOSITORY_MANIFEST_INVALID "repository manifest hash is malformed" ;; esac
        case "$basename" in ''|*/*|*\\*|.*) fail REPOSITORY_MANIFEST_INVALID "repository manifest basename is unsafe" ;; esac
        require_file "$repository/$basename"
        [ "$(sha256_file "$repository/$basename")" = "$expected" ] || fail REPOSITORY_DRIFT "verified repository byte changed before use"
        seen=$((seen + 1))
    done < "$manifest"
    [ "$seen" -gt 0 ] || fail REPOSITORY_MANIFEST_INVALID "repository manifest is empty"
}

emit_repository_manifest() {
    repository=$1
    (
        cd "$repository"
        find . -maxdepth 1 -type f ! -name repository.sha256 ! -name repository.sha256.partial \
            | sed 's#^\./##' \
            | LC_ALL=C sort \
            | while IFS= read -r basename; do
                hash=$(sha256sum "$basename" | awk '{print $1}')
                printf '%s  %s\n' "$hash" "$basename"
            done
    ) > "$repository/repository.sha256.partial"
    mv "$repository/repository.sha256.partial" "$repository/repository.sha256"
}

bootstrap_online_tools() {
    packages=$(json_array_lines builder_packages "$INPUTS_FILE" | tr '\n' ' ')
    main_url=$(repository_value main url)
    community_url=$(repository_value community url)
    # apk verifies the official repository signatures and exact revisions here.
    apk --no-cache --repository "$main_url" --repository "$community_url" add $packages \
        || fail BOOTSTRAP_PACKAGE_VERIFY_FAILED "official signed builder packages did not verify/install"
}

init_signing_key() {
    grep -F '"schema": "KeyInitRequest"' "$REQUEST_FILE" >/dev/null || fail KEY_INIT_REQUEST_INVALID "expected KeyInitRequest"
    init_root=$WORK_ROOT/key-init
    rm -rf "$init_root"
    mkdir -p "$init_root/pre-index" "$init_root/home/.abuild" "$EXPORT_ROOT"
    download_and_verify_indexes "$init_root/pre-index"
    bootstrap_online_tools
    download_and_verify_indexes "$init_root/post-index"
    cmp "$init_root/pre-index/APKINDEX.main.tar.gz" "$init_root/post-index/APKINDEX.main.tar.gz" >/dev/null || fail APKINDEX_DRIFT "main index changed during key initialization"
    cmp "$init_root/pre-index/APKINDEX.community.tar.gz" "$init_root/post-index/APKINDEX.community.tar.gz" >/dev/null || fail APKINDEX_DRIFT "community index changed during key initialization"

    export HOME=$init_root/home
    export PACKAGER='300K Linux build identity <build@300k.invalid>'
    abuild-keygen -a -n >/dev/null 2>&1 || fail KEY_GENERATION_FAILED "abuild-keygen failed"
    private=$(find "$HOME/.abuild" -maxdepth 1 -type f -name '*.rsa' | LC_ALL=C sort | head -n 1)
    [ -n "$private" ] || fail KEY_GENERATION_FAILED "abuild-keygen returned no private key"
    public=$private.pub
    require_file "$public"
    install -m 0600 "$private" "$EXPORT_ROOT/300k.rsa"
    install -m 0644 "$public" "$EXPORT_ROOT/300k.rsa.pub"
    public_hash=$(sha256_file "$EXPORT_ROOT/300k.rsa.pub")
    public_bytes=$(file_bytes "$EXPORT_ROOT/300k.rsa.pub")
    cat > "$EXPORT_ROOT/signing-public.json.partial" <<EOF
{
  "schema": "SigningPublic",
  "schema_version": 1,
  "public_key_file": "300k.rsa.pub",
  "public_key_sha256": "$public_hash",
  "public_key_bytes": $public_bytes
}
EOF
    mv "$EXPORT_ROOT/signing-public.json.partial" "$EXPORT_ROOT/signing-public.json"
    chown builder:builder "$EXPORT_ROOT/300k.rsa" "$EXPORT_ROOT/300k.rsa.pub" "$EXPORT_ROOT/signing-public.json"
    chmod 0600 "$EXPORT_ROOT/300k.rsa"
    milestone "300K_SIGNING_KEY_READY $public_hash"
}

fetch_aports() {
    destination=$1
    remote=$(json_scalar remote "$INPUTS_FILE")
    commit=$(json_scalar commit "$INPUTS_FILE")
    branch=$(json_scalar branch "$INPUTS_FILE")
    rm -rf "$destination"
    git init -q "$destination"
    git -C "$destination" remote add origin "$remote"
    if ! git -C "$destination" fetch -q --depth=1 origin "$commit"; then
        git -C "$destination" fetch -q --depth=64 origin "$branch"
    fi
    git -C "$destination" checkout -q --detach "$commit" || fail APORTS_COMMIT_UNAVAILABLE "pinned aports commit is unavailable"
    [ "$(git -C "$destination" rev-parse HEAD)" = "$commit" ] || fail APORTS_COMMIT_MISMATCH "aports checkout differs from the pin"
    [ -z "$(git -C "$destination" status --porcelain)" ] || fail APORTS_CHECKOUT_DIRTY "aports checkout is dirty"
}

prepare_repository() {
    grep -F '"schema": "BuildRequest"' "$REQUEST_FILE" >/dev/null || fail BUILD_REQUEST_INVALID "expected BuildRequest"
    require_file "$SECRET_ROOT/300k.rsa"
    require_file "$SECRET_ROOT/300k.rsa.pub"
    request_hash=$(sha256_file "$REQUEST_FILE")
    prepare_root=$WORK_ROOT/prepare-$request_hash
    rm -rf "$prepare_root"
    mkdir -p "$prepare_root/pre-index" "$prepare_root/post-index" "$prepare_root/apks" "$prepare_root/repository" "$EXPORT_ROOT"

    download_and_verify_indexes "$prepare_root/pre-index"
    bootstrap_online_tools
    main_url=$(repository_value main url)
    community_url=$(repository_value community url)
    builder_packages=$(json_array_lines builder_packages "$INPUTS_FILE" | tr '\n' ' ')
    image_packages=$(json_array_lines requested_image_packages "$INPUTS_FILE" | tr '\n' ' ')
    online_repositories=$prepare_root/repositories.online
    online_cache=$prepare_root/apk-cache
    mkdir -p "$online_cache"
    printf '%s\n%s\n' "$main_url" "$community_url" > "$online_repositories"
    apk --cache-dir "$online_cache" --repositories-file "$online_repositories" update \
        || fail APK_INDEX_REFRESH_FAILED "isolated signed repository indexes could not be refreshed"
    apk --cache-dir "$online_cache" --repositories-file "$online_repositories" \
        fetch --recursive --output "$prepare_root/apks" \
        $builder_packages $image_packages \
        || fail APK_FETCH_FAILED "complete builder/image APK closure could not be fetched"

    apk_count=0
    for apk_file in "$prepare_root"/apks/*.apk; do
        require_file "$apk_file"
        apk verify "$apk_file" >/dev/null || fail APK_SIGNATURE_INVALID "a retained APK failed official signature verification"
        apk_count=$((apk_count + 1))
    done
    [ "$apk_count" -gt 0 ] || fail APK_CLOSURE_EMPTY "no retained APK bytes were resolved"

    fetch_aports "$prepare_root/aports"
    git -C "$prepare_root/aports" archive --format=tar HEAD > "$prepare_root/repository/aports.tar"
    require_file "$prepare_root/repository/aports.tar"

    download_and_verify_indexes "$prepare_root/post-index"
    cmp "$prepare_root/pre-index/APKINDEX.main.tar.gz" "$prepare_root/post-index/APKINDEX.main.tar.gz" >/dev/null || fail APKINDEX_DRIFT "main index changed during repository preparation"
    cmp "$prepare_root/pre-index/APKINDEX.community.tar.gz" "$prepare_root/post-index/APKINDEX.community.tar.gz" >/dev/null || fail APKINDEX_DRIFT "community index changed during repository preparation"

    cp "$prepare_root/pre-index/APKINDEX.main.tar.gz" "$prepare_root/repository/APKINDEX.main.tar.gz"
    cp "$prepare_root/pre-index/APKINDEX.community.tar.gz" "$prepare_root/repository/APKINDEX.community.tar.gz"
    cp "$prepare_root"/apks/*.apk "$prepare_root/repository/"
    apk index --rewrite-arch x86_64 -o "$prepare_root/repository/APKINDEX.tar.gz" "$prepare_root"/repository/*.apk \
        || fail LOCAL_APKINDEX_FAILED "local repository index generation failed"
    abuild-sign -k "$SECRET_ROOT/300k.rsa" "$prepare_root/repository/APKINDEX.tar.gz" \
        || fail LOCAL_APKINDEX_SIGN_FAILED "local repository index signing failed"
    emit_repository_manifest "$prepare_root/repository"
    verify_repository_snapshot "$prepare_root/repository"
    repository_object_id=$(sha256_file "$prepare_root/repository/repository.sha256")
    object_root=$CACHE_ROOT/repositories/$repository_object_id
    mkdir -p "$CACHE_ROOT/repositories"
    if [ -d "$object_root" ]; then
        verify_repository_snapshot "$object_root"
        cmp "$prepare_root/repository/repository.sha256" "$object_root/repository.sha256" >/dev/null || fail REPOSITORY_OBJECT_COLLISION "repository object identity collision"
    else
        mv "$prepare_root/repository" "$object_root.partial"
        mv "$object_root.partial" "$object_root"
    fi

    printf '%s\n' "$repository_object_id" > "$WORK_ROOT/repository-object-id"
    printf '%s\n' "$request_hash" > "$WORK_ROOT/build-request.sha256"
    (
        cd "$object_root"
        for apk_file in *.apk; do
            printf '%s  %s\n' "$(sha256sum "$apk_file" | awk '{print $1}')" "$apk_file"
        done | LC_ALL=C sort
    ) > "$EXPORT_ROOT/apk-files.sha256"
    cat > "$EXPORT_ROOT/repository-evidence.json" <<EOF
{
  "schema": "RepositoryEvidence",
  "schema_version": 1,
  "build_request_sha256": "$request_hash",
  "repository_object_id": "$repository_object_id",
  "apk_count": $apk_count,
  "official_indexes_verified": true,
  "official_signatures_verified": true,
  "content_addressed_snapshot_verified": true
}
EOF
    chown -R builder:builder "$EXPORT_ROOT"
    milestone "300K_REPOSITORY_READY $repository_object_id"
}

disable_network() {
    default_route=$(ip route show default 2>/dev/null || true)
    if [ -n "$default_route" ]; then ip route del default || fail NETWORK_DISABLE_FAILED "default route could not be removed"; fi
    : > /etc/resolv.conf
    [ -z "$(ip route show default 2>/dev/null || true)" ] || fail NETWORK_DISABLE_FAILED "default route remains"
    milestone 300K_NETWORK_DISABLED
}

verify_codec_round_trip() {
    root=$1
    format=$2
    fixture=/tmp/300k-inspection-fixture
    printf '300K deterministic inspection fixture\n' > "$root$fixture"
    case "$format" in
        gzip)
            chroot "$root" /bin/gzip -n -c -- "$fixture" > "$root$fixture.gz"
            chroot "$root" /bin/gzip -dc -- "$fixture.gz" > "$root$fixture.out"
            ;;
        xz)
            chroot "$root" /usr/bin/xz -zc --check=crc32 -- "$fixture" > "$root$fixture.xz"
            chroot "$root" /usr/bin/xz -dc --single-stream -- "$fixture.xz" > "$root$fixture.out"
            ;;
        zstd)
            chroot "$root" /usr/bin/zstd -q -c -- "$fixture" > "$root$fixture.zst"
            chroot "$root" /usr/bin/zstd -q -dc -- "$fixture.zst" > "$root$fixture.out"
            ;;
        lz4)
            chroot "$root" /usr/bin/lz4 -q -c -- "$fixture" > "$root$fixture.lz4"
            chroot "$root" /usr/bin/lz4 -q -d -c -- "$fixture.lz4" > "$root$fixture.out"
            ;;
        cpio)
            mkdir -p "$root/tmp/cpio-fixture"
            cp "$root$fixture" "$root/tmp/cpio-fixture/payload"
            chroot "$root" /bin/sh -ceu "cd /tmp/cpio-fixture; printf 'payload\\n' | /usr/bin/cpio --create --format=newc --reproducible --quiet" > "$root$fixture.cpio"
            chroot "$root" /usr/bin/cpio --extract --to-stdout --quiet payload < "$root$fixture.cpio" > "$root$fixture.out"
            ;;
        squashfs)
            mkdir -p "$root/tmp/squash-fixture"
            cp "$root$fixture" "$root/tmp/squash-fixture/payload"
            chroot "$root" /usr/bin/mksquashfs /tmp/squash-fixture "$fixture.sqfs" -noappend -no-xattrs -all-time 0 -quiet
            chroot "$root" /usr/bin/unsquashfs -cat "$fixture.sqfs" payload > "$root$fixture.out"
            ;;
        iso)
            mkdir -p "$root/tmp/iso-fixture"
            cp "$root$fixture" "$root/tmp/iso-fixture/payload"
            chroot "$root" /usr/bin/xorriso -as mkisofs -quiet -output "$fixture.iso" /tmp/iso-fixture
            chroot "$root" /usr/bin/xorriso -osirrox on:o_excl_on -indev "$fixture.iso" -extract_single /payload "$fixture.out" >/dev/null 2>&1
            ;;
        *) fail INSPECTION_FORMAT_UNSUPPORTED "unsupported inspection format" ;;
    esac
    cmp "$root$fixture" "$root$fixture.out" >/dev/null || fail INSPECTION_ROUND_TRIP_FAILED "$format deterministic round trip failed"
}

record_inspection_command() {
    root=$1
    format=$2
    package_pin=$3
    command_path=$4
    version_args=$5
    output_file=$6
    package_name=${package_pin%%=*}
    package_version=${package_pin#*=}
    expected_owner=$package_name-$package_version
    ownership=$(chroot "$root" apk info --who-owns "$command_path" 2>/dev/null || true)
    printf '%s' "$ownership" | grep -F "$expected_owner" >/dev/null || fail INSPECTION_OWNER_MISMATCH "$format command ownership mismatch"
    # version_args is fixed source-controlled text, never external input.
    version=$(chroot "$root" sh -ceu "$version_args" | head -n 1 | tr -cd '[:alnum:] ._+:/()-')
    [ -n "$version" ] || fail INSPECTION_VERSION_MISSING "$format version output is empty"
    verify_codec_round_trip "$root" "$format"
    command_hash=$(sha256_file "$root$command_path")
    if [ -s "$output_file" ]; then printf ',\n' >> "$output_file"; fi
    cat >> "$output_file" <<EOF
    {
      "format": "$format",
      "package": "$package_pin",
      "command": "$command_path",
      "command_sha256": "$command_hash",
      "version": "$(json_escape "$version")",
      "package_ownership_verified": true,
      "path_verified": true,
      "round_trip_verified": true
    }
EOF
}

build_from_local() {
    grep -F '"schema": "BuildRequest"' "$REQUEST_FILE" >/dev/null || fail BUILD_REQUEST_INVALID "expected BuildRequest"
    require_file "$WORK_ROOT/repository-object-id"
    require_file "$WORK_ROOT/build-request.sha256"
    repository_object_id=$(cat "$WORK_ROOT/repository-object-id")
    request_hash=$(sha256_file "$REQUEST_FILE")
    [ "$request_hash" = "$(cat "$WORK_ROOT/build-request.sha256")" ] || fail BUILD_REQUEST_HASH_CHANGED "BuildRequest changed between stages"
    object_root=$CACHE_ROOT/repositories/$repository_object_id
    verify_repository_snapshot "$object_root"

    if [ "$(printenv 300K_INJECT_REPOSITORY_DRIFT 2>/dev/null || true)" = 1 ]; then
        injected=$(find "$object_root" -maxdepth 1 -type f -name '*.apk' | LC_ALL=C sort | head -n 1)
        chmod u+w "$injected"
        printf 'injected-drift' >> "$injected"
    fi
    verify_repository_snapshot "$object_root"

    build_root=$WORK_ROOT/buildroots/$request_hash
    rm -rf "$build_root"
    mkdir -p "$build_root/etc/apk/keys" "$build_root/repo/x86_64" "$build_root/work" "$build_root/workspace" \
        "$build_root/export" "$build_root/run/300k-secrets" "$build_root/root/.mkimage" "$build_root/tmp"
    cp /etc/apk/keys/* "$build_root/etc/apk/keys/"
    cp "$SECRET_ROOT/300k.rsa.pub" "$build_root/etc/apk/keys/300k.rsa.pub"
    cp "$object_root"/* "$build_root/repo/x86_64/"
    cp "$SECRET_ROOT/300k.rsa" "$build_root/run/300k-secrets/300k.rsa"
    cp "$SECRET_ROOT/300k.rsa.pub" "$build_root/run/300k-secrets/300k.rsa.pub"
    chmod 0600 "$build_root/run/300k-secrets/300k.rsa"
    cp -a /workspace/. "$build_root/workspace/"
    mkdir -p "$build_root/work/aports"
    tar -xf "$object_root/aports.tar" -C "$build_root/work/aports"
    [ -f "$build_root/work/aports/scripts/mkimage.sh" ] || fail APORTS_ARCHIVE_INVALID "retained aports archive is incomplete"
    cp "$build_root/workspace/builder/profiles/mkimg.300k.sh" "$build_root/root/.mkimage/mkimg.300k.sh"

    repositories_file=$build_root/etc/apk/repositories
    printf '%s\n' 'file:///repo' > "$repositories_file"
    builder_packages=$(json_array_lines builder_packages "$INPUTS_FILE" | tr '\n' ' ')
    mkdir -p /repo
    mount --bind "$build_root/repo" /repo \
        || fail OFFLINE_REPOSITORY_MOUNT_FAILED "canonical local repository mount failed"
    # apk resolves --keys-dir with openat(root_fd, ...); a leading slash would
    # bypass the target root and silently load the builder guest's system keys.
    if ! apk --root "$build_root" --arch x86_64 --initdb --keys-dir etc/apk/keys \
        --repositories-file "$repositories_file" --no-network add $builder_packages; then
        umount /repo >/dev/null 2>&1 || true
        fail OFFLINE_INSTALL_FAILED "file-only network-disabled builder installation failed"
    fi
    umount /repo || fail OFFLINE_REPOSITORY_UNMOUNT_FAILED "canonical local repository unmount failed"
    rmdir /repo
    apk --root "$build_root" --no-network list --installed --manifest | LC_ALL=C sort > "$EXPORT_ROOT/builder-packages.lock"
    require_file "$EXPORT_ROOT/builder-packages.lock"
    cp /etc/resolv.conf "$build_root/etc/resolv.conf" 2>/dev/null || true

    inspection_file=$WORK_ROOT/inspection-commands.json.items
    : > "$inspection_file"
    record_inspection_command "$build_root" gzip 'gzip=1.14-r2' /bin/gzip '/bin/gzip --version' "$inspection_file"
    record_inspection_command "$build_root" xz 'xz=5.8.3-r0' /usr/bin/xz '/usr/bin/xz --version' "$inspection_file"
    record_inspection_command "$build_root" zstd 'zstd=1.5.7-r2' /usr/bin/zstd '/usr/bin/zstd --version' "$inspection_file"
    record_inspection_command "$build_root" lz4 'lz4=1.10.0-r1' /usr/bin/lz4 '/usr/bin/lz4 --version' "$inspection_file"
    record_inspection_command "$build_root" cpio 'cpio=2.15-r0' /usr/bin/cpio '/usr/bin/cpio --version' "$inspection_file"
    record_inspection_command "$build_root" squashfs 'squashfs-tools=4.7.5-r0' /usr/bin/unsquashfs '/usr/bin/unsquashfs -version' "$inspection_file"
    record_inspection_command "$build_root" iso 'xorriso=1.5.8-r0' /usr/bin/xorriso '/usr/bin/xorriso -version' "$inspection_file"

    verify_repository_snapshot "$object_root"
    disable_network
    verify_repository_snapshot "$object_root"
    source_date_epoch=$(json_scalar source_date_epoch "$REQUEST_FILE")
    case "$source_date_epoch" in ''|0|*[!0-9]*) fail SOURCE_DATE_EPOCH_INVALID "BuildRequest epoch is invalid" ;; esac
    chroot "$build_root" env -i \
        HOME=/root \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        SOURCE_DATE_EPOCH="$source_date_epoch" \
        PACKAGER_PRIVKEY=/run/300k-secrets/300k.rsa \
        PACKAGER_PUBKEY=/run/300k-secrets/300k.rsa.pub \
        /bin/sh /work/aports/scripts/mkimage.sh \
            --tag "p01-${request_hash%${request_hash#????????????}}" \
            --outdir /export/raw \
            --workdir "/work/mkimage/$request_hash" \
            --arch x86_64 \
            --repository file:///repo \
            --profile 300k_bootstrap \
            --checksum \
        || fail MKIMAGE_FAILED "pinned offline aports build failed"
    verify_repository_snapshot "$object_root"

    iso_in_root=$(find "$build_root/export/raw" -maxdepth 1 -type f -name '*.iso' | LC_ALL=C sort | head -n 1)
    require_file "$iso_in_root"
    iso_hash=$(sha256_file "$iso_in_root")
    iso_name=300k-bootstrap-x86_64-$(printf '%s' "$iso_hash" | cut -c1-12).iso
    cp "$iso_in_root" "$EXPORT_ROOT/$iso_name"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -pvd_info > "$EXPORT_ROOT/boot-layout.txt"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -report_el_torito plain >> "$EXPORT_ROOT/boot-layout.txt"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -report_el_torito as_mkisofs >> "$EXPORT_ROOT/boot-layout.txt"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -report_system_area plain >> "$EXPORT_ROOT/boot-layout.txt"
    require_file "$EXPORT_ROOT/boot-layout.txt"

    builder_hash=$(sha256_file "$EXPORT_ROOT/builder-packages.lock")
    builder_bytes=$(file_bytes "$EXPORT_ROOT/builder-packages.lock")
    apk_hashes_hash=$(sha256_file "$EXPORT_ROOT/apk-files.sha256")
    apk_hashes_bytes=$(file_bytes "$EXPORT_ROOT/apk-files.sha256")
    iso_bytes=$(file_bytes "$EXPORT_ROOT/$iso_name")
    main_hash=$(repository_value main apkindex_sha256)
    community_hash=$(repository_value community apkindex_sha256)
    cat > "$EXPORT_ROOT/resolved-build-lock.json.partial" <<EOF
{
  "schema": "ResolvedBuildLock",
  "schema_version": 1,
  "build_request_sha256": "$request_hash",
  "repository_object_id": "$repository_object_id",
  "repository_indexes": [
    {"name": "main", "sha256": "$main_hash", "signature_verified": true},
    {"name": "community", "sha256": "$community_hash", "signature_verified": true}
  ],
  "aports": {"commit": "52643b7a176095362fd87fe73cdb994cb2e5ffae", "archive_sha256": "$(sha256_file "$object_root/aports.tar")"},
  "builder_packages_record": {
    "file": "builder-packages.lock",
    "sha256": "$builder_hash",
    "bytes": $builder_bytes,
    "producer": "run-build.sh:prepare-repository",
    "validator": "build.ps1:Test-GeneratedFileRecord"
  },
  "apk_files_record": {
    "file": "apk-files.sha256",
    "sha256": "$apk_hashes_hash",
    "bytes": $apk_hashes_bytes,
    "producer": "run-build.sh:prepare-repository",
    "validator": "build.ps1:Test-GeneratedFileRecord"
  },
  "inspection_commands": [
$(cat "$inspection_file")
  ],
  "offline_install": {"repositories": ["file:///repo"], "apk_no_network": true, "network_disabled": true, "complete_manifest_verified": true},
  "artifacts": [
    {"role": "bootstrap_iso", "file": "$iso_name", "sha256": "$iso_hash", "bytes": $iso_bytes}
  ]
}
EOF
    mv "$EXPORT_ROOT/resolved-build-lock.json.partial" "$EXPORT_ROOT/resolved-build-lock.json"
    chown -R builder:builder "$EXPORT_ROOT"
    milestone "300K_BUILD_COMPLETE $iso_hash"
}

require_public_contract
case "$MODE" in
    init-signing-key)
        init_signing_key
        ;;
    prepare-repository)
        prepare_repository
        ;;
    build-from-local)
        build_from_local
        ;;
    prepare-repository-and-build)
        prepare_repository
        build_from_local
        ;;
    *)
        fail BUILD_MODE_INVALID "expected init-signing-key, prepare-repository, or build-from-local"
        ;;
esac
