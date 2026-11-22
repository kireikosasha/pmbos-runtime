#!/usr/bin/env bash
# Stage "mesa" (arm64 container): Mesa for arm64 glibc
#   - Vulkan: Turnip (freedreno) on the Android KGSL kernel interface, X11 WSI
#   - Vulkan: Venus (virtio) over the vtest socket of the Android-side virglrenderer (venus-android: Mali and other
#     non-Adreno GPUs run the commands on the device's own Vulkan driver)
#   - OpenGL / EGL: Zink on top of Turnip or Venus (no GLVND: libGL.so.1 / libEGL.so.1 are Mesa's); patched to run
#     without robustness2.nullDescriptor (Mali)
# installed under /opt/mesa-<ver> -> pack "mesa-<ver>" (type vulkan-driver, installDir imagefs).
# The Vulkan ICD manifest uses the @ROOTFS@ token (textPatch) for its absolute library path.
PB_LOG_PREFIX=mesa
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$BUILD/mesa" "$STAGE"' EXIT
need_cmd gcc g++ ninja python3 strip file
MESON=/opt/pb-venv/bin/meson
[ -x "$MESON" ] || die "meson venv missing in the build image"

prefix="/opt/mesa-$MESA_VERSION"
w="$BUILD/mesa"
fresh_dir "$w/src"
tar -xf "$SRC/mesa-$MESA_VERSION.tar.xz" -C "$w/src" --strip-components=1
# our fixes (e.g. Zink without robustness2.nullDescriptor for Mali through Venus): mesa-<major>-pmbos-*.patch
for pf in "$PB/patches/mesa-${MESA_VERSION%%.*}-pmbos-"*.patch; do
    [ -f "$pf" ] || continue
    log "applying $(basename "$pf")"
    (cd "$w/src" && patch -p1 --fuzz=0 < "$pf") || die "patch $(basename "$pf") failed"
done

log "meson setup"
PATH="/opt/pb-venv/bin:$PATH" "$MESON" setup "$w/build" "$w/src" \
    --prefix="$prefix" --libdir=lib --buildtype=release -Db_ndebug=true -Dstrip=true \
    -Dplatforms=x11 \
    -Dvulkan-drivers=freedreno,virtio -Dfreedreno-kmds=kgsl \
    -Dgallium-drivers=zink \
    -Dopengl=true -Dglx=dri -Degl=enabled -Dgles1=disabled -Dgles2=enabled \
    -Dgbm=disabled -Dglvnd=disabled -Dllvm=disabled \
    -Dvulkan-layers= -Dtools= -Dvideo-codecs= -Dgallium-va=disabled \
    -Dshader-cache=enabled -Dxmlconfig=disabled -Dzstd=enabled -Dexpat=disabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Ddisplay-info=disabled \
    -Dbuild-tests=false -Dselinux=false \
    > "$w/setup.log" 2>&1 || { tail -n 60 "$w/setup.log" >&2; die "meson setup failed"; }
log "build"
PATH="/opt/pb-venv/bin:$PATH" ninja -C "$w/build" -j"$JOBS" > "$w/build.log" 2>&1 \
    || { tail -n 80 "$w/build.log" >&2; die "mesa build failed"; }
DESTDIR="$w/inst" PATH="/opt/pb-venv/bin:$PATH" "$MESON" install -C "$w/build" --no-rebuild >/dev/null

root="$STAGE/mesa-$MESA_VERSION"
rm -rf "$root"
mkdir -p "$root/opt"
mv "$w/inst$prefix" "$root/opt/"
t="$root/opt/mesa-$MESA_VERSION"
rm -rf "$t/include" "$t/lib/pkgconfig" "$t/share/drirc.d"

[ -f "$t/lib/libvulkan_freedreno.so" ] || die "libvulkan_freedreno.so not built"
[ -f "$t/lib/libvulkan_virtio.so" ] || die "libvulkan_virtio.so (Venus) not built"
[ -e "$t/lib/libEGL.so.1" ] || die "libEGL.so.1 not built"
[ -e "$t/lib/libGL.so.1" ] || die "libGL.so.1 not built"

# Vulkan ICD manifests with an install-time absolute path
icd_dir="$t/share/vulkan/icd.d"
for drv in freedreno virtio; do
src_icd="$(find "$icd_dir" -name "${drv}_icd*.json" ! -name "${drv}_icd.aarch64.json" -print -quit)"
[ -n "$src_icd" ] || src_icd="$(find "$icd_dir" -name "${drv}_icd*.json" -print -quit)"
[ -n "$src_icd" ] || die "$drv ICD manifest not generated"
python3 - "$src_icd" "$icd_dir/${drv}_icd.aarch64.json" "@ROOTFS@$prefix/lib/libvulkan_${drv}.so" <<'PY'
import json, sys
src, dst, lib = sys.argv[1:4]
with open(src) as f:
    icd = json.load(f)
icd["ICD"]["library_path"] = lib
icd["ICD"].setdefault("api_version", "1.4.0")
with open(dst + ".tmp", "w") as f:
    json.dump(icd, f, indent=4)
    f.write("\n")
import os
if os.path.abspath(src) != os.path.abspath(dst):
    os.unlink(src)
os.replace(dst + ".tmp", dst)
PY
done
install -m 0644 "$w/src/docs/license.rst" "$t/share/LICENSE.mesa.rst"

packdef "mesa-$MESA_VERSION" "$MESA_VERSION" vulkan-driver imagefs "imagefs" 1 1 \
    "Mesa $MESA_VERSION: Turnip Vulkan (Adreno, KGSL) + Venus Vulkan (other GPUs, via venus-android) + Zink OpenGL/EGL, X11 WSI (opt/mesa-$MESA_VERSION)"
rm -rf "$w"
log "mesa staged"
