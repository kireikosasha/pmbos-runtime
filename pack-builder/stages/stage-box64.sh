#!/usr/bin/env bash
# Stage "box64" (arm64 container): builds box64 with the ARM64 dynarec for a generic ARMv8
# target and for every SoC-tuned variant in BOX64_VARIANTS.
#   generic -> pack "box64"     : usr/bin/box64, usr/lib/box64-x86_64-linux-gnu/*, etc/box64.box64rc
#   <soc>   -> pack "box64-<soc>": usr/bin/box64-<soc> (shares the x86_64 libs of "box64")
PB_LOG_PREFIX=box64
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$BUILD/box64" "$STAGE"' EXIT
need_cmd cmake ninja gcc git python3 strip nm readelf

src="$BUILD/box64/src"
patchfile="$PB/patches/box64-$BOX64_VERSION-pmbos-shm-plt.patch"
[ -f "$patchfile" ] || die "no box64 patch for $BOX64_VERSION ($patchfile)"
case " $BOX64_VARIANTS " in *" generic "*) ;; *) die "BOX64_VARIANTS must contain 'generic'" ;; esac

fresh_dir "$BUILD/box64"
git clone -q --no-hardlinks "$SRC/box64-$BOX64_COMMIT" "$src"
git -C "$src" -c advice.detachedHead=false checkout -q "$BOX64_COMMIT"
git -C "$src" tag -f "v$BOX64_VERSION" "$BOX64_COMMIT" >/dev/null
log "applying $(basename "$patchfile")"
git -C "$src" apply --whitespace=nowarn "$patchfile"
# make sure CMake regenerates the wrappers from the patched *_private.h
touch "$src/src/wrapped/wrappedlibc_private.h"

# Link with the padded PT_INTERP placeholder directly: the runtime rewrites it in place on
# install, and patchelf never has to restructure this fixed-load-address executable.
interp="$(python3 "$PACKTOOL" placeholder --len "$INTERP_PLACEHOLDER_LEN")"
sysld=/lib/ld-linux-aarch64.so.1

for variant in $BOX64_VARIANTS; do
    bdir="$BUILD/box64/build-$variant"
    inst="$BUILD/box64/inst-$variant"
    opts=(-DARM_DYNAREC=ON -DBAD_SIGNAL=ON -DWINLATOR_GLIBC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
          -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3
          "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--dynamic-linker=$interp")
    if [ "$variant" = generic ]; then
        opts+=(-DARM64=ON)
    else
        opts+=("-D$(printf '%s' "$variant" | tr '[:lower:]' '[:upper:]')=ON")
    fi
    log "configure $variant: ${opts[*]}"
    cmake -S "$src" -B "$bdir" -G Ninja "${opts[@]}" >/dev/null
    log "build $variant"
    cmake --build "$bdir" -j"$JOBS" >/dev/null
    DESTDIR="$inst" cmake --install "$bdir" >/dev/null
    bin="$inst/usr/bin/box64"
    [ -x "$bin" ] || die "box64 binary missing for $variant"
    strip --strip-debug "$bin"
    # No "cmd | grep -q" under pipefail: grep -q exits at the first match and the writer then
    # dies with SIGPIPE (141), failing the pipeline although the match was found. Capture first.
    readelf -l "$bin" > "$bdir/phdrs.txt"
    grep -qF "$interp" "$bdir/phdrs.txt" || die "$variant: PT_INTERP placeholder not set"
    # the patch must have turned the shm functions into PLT-bound wrappers. .symtab survives
    # strip --strip-debug and does not depend on box64 exporting my_* into .dynsym.
    nm --defined-only "$bin" > "$bdir/syms.txt"
    for s in my_shmat my_shmctl my_shmdt my_shmget; do
        grep -qw "$s" "$bdir/syms.txt" || die "$variant: $s not defined - box64 patch not effective"
    done
    grep -q 'GOM(shmget' "$src/src/wrapped/wrappedlibc_private.h" || die "patched private header missing"

    if [ "$variant" = generic ]; then
        "$sysld" "$bin" --version || die "box64 --version failed"
        root="$STAGE/box64"
        rm -rf "$root"
        mkdir -p "$root/usr/bin" "$root/etc"
        install -m 0755 "$bin" "$root/usr/bin/box64"
        [ -d "$inst/usr/lib/box64-x86_64-linux-gnu" ] || die "box64 x86_64 libs not installed"
        mkdir -p "$root/usr/lib"
        cp -a "$inst/usr/lib/box64-x86_64-linux-gnu" "$root/usr/lib/"
        install -m 0644 "$src/system/box64.box64rc" "$root/etc/box64.box64rc"
        install -m 0644 "$src/LICENSE" "$root/usr/lib/box64-x86_64-linux-gnu/LICENSE.box64"
        packdef box64 "$BOX64_VERSION" box64 imagefs "imagefs" 1 1 \
            "box64 $BOX64_VERSION x86_64 emulator, generic ARMv8 dynarec (+ x86_64 runtime libs)"
    else
        root="$STAGE/box64-$variant"
        rm -rf "$root"
        mkdir -p "$root/usr/bin"
        install -m 0755 "$bin" "$root/usr/bin/box64-$variant"
        packdef "box64-$variant" "$BOX64_VERSION" box64 imagefs "imagefs,box64" 0 1 \
            "box64 $BOX64_VERSION tuned for $(printf '%s' "$variant" | tr '[:lower:]' '[:upper:]') (usr/bin/box64-$variant)"
    fi
    rm -rf "$bdir"
done
log "box64 variants staged: $BOX64_VARIANTS"
