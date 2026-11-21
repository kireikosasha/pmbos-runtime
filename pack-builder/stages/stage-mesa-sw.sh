#!/usr/bin/env bash
# Stage "mesa-sw" (arm64 container): software (CPU) rendering Mesa for GPUs without a Mesa Vulkan driver (Mali,
# PowerVR, ...): installed under /opt/mesa-sw-<ver> -> pack "mesa-sw-<ver>" (type sw-driver, installDir imagefs).
#   - Vulkan: lavapipe (vulkan-drivers=swrast) -> DXVK / VKD3D-Proton run on the CPU; X11 WSI is always the
#     software path (PutImage / MIT-SHM), no DRI3 needed
#   - OpenGL / EGL / GLES2: gallium llvmpipe (libGL.so.1 / libEGL.so.1, no GLVND)
#   - LLVM (Debian bookworm llvm-<LLVM_MAJOR>, from the build image) is linked STATICALLY, so the pack does not
#     depend on libLLVM (+ libz3/libicu/libxml2); the few remaining DT_NEEDED libraries that imagefs lacks are
#     copied from the build image into opt/mesa-sw-<ver>/lib (with their Debian copyright files).
# GLX: Mesa >= 25 dropped -Dglx=xlib (client-side GLX over plain X11; 26.3 meson.options offers auto/disabled/dri
# only), so GLX here is the DRI flavour, which needs a GLX extension in the X server. Without one (PMB's X server
# ships GLX off) GL clients must use EGL on X11: Mesa's EGL x11 platform falls back to "swrast" (PutImage /
# MIT-SHM), which needs no server-side GLX or DRI. Kept separate from stage "mesa" (Turnip + Zink, glx=dri, no
# LLVM) so Adreno devices keep the small pack.
# The Vulkan ICD manifest uses the @ROOTFS@ token (textPatch) for its absolute library path.
PB_LOG_PREFIX=mesa-sw
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$BUILD/mesa-sw" "$STAGE"' EXIT
need_cmd gcc g++ ninja python3 strip file readelf dpkg-query
MESON=/opt/pb-venv/bin/meson
[ -x "$MESON" ] || die "meson venv missing in the build image"
llvm_cfgs=(/usr/lib/llvm-*/bin/llvm-config)   # nullglob: empty when no llvm-*-dev is installed
LLVM_CONFIG=""
[ "${#llvm_cfgs[@]}" -gt 0 ] && LLVM_CONFIG="$(printf '%s\n' "${llvm_cfgs[@]}" | sort -V | tail -n1)"
[ -n "$LLVM_CONFIG" ] && [ -x "$LLVM_CONFIG" ] || die "llvm-config missing in the build image (Dockerfile.arm64: llvm-*-dev)"
LLVM_VER="$("$LLVM_CONFIG" --version)"
llvm_static="$("$LLVM_CONFIG" --link-static --libnames core 2>&1 || true)"
log "LLVM $LLVM_VER ($LLVM_CONFIG), static core lib: $llvm_static"
case "$llvm_static" in *.a*) ;; *) die "LLVM $LLVM_VER has no static libraries ($llvm_static)" ;; esac

id="mesa-sw-$MESA_VERSION"
prefix="/opt/$id"
w="$BUILD/mesa-sw"
fresh_dir "$w/src"
tar -xf "$SRC/mesa-$MESA_VERSION.tar.xz" -C "$w/src" --strip-components=1

# meson finds the static LLVM through this exact llvm-config (no PATH guessing between installed versions)
cat > "$w/native.ini" <<EOF
[binaries]
llvm-config = '$LLVM_CONFIG'
EOF

log "meson setup"
PATH="/opt/pb-venv/bin:$PATH" "$MESON" setup "$w/build" "$w/src" --native-file "$w/native.ini" \
    --prefix="$prefix" --libdir=lib --buildtype=release -Db_ndebug=true -Dstrip=true \
    -Dplatforms=x11 \
    -Dvulkan-drivers=swrast \
    -Dgallium-drivers=llvmpipe \
    -Dopengl=true -Dglx=dri -Degl=enabled -Dgles1=disabled -Dgles2=enabled \
    -Dgbm=disabled -Dglvnd=disabled \
    -Dllvm=enabled -Dshared-llvm=disabled -Ddraw-use-llvm=true -Dllvm-orcjit=false \
    -Dvulkan-layers= -Dtools= -Dvideo-codecs= -Dgallium-va=disabled \
    -Dshader-cache=enabled -Dxmlconfig=disabled -Dzstd=enabled -Dexpat=disabled \
    -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Ddisplay-info=disabled \
    -Dbuild-tests=false -Dselinux=false \
    > "$w/setup.log" 2>&1 || { tail -n 60 "$w/setup.log" >&2; die "meson setup failed"; }
