#!/usr/bin/env bash
# Stage "repack" (tools container): official prebuilt Windows-side components.
#   dxvk-<ver>         components/dxvk-<ver>/{x64,x32}/*.dll        (d3d8/9/10core/11, dxgi)
#   vkd3d-proton-<ver> components/vkd3d-proton-<ver>/{x64,x32}/*.dll (d3d12, d3d12core)
#   wine-mono-<ver>    imagefs/opt/wine-addons/mono/wine-mono-<ver>/
#   wine-gecko-<ver>   imagefs/opt/wine-addons/gecko/wine-gecko-<ver>-{x86,x86_64}/
# DLL directory names are normalised to x64 (-> system32) and x32 (-> syswow64).
PB_LOG_PREFIX=repack
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$BUILD/repack" "$STAGE"' EXIT
need_cmd tar zstd xz

tmp="$BUILD/repack"
fresh_dir "$tmp"

# ---- DXVK ----------------------------------------------------------------------------------
root="$STAGE/dxvk-$DXVK_VERSION"
rm -rf "$root"
tar -xzf "$SRC/dxvk-$DXVK_VERSION.tar.gz" -C "$tmp"
d="$tmp/dxvk-$DXVK_VERSION"
[ -f "$d/x64/d3d11.dll" ] && [ -f "$d/x32/d3d11.dll" ] || die "unexpected DXVK archive layout"
mkdir -p "$root/x64" "$root/x32"
cp "$d"/x64/*.dll "$root/x64/"
cp "$d"/x32/*.dll "$root/x32/"
packdef "dxvk-$DXVK_VERSION" "$DXVK_VERSION" dxvk "components/dxvk-$DXVK_VERSION" "" 1 0 \
    "DXVK $DXVK_VERSION: Direct3D 8/9/10/11 over Vulkan (x64 -> system32, x32 -> syswow64)"

# ---- VKD3D-Proton --------------------------------------------------------------------------
root="$STAGE/vkd3d-proton-$VKD3D_VERSION"
rm -rf "$root"
zstd -dc "$SRC/vkd3d-proton-$VKD3D_VERSION.tar.zst" | tar -x -C "$tmp"
d="$tmp/vkd3d-proton-$VKD3D_VERSION"
[ -f "$d/x64/d3d12.dll" ] && [ -f "$d/x86/d3d12.dll" ] || die "unexpected VKD3D-Proton archive layout"
mkdir -p "$root/x64" "$root/x32"
cp "$d"/x64/*.dll "$root/x64/"
cp "$d"/x86/*.dll "$root/x32/"
packdef "vkd3d-proton-$VKD3D_VERSION" "$VKD3D_VERSION" vkd3d "components/vkd3d-proton-$VKD3D_VERSION" "" 1 0 \
    "VKD3D-Proton $VKD3D_VERSION: Direct3D 12 over Vulkan (x64 -> system32, x32 -> syswow64)"

# ---- wine-mono (one pack per version referenced by WINE_VERSIONS) ----------------------------
declare -A monos=()
first_mono="$(getv WINE_MONO "${WINE_VERSIONS%% *}")"
for v in $WINE_VERSIONS; do monos["$(getv WINE_MONO "$v")"]=1; done
for m in "${!monos[@]}"; do
    root="$STAGE/wine-mono-$m"
    rm -rf "$root"
    mkdir -p "$root/opt/wine-addons/mono"
    tar -xJf "$SRC/wine-mono-$m-x86.tar.xz" -C "$root/opt/wine-addons/mono"
    [ -d "$root/opt/wine-addons/mono/wine-mono-$m" ] || die "unexpected wine-mono $m layout"
    rec=0
    [ "$m" = "$first_mono" ] && rec=1
    packdef "wine-mono-$m" "$m" misc imagefs "imagefs" "$rec" 0 \
        "Wine Mono $m (.NET Framework for Wine), shared by all wine builds"
done

# ---- wine-gecko ----------------------------------------------------------------------------
root="$STAGE/wine-gecko-$WINE_GECKO_VERSION"
rm -rf "$root"
mkdir -p "$root/opt/wine-addons/gecko"
tar -xJf "$SRC/wine-gecko-$WINE_GECKO_VERSION-x86.tar.xz" -C "$root/opt/wine-addons/gecko"
tar -xJf "$SRC/wine-gecko-$WINE_GECKO_VERSION-x86_64.tar.xz" -C "$root/opt/wine-addons/gecko"
for a in x86 x86_64; do
    [ -d "$root/opt/wine-addons/gecko/wine-gecko-$WINE_GECKO_VERSION-$a" ] || die "unexpected wine-gecko layout ($a)"
done
packdef "wine-gecko-$WINE_GECKO_VERSION" "$WINE_GECKO_VERSION" misc imagefs "imagefs" 0 0 \
    "Wine Gecko $WINE_GECKO_VERSION (MSHTML engine, x86 + x86_64), shared by all wine builds"

rm -rf "$tmp"
log "repacked dxvk, vkd3d-proton, wine-mono (${!monos[*]}), wine-gecko"
