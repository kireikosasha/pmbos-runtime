#!/usr/bin/env bash
# Stage "wine" (amd64 container): builds every version in WINE_VERSIONS (or only WINE_BUILD_VERSIONS) in the new WoW64
# mode (x86_64 unix side, x86_64 + i386 PE modules via MinGW), installed under
# /opt/wine-<ver> -> pack "wine-<ver>" (installDir imagefs, files opt/wine-<ver>/...).
# The unix side runs under box64 on the device.
PB_LOG_PREFIX=wine
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$BUILD/wine" "$STAGE"' EXIT
need_cmd gcc make x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc strip file patch

recommended="${WINE_VERSIONS%% *}"
build_versions="${WINE_BUILD_VERSIONS:-$WINE_VERSIONS}"
for v in $build_versions; do
    case " $WINE_VERSIONS " in *" $v "*) ;; *) die "WINE_BUILD_VERSIONS: $v is not in WINE_VERSIONS ($WINE_VERSIONS)" ;; esac
done
for v in $build_versions; do
    first=0
    [ "$v" = "$recommended" ] && first=1
    major="${v%%.*}"
    patchfile="$PB/patches/wine-$major-pmbos-tmpdir.patch"
    [ -f "$patchfile" ] || die "no wine patch for major version $major ($patchfile)"
    mono="$(getv WINE_MONO "$v")"
    prefix="/opt/wine-$v"
    w="$BUILD/wine/$v"
    fresh_dir "$w/src"
    mkdir -p "$w/build" "$w/inst"
    tar -xf "$SRC/wine-$v.tar.xz" -C "$w/src" --strip-components=1
    log "wine $v: applying $(basename "$patchfile")"
    (cd "$w/src" && patch -p1 --fuzz=0 < "$patchfile")

    log "wine $v: configure"
    (
        cd "$w/build"
        "$w/src/configure" \
            --prefix="$prefix" \
            --enable-archs=x86_64,i386 \
            --disable-tests \
            --with-mingw \
            --with-x --with-freetype --with-fontconfig --with-gnutls --with-vulkan --with-opengl \
            --with-alsa --with-pulse \
            --with-xcomposite --with-xcursor --with-xfixes --with-xinerama --with-xinput2 \
            --with-xrandr --with-xrender --with-xshape --with-xshm --with-xxf86vm \
            --without-capi --without-cups --without-dbus --without-ffmpeg --without-gphoto \
            --without-gssapi --without-gstreamer --without-hwloc --without-krb5 --without-netapi \
            --without-opencl --without-oss --without-pcap --without-pcsclite --without-sane \
            --without-sdl --without-udev --without-unwind --without-usb --without-v4l2 \
            --without-wayland \
            CFLAGS="-O2 -pipe -g0" CROSSCFLAGS="-O2 -pipe -g0" LDFLAGS="-Wl,-O1" \
            > configure.log 2>&1 || { tail -n 60 configure.log >&2; die "wine $v: configure failed"; }
        # hard requirements for PMB OS: X11, Vulkan, EGL, FreeType, GnuTLS
        for pat in 'X .*development files not found' 'libvulkan.*not found' \
                   'EGL .*development files not found' 'FreeType .*not found' 'libgnutls .*not found'; do
            if grep -qE "$pat" configure.log; then
                die "wine $v: configure reported: $(grep -E "$pat" configure.log | head -n1)"
            fi
        done
    )
    log "wine $v: build (this takes a while)"
    make -C "$w/build" -j"$JOBS" >"$w/build/make.log" 2>&1 \
        || { tail -n 80 "$w/build/make.log" >&2; die "wine $v: build failed"; }
    make -C "$w/build" install DESTDIR="$w/inst" >"$w/build/install.log" 2>&1 \
        || { tail -n 40 "$w/build/install.log" >&2; die "wine $v: install failed"; }

    root="$STAGE/wine-$v"
    rm -rf "$root"
    mkdir -p "$root/opt"
    mv "$w/inst$prefix" "$root/opt/"
    t="$root/opt/wine-$v"
    rm -rf "$t/include" "$t/share/man" "$t/share/applications" "$t/lib/wine/x86_64-unix/"*.a \
           "$t/lib/wine/x86_64-windows/"*.a "$t/lib/wine/i386-windows/"*.a
    # strip the unix side (x86_64 ELF); PE modules are built without debug info already
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q '^ELF 64-bit LSB.*x86-64'; then strip --strip-unneeded "$f"; fi
    done < <(find "$t/bin" "$t/lib/wine/x86_64-unix" -type f -print0)

    # sanity: both PE architectures, unix side, patch present
    [ -d "$t/lib/wine/x86_64-windows" ] && [ -d "$t/lib/wine/i386-windows" ] \
        || die "wine $v: missing x86_64/i386 PE directories (WoW64 build failed?)"
    [ -f "$t/lib/wine/x86_64-unix/ntdll.so" ] || die "wine $v: ntdll.so missing"
    grep -q PMBOS_TMPDIR "$t/lib/wine/x86_64-unix/ntdll.so" || die "wine $v: ntdll patch missing"
    grep -q PMBOS_TMPDIR "$t/bin/wineserver" || die "wine $v: wineserver patch missing"
    [ -f "$t/lib/wine/x86_64-windows/winevulkan.dll" ] || die "wine $v: winevulkan missing"

    # wine-mono / wine-gecko are shared by all wine builds (packs wine-mono-*, wine-gecko-*)
    ln -sfn ../../../wine-addons/mono "$t/share/wine/mono"
    ln -sfn ../../../wine-addons/gecko "$t/share/wine/gecko"
    install -m 0644 "$w/src/LICENSE" "$t/share/wine/LICENSE"
    install -m 0644 "$w/src/COPYING.LIB" "$t/share/wine/COPYING.LIB"

    packdef "wine-$v" "$v" wine imagefs "imagefs,box64,wine-mono-$mono" "$first" 0 \
        "Wine $v (WoW64: x86_64 + i386 PE, x86_64 unix side for box64), opt/wine-$v"
    rm -rf "$w"
done
log "wine staged: $build_versions"