grep -iE "llvm|llvmpipe|swrast|lavapipe" "$w/setup.log" | head -n 20 >&2 || true
log "build"
PATH="/opt/pb-venv/bin:$PATH" ninja -C "$w/build" -j"$JOBS" > "$w/build.log" 2>&1 \
    || { tail -n 80 "$w/build.log" >&2; die "mesa-sw build failed"; }
DESTDIR="$w/inst" PATH="/opt/pb-venv/bin:$PATH" "$MESON" install -C "$w/build" --no-rebuild >/dev/null

root="$STAGE/$id"
rm -rf "$root"
mkdir -p "$root/opt"
mv "$w/inst$prefix" "$root/opt/"
t="$root$prefix"
rm -rf "$t/include" "$t/lib/pkgconfig" "$t/share/drirc.d"

[ -f "$t/lib/libvulkan_lvp.so" ] || die "libvulkan_lvp.so (lavapipe) not built"
[ -e "$t/lib/libEGL.so.1" ] || die "libEGL.so.1 not built"
[ -e "$t/lib/libGL.so.1" ] || die "libGL.so.1 not built"
gallium=("$t"/lib/libgallium-*.so)
[ "${#gallium[@]}" -gt 0 ] || die "libgallium-*.so (llvmpipe) not built"
for f in "$t/lib/libvulkan_lvp.so" "${gallium[@]}"; do
    dyn="$(readelf -d "$f")"
    case "$dyn" in *"[libLLVM"*) die "$(basename "$f") links libLLVM dynamically (want static)" ;; esac
done

# ---- DT_NEEDED closure: bundle what imagefs does not ship --------------------------------------------------
# imagefs = ROOTFS_PACKAGES + ROOTFS_OPTIONAL_PACKAGES (+ their apt dependencies). A library is bundled when its
# Debian package is not one of the explicitly listed ones (duplicates of an indirect imagefs dependency are
# harmless: opt/mesa-sw-<v>/lib comes first in LD_LIBRARY_PATH). Stage post re-checks the closure against the
# real imagefs (check-needed with opt/<id>/lib as an extra lib dir).
declare -A IMAGEFS_PKG=()
for p in $ROOTFS_PACKAGES $ROOTFS_OPTIONAL_PACKAGES; do IMAGEFS_PKG[$p]=1; done
declare -A HAVE=() SEEN=()
bundled=()
for f in "$t"/lib/*.so*; do HAVE[$(basename "$f")]=1; done
queue=()
while IFS= read -r -d '' f; do
    case "$(file -b "$f")" in "ELF 64-bit"*aarch64*) queue+=("$f") ;; esac
done < <(find "$t/lib" -type f -print0)
while [ "${#queue[@]}" -gt 0 ]; do
    f="${queue[0]}"; queue=("${queue[@]:1}")
    while read -r so; do
        [ -n "$so" ] || continue
        [ -z "${HAVE[$so]:-}" ] && [ -z "${SEEN[$so]:-}" ] || continue
        SEEN[$so]=1
        case "$so" in ld-linux-*|libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*) continue ;; esac
        owner="$(dpkg-query -S "*/$so" 2>/dev/null | grep -v '^diversion' | head -n1 || true)"
        [ -n "$owner" ] || die "$(basename "$f") needs $so, which no Debian package in the build image provides"
        pkg="${owner%%:*}"
        path="${owner#*: }"
        if [ -n "${IMAGEFS_PKG[$pkg]:-}" ]; then continue; fi
        [ -e "$path" ] || die "$so ($pkg) listed by dpkg but $path is missing"
        log "bundling $so from Debian package $pkg (not in imagefs)"
        cp -L "$path" "$t/lib/$so"
        chmod 0644 "$t/lib/$so"
        strip --strip-unneeded "$t/lib/$so" 2>/dev/null || true
        HAVE[$so]=1
        bundled+=("$pkg $(dpkg-query -W -f='${Version}' "$pkg") $so")
        mkdir -p "$t/share/doc/$pkg"
        [ -f "/usr/share/doc/$pkg/copyright" ] && cp "/usr/share/doc/$pkg/copyright" "$t/share/doc/$pkg/copyright"
        queue+=("$t/lib/$so")
    done < <(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
done

# Vulkan ICD manifest with an install-time absolute path
icd_dir="$t/share/vulkan/icd.d"
src_icd="$(find "$icd_dir" -name 'lvp_icd*.json' -print -quit)"
[ -n "$src_icd" ] || die "lavapipe ICD manifest not generated"
python3 - "$src_icd" "$icd_dir/lvp_icd.aarch64.json" "@ROOTFS@$prefix/lib/libvulkan_lvp.so" <<'PY'
import json, sys, os
src, dst, lib = sys.argv[1:4]
with open(src) as f:
    icd = json.load(f)
icd["ICD"]["library_path"] = lib
icd["ICD"].setdefault("api_version", "1.4.0")
with open(dst + ".tmp", "w") as f:
    json.dump(icd, f, indent=4)
    f.write("\n")
if os.path.abspath(src) != os.path.abspath(dst):
    os.unlink(src)
os.replace(dst + ".tmp", dst)
PY

# ---- self-test: lavapipe instance + physical device (initializes llvmpipe + the static LLVM JIT) ------------
log "self-test: lavapipe"
cat > "$w/lvp-test.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <vulkan/vulkan_core.h>
typedef PFN_vkVoidFunction (*gipa_t)(VkInstance, const char *);
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    gipa_t gipa = (gipa_t)dlsym(h, "vk_icdGetInstanceProcAddr");
    if (!gipa) { fprintf(stderr, "no vk_icdGetInstanceProcAddr\n"); return 3; }
    PFN_vkCreateInstance ci = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "pmbos-lvp-test", 1, NULL, 0, VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app, 0, NULL, 0, NULL };
    VkInstance inst;
    VkResult r = ci(&ici, NULL, &inst);
    if (r != VK_SUCCESS) { fprintf(stderr, "vkCreateInstance: %d\n", r); return 4; }
    PFN_vkEnumeratePhysicalDevices epd = (PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceProperties gpp = (PFN_vkGetPhysicalDeviceProperties)gipa(inst, "vkGetPhysicalDeviceProperties");
    PFN_vkCreateDevice cd = (PFN_vkCreateDevice)gipa(inst, "vkCreateDevice");
    PFN_vkDestroyDevice dd = (PFN_vkDestroyDevice)gipa(inst, "vkDestroyDevice");
    PFN_vkDestroyInstance di = (PFN_vkDestroyInstance)gipa(inst, "vkDestroyInstance");
    uint32_t n = 1;
    VkPhysicalDevice pd;
    r = epd(inst, &n, &pd);
    if ((r != VK_SUCCESS && r != VK_INCOMPLETE) || n == 0) { fprintf(stderr, "no physical device (%d)\n", r); return 5; }
    VkPhysicalDeviceProperties p;
    gpp(pd, &p);
    float prio = 1.0f;
    VkDeviceQueueCreateInfo q = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &q, 0, NULL, 0, NULL, NULL };
    VkDevice dev;
    r = cd(pd, &dci, NULL, &dev);
    if (r != VK_SUCCESS) { fprintf(stderr, "vkCreateDevice: %d\n", r); return 6; }
    printf("%s, Vulkan %u.%u.%u\n", p.deviceName, VK_VERSION_MAJOR(p.apiVersion), VK_VERSION_MINOR(p.apiVersion),
           VK_VERSION_PATCH(p.apiVersion));
    dd(dev, NULL);
    di(inst, NULL);
    return strstr(p.deviceName, "llvmpipe") ? 0 : 7;
}
EOF
gcc -O1 -I"$w/src/include" -o "$w/lvp-test" "$w/lvp-test.c" -ldl || die "cannot build the lavapipe self-test"
out="$(LD_LIBRARY_PATH="$t/lib" timeout 300 "$w/lvp-test" "$t/lib/libvulkan_lvp.so" 2>&1)" \
    || die "lavapipe self-test failed: $out"
