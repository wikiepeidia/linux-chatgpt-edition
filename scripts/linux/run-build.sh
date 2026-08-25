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
ACTIVE_BUILD_ROOT=

cleanup_sensitive_build_state() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$ACTIVE_BUILD_ROOT" ]; then
        case "$ACTIVE_BUILD_ROOT" in
            "$WORK_ROOT"/buildroots/*)
                if [ -d "$ACTIVE_BUILD_ROOT/run/300k-secrets" ] && [ ! -L "$ACTIVE_BUILD_ROOT/run/300k-secrets" ]; then
                    rm -f -- "$ACTIVE_BUILD_ROOT/run/300k-secrets/300k.rsa" "$ACTIVE_BUILD_ROOT/run/300k-secrets/300k.rsa.pub" 2>/dev/null || true
                fi
                ;;
            *) printf '%s\n' 'BUILD_SECRET_CLEANUP_REFUSED: active build root is outside the owned buildroots directory' >&2 ;;
        esac
    fi
    exit "$status"
}
trap cleanup_sensitive_build_state EXIT HUP INT TERM

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

json_object_lines() {
    key=$1
    file=$2
    awk -v wanted="\"$key\"" '
        index($0, wanted) { inside=1; next }
        inside && /^[[:space:]]*}/ { exit }
        inside {
            line=$0
            sub(/^[[:space:]]*"/, "", line)
            split(line, parts, /"[[:space:]]*:[[:space:]]*"/)
            name=parts[1]
            value=parts[2]
            sub(/",?[[:space:]]*$/, "", value)
            if (length(name) > 0 && length(value) > 0) print name "\t" value
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

inspection_value() {
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

inspection_array_first() {
    format=$1
    field=$2
    awk -v object="\"$format\"" -v wanted="\"$field\"" '
        index($0, object) && /[{][[:space:]]*$/ { inside=1; next }
        inside && /^[[:space:]]*}[,]?[[:space:]]*$/ { exit }
        inside && index($0, wanted) {
            line=$0
            sub(/^[^[]*\[[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
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
    grep -F '"package": "busybox=1.37.0-r31"' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "tar decoder package pin missing"
    grep -F '"package": "apk-tools=3.0.7-r0"' "$INPUTS_FILE" >/dev/null || fail INPUT_TOOLCHAIN_MISSING "APK decoder package pin missing"
    grep -F '"max_depth": 8' "$INPUTS_FILE" >/dev/null || fail INPUT_INSPECTION_POLICY_INVALID "inspection depth policy changed"
    grep -F '"max_members": 200000' "$INPUTS_FILE" >/dev/null || fail INPUT_INSPECTION_POLICY_INVALID "inspection member policy changed"
    grep -F '"max_path_bytes": 4096' "$INPUTS_FILE" >/dev/null || fail INPUT_INSPECTION_POLICY_INVALID "inspection path policy changed"
    grep -F '"max_file_bytes": 1073741824' "$INPUTS_FILE" >/dev/null || fail INPUT_INSPECTION_POLICY_INVALID "inspection file policy changed"
    grep -F '"max_total_expanded_bytes": 4294967296' "$INPUTS_FILE" >/dev/null || fail INPUT_INSPECTION_POLICY_INVALID "inspection expansion policy changed"
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

verify_closed_keyring() {
    destination=$1
    manifest=$2
    require_file "$manifest"
    expected_names=$WORK_ROOT/trusted-key-names.expected
    actual_names=$WORK_ROOT/trusted-key-names.actual
    : > "$expected_names"
    seen=0
    while IFS='  ' read -r expected basename; do
        [ -n "$expected" ] || continue
        printf '%s' "$basename" | grep -Eq '^(alpine-devel@lists\.alpinelinux\.org-[0-9a-f]{8}|300k)\.rsa\.pub$' \
            || fail TRUSTED_KEY_BASENAME_INVALID "trusted key basename is unsafe"
        [ "${#expected}" -eq 64 ] && printf '%s' "$expected" | grep -Eq '^[0-9a-f]+$' \
            || fail TRUSTED_KEY_HASH_INVALID "trusted key SHA-256 is malformed"
        require_file "$destination/$basename"
        [ ! -L "$destination/$basename" ] || fail TRUSTED_KEY_TYPE_INVALID "trusted key may not be a symlink"
        [ "$(sha256_file "$destination/$basename")" = "$expected" ] \
            || fail TRUSTED_KEY_HASH_MISMATCH "trusted key bytes differ from the public allowlist"
        printf '%s\n' "$basename" >> "$expected_names"
        seen=$((seen + 1))
    done < "$manifest"
    [ "$seen" -eq 4 ] || fail TRUSTED_KEY_SET_INVALID "closed keyring must contain three Alpine keys and one project key"
    : > "$actual_names"
    for path in "$destination"/*; do
        [ -f "$path" ] || fail TRUSTED_KEY_TYPE_INVALID "closed keyring contains a non-file entry"
        [ ! -L "$path" ] || fail TRUSTED_KEY_TYPE_INVALID "closed keyring contains a symlink"
        basename "$path" >> "$actual_names"
    done
    LC_ALL=C sort "$actual_names" > "$actual_names.sorted"
    LC_ALL=C sort "$expected_names" > "$expected_names.sorted"
    cmp "$expected_names.sorted" "$actual_names.sorted" >/dev/null \
        || fail TRUSTED_KEY_SET_INVALID "closed keyring contains an unapproved or missing key"
}

stage_closed_keyring() {
    destination=$1
    trusted_items=$2
    manifest=$3
    records=$WORK_ROOT/repository-keys.records
    rm -rf "$destination"
    mkdir -p "$destination"
    json_object_lines repository_keys "$INPUTS_FILE" > "$records"
    : > "$trusted_items"
    : > "$manifest.partial"
    repository_key_count=0
    tab=$(printf '\t')
    while IFS="$tab" read -r basename expected; do
        [ -n "$basename" ] || continue
        printf '%s' "$basename" | grep -Eq '^alpine-devel@lists\.alpinelinux\.org-[0-9a-f]{8}\.rsa\.pub$' \
            || fail TRUSTED_KEY_BASENAME_INVALID "Alpine repository-key basename is unsafe"
        [ "${#expected}" -eq 64 ] && printf '%s' "$expected" | grep -Eq '^[0-9a-f]+$' \
            || fail TRUSTED_KEY_HASH_INVALID "Alpine repository-key SHA-256 is malformed"
        source=/etc/apk/keys/$basename
        require_file "$source"
        [ ! -L "$source" ] || fail TRUSTED_KEY_TYPE_INVALID "Alpine repository-key source may not be a symlink"
        [ "$(sha256_file "$source")" = "$expected" ] \
            || fail TRUSTED_KEY_HASH_MISMATCH "Alpine repository-key bytes differ from the pinned aports source"
        install -m 0644 "$source" "$destination/$basename"
        printf '%s  %s\n' "$expected" "$basename" >> "$manifest.partial"
        if [ -s "$trusted_items" ]; then printf ',\n' >> "$trusted_items"; fi
        printf '    {"file": "%s", "sha256": "%s", "trust": "alpine-x86_64"}' "$basename" "$expected" >> "$trusted_items"
        repository_key_count=$((repository_key_count + 1))
    done < "$records"
    [ "$repository_key_count" -eq 3 ] \
        || fail TRUSTED_KEY_SET_INVALID "public inputs must pin exactly three Alpine x86_64 repository keys"

    project_hash=$(json_scalar public_key_sha256 "$REQUEST_FILE")
    [ "${#project_hash}" -eq 64 ] && printf '%s' "$project_hash" | grep -Eq '^[0-9a-f]+$' \
        || fail TRUSTED_KEY_HASH_INVALID "BuildRequest project signing-key SHA-256 is malformed"
    require_file "$SECRET_ROOT/300k.rsa.pub"
    [ "$(sha256_file "$SECRET_ROOT/300k.rsa.pub")" = "$project_hash" ] \
        || fail TRUSTED_KEY_HASH_MISMATCH "project public key differs from BuildRequest"
    install -m 0644 "$SECRET_ROOT/300k.rsa.pub" "$destination/300k.rsa.pub"
    printf '%s  %s\n' "$project_hash" 300k.rsa.pub >> "$manifest.partial"
    if [ -s "$trusted_items" ]; then printf ',\n' >> "$trusted_items"; fi
    printf '    {"file": "300k.rsa.pub", "sha256": "%s", "trust": "project-signing"}' "$project_hash" >> "$trusted_items"
    mv "$manifest.partial" "$manifest"
    verify_closed_keyring "$destination" "$manifest"
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
    rm -rf "$root/tmp/cpio-fixture" "$root/tmp/squash-fixture" "$root/tmp/iso-fixture" "$root/tmp/tar-fixture"
    rm -f "$root$fixture" "$root$fixture".*
    printf '300K deterministic inspection fixture\n' > "$root$fixture"
    command_path=$(inspection_value "$format" command)
    encoder_path=$(inspection_array_first "$format" fixture_encoder)
    case "$format" in
        gzip)
            chroot "$root" "$encoder_path" -n -c -- "$fixture" > "$root$fixture.gz"
            chroot "$root" "$command_path" -dc -- "$fixture.gz" > "$root$fixture.out"
            ;;
        xz)
            chroot "$root" "$encoder_path" -zc --check=crc32 -- "$fixture" > "$root$fixture.xz"
            chroot "$root" "$command_path" -dc -- "$fixture.xz" > "$root$fixture.out"
            ;;
        zstd)
            chroot "$root" "$encoder_path" -q -c -- "$fixture" > "$root$fixture.zst"
            chroot "$root" "$command_path" -q -dc -- "$fixture.zst" > "$root$fixture.out"
            ;;
        lz4)
            chroot "$root" "$encoder_path" -q -c -- "$fixture" > "$root$fixture.lz4"
            chroot "$root" "$command_path" -q -d -c -- "$fixture.lz4" > "$root$fixture.out"
            ;;
        cpio)
            mkdir -p "$root/tmp/cpio-fixture"
            cp "$root$fixture" "$root/tmp/cpio-fixture/payload"
            chroot "$root" /bin/sh -ceu "cd /tmp/cpio-fixture; printf 'payload\\n' | $encoder_path --create --format=newc --reproducible --quiet" > "$root$fixture.cpio"
            chroot "$root" "$command_path" --extract --to-stdout --quiet payload < "$root$fixture.cpio" > "$root$fixture.out"
            ;;
        squashfs)
            mkdir -p "$root/tmp/squash-fixture"
            cp "$root$fixture" "$root/tmp/squash-fixture/payload"
            chroot "$root" "$encoder_path" /tmp/squash-fixture "$fixture.sqfs" -noappend -no-xattrs -all-time 0 -quiet
            chroot "$root" "$command_path" -cat "$fixture.sqfs" payload > "$root$fixture.out"
            ;;
        iso)
            mkdir -p "$root/tmp/iso-fixture"
            cp "$root$fixture" "$root/tmp/iso-fixture/payload"
            chroot "$root" "$encoder_path" -as mkisofs -quiet -output "$fixture.iso" /tmp/iso-fixture
            chroot "$root" "$command_path" -osirrox on:o_excl_on -indev "$fixture.iso" -extract_single /payload "$fixture.out" >/dev/null 2>&1
            ;;
        tar)
            mkdir -p "$root/tmp/tar-fixture"
            cp "$root$fixture" "$root/tmp/tar-fixture/payload"
            chroot "$root" /bin/sh -ceu "cd /tmp/tar-fixture; $encoder_path -cf $fixture.tar payload"
            chroot "$root" "$command_path" -xOf "$fixture.tar" payload > "$root$fixture.out"
            ;;
        apk)
            mkdir -p "$root/tmp/tar-fixture"
            cp "$root$fixture" "$root/tmp/tar-fixture/payload"
            tar_path=$(inspection_value tar command)
            gzip_path=$(inspection_value gzip command)
            chroot "$root" /bin/sh -ceu "cd /tmp/tar-fixture; $tar_path -cf $fixture.tar payload; $gzip_path -n -c -- $fixture.tar > $fixture.apk; $gzip_path -dc -- $fixture.apk | $tar_path -xOf - payload" > "$root$fixture.out"
            ;;
        *) fail INSPECTION_FORMAT_UNSUPPORTED "unsupported inspection format" ;;
    esac
    cmp "$root$fixture" "$root$fixture.out" >/dev/null || fail INSPECTION_ROUND_TRIP_FAILED "$format deterministic round trip failed"
}

record_inspection_command() {
    root=$1
    format=$2
    output_file=$3
    repository=$4
    package_pin=$(inspection_value "$format" package)
    command_path=$(inspection_value "$format" command)
    [ -n "$package_pin" ] && [ -n "$command_path" ] \
        || fail INSPECTION_CONFIG_INVALID "$format package/path is absent from inspection_toolchain"
    package_name=${package_pin%%=*}
    package_version=${package_pin#*=}
    expected_owner=$package_name-$package_version
    resolved_command=$(chroot "$root" readlink -f "$command_path" 2>/dev/null || true)
    case "$resolved_command" in
        /*) ;;
        *) fail INSPECTION_PATH_RESOLUTION_FAILED "$format command did not resolve to one absolute chroot path" ;;
    esac
    ownership=$(chroot "$root" apk info -W "$resolved_command" 2>/dev/null || true)
    printf '%s' "$ownership" | grep -F "$expected_owner" >/dev/null || fail INSPECTION_OWNER_MISMATCH "$format command ownership mismatch"
    case "$format" in
        squashfs|iso) version=$(chroot "$root" "$command_path" -version 2>&1 | head -n 1 | tr -cd '[:alnum:] ._+:/()-') ;;
        tar) version=$(chroot "$root" /bin/busybox 2>&1 | head -n 1 | tr -cd '[:alnum:] ._+:/()-') ;;
        *) version=$(chroot "$root" "$command_path" --version 2>&1 | head -n 1 | tr -cd '[:alnum:] ._+:/()-') ;;
    esac
    [ -n "$version" ] || fail INSPECTION_VERSION_MISSING "$format version output is empty"
    verify_codec_round_trip "$root" "$format"
    command_hash=$(chroot "$root" sha256sum "$command_path" | awk '{print $1}')
    retained_apk=$(find "$repository" -maxdepth 1 -type f -name "$package_name-$package_version.apk" | LC_ALL=C sort | head -n 1)
    require_file "$retained_apk"
    retained_basename=$(basename "$retained_apk")
    retained_hash=$(sha256_file "$retained_apk")
    grep -F "$retained_hash  $retained_basename" "$repository/repository.sha256" >/dev/null \
        || fail INSPECTION_RETAINED_APK_DRIFT "$format package is absent from the verified repository manifest"
    if [ -s "$output_file" ]; then printf ',\n' >> "$output_file"; fi
    cat >> "$output_file" <<EOF
    {
      "format": "$format",
      "package": "$package_pin",
      "command": "$command_path",
      "command_sha256": "$command_hash",
      "version": "$(json_escape "$version")",
      "retained_apk_file": "$retained_basename",
      "retained_apk_sha256": "$retained_hash",
      "package_ownership_verified": true,
      "path_verified": true,
      "round_trip_verified": true,
      "retained_apk_verified": true,
      "contract_source": "builder/inputs.json:inspection_toolchain",
      "retained_repository": "$repository_object_id"
    }
EOF
}

assert_inspection_toolchain_identity() {
    root=$1
    repository=$2
    evidence=$3
    seen=0
    for format in gzip xz zstd lz4 cpio squashfs iso tar apk; do
        package_pin=$(inspection_value "$format" package)
        command_path=$(inspection_value "$format" command)
        retained_basename=$(awk -v wanted="\"format\": \"$format\"" '
            index($0,wanted) { inside=1 }
            inside && /"retained_apk_file"/ { line=$0; sub(/^[^:]*:[[:space:]]*"/,"",line); sub(/",?[[:space:]]*$/, "", line); print line; exit }
        ' "$evidence")
        retained_hash=$(awk -v wanted="\"format\": \"$format\"" '
            index($0,wanted) { inside=1 }
            inside && /"retained_apk_sha256"/ { line=$0; sub(/^[^:]*:[[:space:]]*"/,"",line); sub(/",?[[:space:]]*$/, "", line); print line; exit }
        ' "$evidence")
        grep -F "\"package\": \"$package_pin\"" "$evidence" >/dev/null \
            || fail INSPECTION_EVIDENCE_MISMATCH "$format package evidence is absent"
        grep -F "\"command\": \"$command_path\"" "$evidence" >/dev/null \
            || fail INSPECTION_EVIDENCE_MISMATCH "$format command evidence is absent"
        require_file "$root$command_path"
        require_file "$repository/$retained_basename"
        [ "$(sha256_file "$repository/$retained_basename")" = "$retained_hash" ] \
            || fail INSPECTION_RETAINED_APK_DRIFT "$format retained APK changed before inspection"
        seen=$((seen + 1))
    done
    [ "$seen" -eq 9 ] || fail INSPECTION_TOOLCHAIN_SET_INVALID "inspection evidence is incomplete"
}

run_inspector_self_test() {
    root=$1
    chroot "$root" /bin/sh /workspace/scripts/linux/inspect-iso.sh self-test /work/inspection-self-test \
        > "$root/work/inspector-self-test.log" 2>&1 \
        || { tail -n 80 "$root/work/inspector-self-test.log" >&2 || true; fail INSPECTION_SELF_TEST_FAILED "hostile compressed-layer fixture suite failed"; }
    grep -F '300K_INSPECTOR_SELF_TEST_PASS' "$root/work/inspector-self-test.log" >/dev/null \
        || fail INSPECTION_SELF_TEST_FAILED "hostile fixture suite returned no non-vacuous pass marker"
    printf '%s\n' passed > "$root/work/inspector-self-test.passed"
}

inspect_iso_artifact() {
    root=$1
    iso=$2
    chroot "$root" /bin/sh /workspace/scripts/linux/inspect-iso.sh audit "$iso" /work/inspection-audit /export/iso-audit.json \
        || fail ISO_DECODE_AUDIT_FAILED "settled ISO failed recursive decoded-content inspection"
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
    ACTIVE_BUILD_ROOT=$build_root
    builder_user=builder
    builder_uid=1000
    builder_gid=1000
    rm -rf "$build_root"
    mkdir -p "$build_root/repo/x86_64" "$build_root/work" "$build_root/workspace" \
        "$build_root/export" "$build_root/run/300k-secrets" "$build_root/home/$builder_user/.mkimage" \
        "$build_root/tmp" "$build_root/proc" "$build_root/dev"
    trusted_key_items=$WORK_ROOT/trusted-keys.json.items
    trusted_key_manifest=$WORK_ROOT/trusted-keys.sha256
    stage_closed_keyring "$build_root/etc/apk/keys" "$trusted_key_items" "$trusted_key_manifest"
    cp "$object_root"/* "$build_root/repo/x86_64/"
    cp "$SECRET_ROOT/300k.rsa" "$build_root/run/300k-secrets/300k.rsa"
    cp "$SECRET_ROOT/300k.rsa.pub" "$build_root/run/300k-secrets/300k.rsa.pub"
    chmod 0600 "$build_root/run/300k-secrets/300k.rsa"
    cp -a /workspace/. "$build_root/workspace/"
    require_file "$build_root/workspace/scripts/linux/inspect-iso.sh"
    mkdir -p "$build_root/work/aports"
    tar -xf "$object_root/aports.tar" -C "$build_root/work/aports"
    [ -f "$build_root/work/aports/scripts/mkimage.sh" ] || fail APORTS_ARCHIVE_INVALID "retained aports archive is incomplete"
    cp "$build_root/workspace/builder/profiles/mkimg.300k.sh" "$build_root/home/$builder_user/.mkimage/mkimg.300k.sh"

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
    # The intentionally minimal builder closure has no baselayout account
    # database. Define only the fixed identities needed for the uid transition.
    printf '%s\n' \
        'root:x:0:0:root:/root:/bin/sh' \
        "$builder_user:x:$builder_uid:$builder_gid:300K build user:/home/$builder_user:/bin/sh" \
        > "$build_root/etc/passwd"
    printf '%s\n' \
        'root:x:0:' \
        "$builder_user:x:$builder_gid:" \
        > "$build_root/etc/group"
    chmod 0644 "$build_root/etc/passwd" "$build_root/etc/group"
    mkdir -p "$build_root/work/mkimage" "$build_root/export/raw"
    chmod 0755 "$build_root" "$build_root/home" "$build_root/work" "$build_root/run"
    # The outer umask protects generated state, but package payload modes still
    # need their declared read/execute classes for the non-root image builder.
    chmod -R a+rX "$build_root/bin" "$build_root/sbin" "$build_root/lib" "$build_root/usr" "$build_root/etc"
    # aports fetches with --link. Ownership permits protected hardlinks while
    # read-only modes plus before/after manifests keep retained bytes fail-closed.
    chown -R "$builder_uid:$builder_gid" "$build_root/repo"
    chmod -R a-w,a+rX "$build_root/repo" "$build_root/work/aports" "$build_root/workspace"
    chown -R "$builder_uid:$builder_gid" \
        "$build_root/home/$builder_user" "$build_root/work/mkimage" "$build_root/export"
    chown -R "$builder_uid:$builder_gid" "$build_root/run/300k-secrets"
    chmod 0700 "$build_root/run/300k-secrets"
    chmod 0600 "$build_root/run/300k-secrets/300k.rsa" "$build_root/run/300k-secrets/300k.rsa.pub"
    chmod 0700 "$build_root/home/$builder_user/.mkimage"
    chmod 1777 "$build_root/tmp"
    apk --root "$build_root" --no-network list --installed --manifest | LC_ALL=C sort > "$EXPORT_ROOT/builder-packages.lock"
    require_file "$EXPORT_ROOT/builder-packages.lock"
    cp /etc/resolv.conf "$build_root/etc/resolv.conf" 2>/dev/null || true

    inspection_file=$WORK_ROOT/inspection-commands.json.items
    : > "$inspection_file"
    for inspection_format in gzip xz zstd lz4 cpio squashfs iso tar apk; do
        record_inspection_command "$build_root" "$inspection_format" "$inspection_file" "$object_root"
    done

    verify_repository_snapshot "$build_root/repo/x86_64"
    verify_repository_snapshot "$object_root"
    assert_inspection_toolchain_identity "$build_root" "$object_root" "$inspection_file"
    cp "$inspection_file" "$build_root/work/inspection-commands.json.items"
    cp "$trusted_key_manifest" "$build_root/work/trusted-keys.sha256"
    disable_network
    verify_repository_snapshot "$build_root/repo/x86_64"
    verify_repository_snapshot "$object_root"
    verify_closed_keyring "$build_root/etc/apk/keys" "$trusted_key_manifest"
    run_inspector_self_test "$build_root"
    source_date_epoch=$(json_scalar source_date_epoch "$REQUEST_FILE")
    case "$source_date_epoch" in ''|0|*[!0-9]*) fail SOURCE_DATE_EPOCH_INVALID "BuildRequest epoch is invalid" ;; esac
    release_tag=p01-${request_hash%${request_hash#????????????}}
    mkimage_workdir=/work/mkimage/$request_hash
    # Pinned aports commit 52643b7 copies /etc/apk/keys into its inner APKROOT
    # only with --hostkeys. The buildroot key directory above is an exact,
    # hash-verified four-key allowlist, so no ambient guest key crosses here.
    mkimage_command="exec /usr/bin/env -i HOME=/home/$builder_user PATH=/usr/sbin:/usr/bin:/sbin:/bin CBUILD=x86_64 SOURCE_DATE_EPOCH=$source_date_epoch PACKAGER_PRIVKEY=/run/300k-secrets/300k.rsa PACKAGER_PUBKEY=/run/300k-secrets/300k.rsa.pub /bin/sh /work/aports/scripts/mkimage.sh --tag $release_tag --outdir /export/raw --workdir $mkimage_workdir --arch x86_64 --hostkeys --repository file:///repo --profile 300k_bootstrap --checksum"
    # Pinned aports uses apk add --no-chown for its APKROOT. apk-tools 3 maps
    # that option to usermode and rejects uid 0, so run mkimage as its sole
    # dedicated owner rather than weakening package verification.
    mount --bind /proc "$build_root/proc" \
        || fail MKIMAGE_PROC_MOUNT_FAILED "builder proc mount failed"
    if ! mount --bind /dev "$build_root/dev"; then
        umount "$build_root/proc" >/dev/null 2>&1 || true
        fail MKIMAGE_DEV_MOUNT_FAILED "builder device mount failed"
    fi
    mkimage_status=0
    mkimage_log=$build_root/tmp/300k-mkimage.log
    builder_probe='test "$(id -u)" = 1000 && test -x /bin/sh && test "$(/sbin/apk --print-arch)" = x86_64 && test -r /repo/x86_64/APKINDEX.tar.gz && test -r /run/300k-secrets/300k.rsa && test -w /work/mkimage && test -w /export/raw'
    if ! chroot "$build_root" /bin/su -s /bin/sh -c "$builder_probe" "$builder_user"; then
        mkimage_status=126
    else
        chroot "$build_root" /bin/su -s /bin/sh -c "$mkimage_command" "$builder_user" \
            > "$mkimage_log" 2>&1 \
            || mkimage_status=$?
    fi
    mount_cleanup_status=0
    umount "$build_root/dev" || mount_cleanup_status=1
    umount "$build_root/proc" || mount_cleanup_status=1
    [ "$mount_cleanup_status" -eq 0 ] \
        || fail MKIMAGE_MOUNT_CLEANUP_FAILED "builder proc/device cleanup failed"
    [ "$mkimage_status" -ne 126 ] \
        || fail MKIMAGE_IDENTITY_INVALID "builder uid or path permissions are invalid"
    if [ "$mkimage_status" -ne 0 ]; then
        tail -n 80 "$mkimage_log" >&2 || true
        fail MKIMAGE_FAILED "pinned offline aports build failed"
    fi
    verify_repository_snapshot "$build_root/repo/x86_64"
    verify_repository_snapshot "$object_root"

    iso_in_root=$(find "$build_root/export/raw" -maxdepth 1 -type f -name '*.iso' | LC_ALL=C sort | head -n 1)
    require_file "$iso_in_root"
    iso_hash=$(sha256_file "$iso_in_root")
    iso_name=300k-bootstrap-x86_64-$(printf '%s' "$iso_hash" | cut -c1-12).iso
    inspect_iso_artifact "$build_root" "${iso_in_root#$build_root}"
    require_file "$build_root/export/iso-audit.json"
    grep -F "\"iso_sha256\": \"$iso_hash\"" "$build_root/export/iso-audit.json" >/dev/null \
        || fail ISO_AUDIT_HASH_MISMATCH "decoded audit does not identify the settled ISO bytes"
    grep -F '"result": "pass"' "$build_root/export/iso-audit.json" >/dev/null \
        || fail ISO_AUDIT_RESULT_INVALID "decoded audit is not a successful result"
    cp "$iso_in_root" "$EXPORT_ROOT/$iso_name"
    cp "$build_root/export/iso-audit.json" "$EXPORT_ROOT/iso-audit.json"
    printf '%s  %s\n' "$iso_hash" "$iso_name" > "$EXPORT_ROOT/SHA256SUMS"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -pvd_info > "$EXPORT_ROOT/boot-layout.txt"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -report_el_torito plain >> "$EXPORT_ROOT/boot-layout.txt"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -report_el_torito as_mkisofs >> "$EXPORT_ROOT/boot-layout.txt"
    chroot "$build_root" /usr/bin/xorriso -indev "${iso_in_root#$build_root}" -report_system_area plain >> "$EXPORT_ROOT/boot-layout.txt"
    require_file "$EXPORT_ROOT/boot-layout.txt"

    builder_hash=$(sha256_file "$EXPORT_ROOT/builder-packages.lock")
    builder_bytes=$(file_bytes "$EXPORT_ROOT/builder-packages.lock")
    apk_hashes_hash=$(sha256_file "$EXPORT_ROOT/apk-files.sha256")
    apk_hashes_bytes=$(file_bytes "$EXPORT_ROOT/apk-files.sha256")
    audit_hash=$(sha256_file "$EXPORT_ROOT/iso-audit.json")
    audit_bytes=$(file_bytes "$EXPORT_ROOT/iso-audit.json")
    checksums_hash=$(sha256_file "$EXPORT_ROOT/SHA256SUMS")
    checksums_bytes=$(file_bytes "$EXPORT_ROOT/SHA256SUMS")
    inspection_hash=$(sha256_file "$inspection_file")
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
  "trusted_keys": [
$(cat "$trusted_key_items")
  ],
  "trust_policy": {"mkimage_hostkeys": true, "closed_keyring_verified": true, "signature_bypass": false},
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
  "inspection_toolchain_sha256": "$inspection_hash",
  "offline_install": {"repositories": ["file:///repo"], "apk_no_network": true, "network_disabled": true, "complete_manifest_verified": true},
  "artifacts": [
    {"role": "bootstrap_iso", "file": "$iso_name", "sha256": "$iso_hash", "bytes": $iso_bytes},
    {"role": "decoded_iso_audit", "file": "iso-audit.json", "sha256": "$audit_hash", "bytes": $audit_bytes},
    {"role": "iso_checksums", "file": "SHA256SUMS", "sha256": "$checksums_hash", "bytes": $checksums_bytes}
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
