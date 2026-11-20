#!/usr/bin/env bash
# Stage "fetch" (tools container): downloads every pinned upstream input into /work/src and
# verifies its SHA-256 (incl. the pinned Debian glibc source package and libc6 .deb);
# checks out box64 at the pinned commit.
PB_LOG_PREFIX=fetch
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$SRC"' EXIT
need_cmd curl sha256sum git

mkdir -p "$SRC"

fetch "$LIBXCB_URL" "$LIBXCB_SHA256" "$SRC/libxcb-$LIBXCB_VERSION.tar.xz"
fetch "$MESA_URL" "$MESA_SHA256" "$SRC/mesa-$MESA_VERSION.tar.xz"
fetch "$DXVK_URL" "$DXVK_SHA256" "$SRC/dxvk-$DXVK_VERSION.tar.gz"
fetch "$VKD3D_URL" "$VKD3D_SHA256" "$SRC/vkd3d-proton-$VKD3D_VERSION.tar.zst"
fetch "$WINE_GECKO_X86_URL" "$WINE_GECKO_X86_SHA256" "$SRC/wine-gecko-$WINE_GECKO_VERSION-x86.tar.xz"
fetch "$WINE_GECKO_X64_URL" "$WINE_GECKO_X64_SHA256" "$SRC/wine-gecko-$WINE_GECKO_VERSION-x86_64.tar.xz"

# glibc: the pinned Debian source package + the stock libc6 .deb (its ld.so = the APK's loader).
# Pool first (main, then security), then snapshot.debian.org by SHA-1 (permanent).
while read -r name sha sha1; do
    enc="${name//+/%2B}"
    fetch_any "$sha" "$SRC/glibc/$name" \
        "$DEBIAN_MIRROR/pool/main/g/glibc/$enc" \
        "$DEBIAN_SECURITY_MIRROR/pool/updates/main/g/glibc/$enc" \
        "https://snapshot.debian.org/file/$sha1"
done < <(glibc_inputs)

declare -A monos=()
for v in $WINE_VERSIONS; do
    fetch "$(getv WINE_URL "$v")" "$(getv WINE_SHA256 "$v")" "$SRC/wine-$v.tar.xz"
    monos["$(getv WINE_MONO "$v")"]=1
done
for m in "${!monos[@]}"; do
    fetch "$(getv WINE_MONO_URL "$m")" "$(getv WINE_MONO_SHA256 "$m")" "$SRC/wine-mono-$m-x86.tar.xz"
done

# box64: exact commit (the build embeds `git describe`, so keep the .git directory)
b64="$SRC/box64-$BOX64_COMMIT"
if [ -d "$b64/.git" ] && [ "$(git -C "$b64" rev-parse HEAD)" = "$BOX64_COMMIT" ] \
        && [ -z "$(git -C "$b64" status --porcelain)" ]; then
    log "cached: box64 @ $BOX64_COMMIT"
else
    log "checkout: box64 @ $BOX64_COMMIT"
    fresh_dir "$b64"
    git -C "$b64" init -q
    git -C "$b64" config core.autocrlf false
    git -C "$b64" remote add origin "$BOX64_GIT"
    if ! git -C "$b64" fetch -q --depth 1 origin "$BOX64_COMMIT"; then
        warn "server refused fetch-by-commit, fetching tag v$BOX64_VERSION"
        git -C "$b64" fetch -q --depth 1 origin "refs/tags/v$BOX64_VERSION:refs/tags/v$BOX64_VERSION"
    fi
    git -C "$b64" -c advice.detachedHead=false checkout -q "$BOX64_COMMIT" \
        || die "box64 commit $BOX64_COMMIT not available"
    [ "$(git -C "$b64" rev-parse HEAD)" = "$BOX64_COMMIT" ] || die "box64 checkout mismatch"
    # a tag ref makes `git describe` in box64's CMake produce the release version
    git -C "$b64" tag -f "v$BOX64_VERSION" "$BOX64_COMMIT" >/dev/null
fi

log "all sources present and verified"