log "  $out"

install -m 0644 "$w/src/docs/license.rst" "$t/share/LICENSE.mesa.rst"
llvm_pkg="$(dpkg-query -S "$LLVM_CONFIG" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
llvm_copy=""
for d in ${llvm_pkg:+"/usr/share/doc/$llvm_pkg"} /usr/share/doc/llvm-*; do
    [ -f "$d/copyright" ] && { llvm_copy="$d/copyright"; break; }
done
if [ -n "$llvm_copy" ]; then
    install -m 0644 "$llvm_copy" "$t/share/LICENSE.llvm"
else
    warn "LLVM copyright file not found"
fi
{
    echo "mesa-sw $MESA_VERSION: lavapipe (Vulkan) + llvmpipe (GL/EGL/GLES2) built from $MESA_URL"
    echo "LLVM $LLVM_VER statically linked (Debian $DEBIAN_SUITE ${llvm_pkg:-llvm} $(dpkg-query -W -f='${Version}' "${llvm_pkg:-llvm-15}" 2>/dev/null || echo ?), Apache-2.0 WITH LLVM-exception)"
    echo "Bundled Debian $DEBIAN_SUITE libraries (package version soname; copyright in share/doc/<package>/):"
    if [ "${#bundled[@]}" -gt 0 ]; then printf '  %s\n' "${bundled[@]}"; else echo "  (none)"; fi
} > "$t/share/BUILDINFO.mesa-sw.txt"
cat "$t/share/BUILDINFO.mesa-sw.txt" >&2

packdef "$id" "$MESA_VERSION" sw-driver imagefs "imagefs" 1 1 \
    "Mesa $MESA_VERSION software rendering (CPU): lavapipe Vulkan for DXVK/VKD3D + llvmpipe OpenGL/EGL (LLVM $LLVM_VER), X11; for GPUs without Turnip (Mali etc.) (opt/$id)"
rm -rf "$w"
log "mesa-sw staged"
