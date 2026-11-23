#!/usr/bin/env bash
# Stage "rootfs" (tools container, host arch): minimal Debian arm64 glibc userland for box64,
# wine's unix side (through box64 wrappers) and Mesa -> pack "imagefs" (type rootfs).
#   mmdebstrap --variant=extract (no maintainer scripts, no emulation needed)
#   -> merged /usr, real <imagefs>/lib/ld-linux-aarch64.so.1, relative symlinks
#   -> glibc rebuilt with the PMBOS_ROOTFS + PMBOS_LOADER (execve) patches (stage glibc) over libc6
#   -> patched libxcb.so.1, libpmbshm.so, /bin/sh (dash), /etc (templates + netbase),
#      zoneinfo, CA bundle, trimming.
PB_LOG_PREFIX=rootfs
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
raw="$BUILD/rootfs-raw"
root="$STAGE/imagefs"
trap 'fix_owner "$raw" "$root" "$STAGE"' EXIT
need_cmd mmdebstrap python3 zcat

[ -f "$BUILD/pmbshm/libpmbshm.so" ] || die "run stage pmbshm first"
[ -f "$BUILD/pmbaudio/libasound_module_pcm_pmbos.so" ] || die "run stage pmbaudio first"
[ -f "$BUILD/libxcb/LIBFILE" ] || die "run stage libxcb first"
libxcb_file="$(cat "$BUILD/libxcb/LIBFILE")"
[ -f "$BUILD/glibc/VERSION" ] && [ -d "$BUILD/glibc/overlay" ] || die "run stage glibc first"
glibc_ver="$(cat "$BUILD/glibc/VERSION")"
TRIPLET=aarch64-linux-gnu
LD=ld-linux-aarch64.so.1

rm -rf "$raw" "$root" "$STAGE/imagefs.pack.json"
mkdir -p "$STAGE"

# libc-bin: only for /usr/lib/locale/C.utf8 - glibc's UTF-8 locale is NOT built into libc.so.6, and without it every
# process stays in the 7-bit "C" locale whatever LANG says (Wine then converts file names as US-ASCII: nothing with a
# non-ASCII name can be opened). The launcher points LOCPATH at <imagefs>/usr/lib/locale. Its programs are trimmed below.
# shellcheck disable=SC2086
pkgs="$(echo $ROOTFS_PACKAGES $ROOTFS_OPTIONAL_PACKAGES libc-bin | tr ' ' ',')"
log "mmdebstrap $DEBIAN_SUITE arm64: $pkgs"
mmdebstrap --mode=root --variant=extract --architectures=arm64 \
    --skip=check/qemu,chroot/mount \
    --aptopt='Acquire::Retries "5"' \
    --include="$pkgs" \
    "$DEBIAN_SUITE" "$raw" \
    "deb $DEBIAN_MIRROR $DEBIAN_SUITE main" \
    "deb $DEBIAN_MIRROR $DEBIAN_SUITE-updates main" \
    "deb $DEBIAN_SECURITY_MIRROR $DEBIAN_SUITE-security main"

# libxcb1 of the suite must be the upstream release we patched (ABI identity)
chlog="$raw/usr/share/doc/libxcb1/changelog.Debian.gz"
[ -f "$chlog" ] || die "cannot determine Debian libxcb1 version ($chlog missing)"
# sed reads all input: "| head" would SIGPIPE zcat and fail the assignment under pipefail
debver="$(zcat "$chlog" | sed -n '1s/^libxcb (\([^)]*\)).*/\1/p')"
[ "${debver%%-*}" = "$LIBXCB_VERSION" ] \
    || die "Debian ships libxcb $debver but LIBXCB_VERSION=$LIBXCB_VERSION; update versions.env"
log "Debian libxcb1 $debver matches patched upstream $LIBXCB_VERSION"

# libc6 of the suite must be the Debian version stage glibc rebuilt (same files, same ABI)
chlog="$raw/usr/share/doc/libc6/changelog.Debian.gz"
[ -f "$chlog" ] || die "cannot determine Debian libc6 version ($chlog missing)"
libc_ver="$(zcat "$chlog" | sed -n '1s/^glibc (\([^)]*\)).*/\1/p')"
[ "${libc_ver%%-*}" = "${glibc_ver%%-*}" ] \
    || die "Debian ships glibc $libc_ver but stage glibc built $glibc_ver (different upstream release)"
if [ "$libc_ver" != "$glibc_ver" ]; then
    if [ -n "${GLIBC_DEBIAN_VERSION:-}" ] && [ "$glibc_ver" = "$GLIBC_DEBIAN_VERSION" ]; then
        warn "Debian ships libc6 $libc_ver, using the pinned rebuild $glibc_ver (GLIBC_DEBIAN_VERSION)"
    else
        die "Debian ships libc6 $libc_ver but stage glibc built $glibc_ver: re-run stage glibc (or pin GLIBC_DEBIAN_VERSION)"
    fi
fi
log "Debian libc6 $libc_ver -> replaced by the PMBOS_ROOTFS/PMBOS_LOADER rebuild of $glibc_ver"

cp -a "$raw" "$root"
cd "$root"

# --- layout -------------------------------------------------------------------------------
rm -rf dev proc sys run mnt media srv opt home root boot
python3 "$PACKTOOL" normalize-rootfs "$root"

# --- glibc: every file of Debian's libc6 replaced by the pmbos rebuild -----------------------------
gl="$BUILD/glibc/overlay"
install -m 0755 "$gl/lib/$LD" "lib/$LD"            # normalize-rootfs made this the real loader
rm -rf "usr/lib/$TRIPLET/gconv"
cp -a --remove-destination "$gl/usr/lib/$TRIPLET/." "usr/lib/$TRIPLET/"
grep -q PMBOS_ROOTFS "usr/lib/$TRIPLET/libc.so.6" || die "imagefs libc.so.6 is not the PMBOS_ROOTFS build"
grep -q PMBOS_LOADER_LIBPATH "usr/lib/$TRIPLET/libc.so.6" || die "imagefs libc.so.6 lacks the PMBOS_LOADER execve redirect"
# the UTF-8 locale (libc-bin of the same glibc release: the locale file format belongs to the release)
[ -s usr/lib/locale/C.utf8/LC_CTYPE ] || die "usr/lib/locale/C.utf8 missing (libc-bin not extracted?)"
find usr/lib/locale -mindepth 1 -maxdepth 1 ! -name C.utf8 -exec rm -rf {} +
cmp -s "$gl/lib/$LD" "lib/$LD" || die "imagefs loader is not the rebuilt one"

# --- trimming (nothing from the imagefs is executed except the loader and /bin/sh) ---------
# /bin/sh: glibc's system()/popen()/wordexp()/execvp() fallback run $PMBOS_ROOTFS/bin/sh
[ -f usr/bin/dash ] || die "usr/bin/dash missing (ROOTFS_PACKAGES must contain dash)"
find usr/bin -mindepth 1 -maxdepth 1 ! -name dash -exec rm -rf {} +
ln -s dash usr/bin/sh
[ "$(readlink bin 2>/dev/null || true)" = usr/bin ] || { rm -rf bin; ln -s usr/bin bin; }
rm -rf usr/sbin usr/games usr/libexec usr/local usr/include usr/src
rm -f sbin
rm -rf usr/lib/apt usr/lib/dpkg usr/lib/mime usr/lib/ssl usr/lib/systemd usr/lib/udev \
       usr/lib/tmpfiles.d usr/lib/sysusers.d usr/lib/os-release usr/lib/ucf usr/lib/sasl2 \
       usr/lib/aarch64-linux-gnu/perl usr/lib/aarch64-linux-gnu/perl-base usr/lib/aarch64-linux-gnu/perl5 \
       usr/lib/aarch64-linux-gnu/audit
# optional plugins of libraries the codecs pull in, for outputs PMB OS doesn't have (libcaca's OpenGL / X11 drivers
# would need libGL, libglut...): never loaded by gstreamer
rm -rf "usr/lib/$TRIPLET/caca"
find usr/lib -name '*.a' -delete
find usr/lib -name '*.la' -delete
# CA bundle (ca-certificates' postinst never ran): sorted, deterministic
mkdir -p etc/ssl/certs
find usr/share/ca-certificates -name '*.crt' -print0 | LC_ALL=C sort -z | xargs -0 cat > etc/ssl/certs/ca-certificates.crt
[ -s etc/ssl/certs/ca-certificates.crt ] || die "empty CA bundle"
# keep only the share/ data that native libraries read at runtime
keep_share="fonts fontconfig X11 alsa doc zoneinfo sounds"
for d in usr/share/*; do
    case " $keep_share " in *" $(basename "$d") "*) ;; *) rm -rf "$d" ;; esac
done
# usr/share/doc: keep copyright notices only (license compliance)
find usr/share/doc -type f ! -name copyright -delete
find usr/share/doc -type l -delete
find usr/share/doc -depth -type d -empty -delete
# zoneinfo: drop the leap-second ("right/") and duplicate ("posix/") trees
rm -rf usr/share/zoneinfo/right usr/share/zoneinfo/posix
[ -f usr/share/zoneinfo/Etc/UTC ] || die "tzdata zoneinfo missing (ROOTFS_PACKAGES must contain tzdata)"
# /etc: our templates + Debian's fontconfig rule set + netbase databases
mkdir -p etc.new/ssl/certs
cp -a etc/fonts etc.new/fonts
cp etc/ssl/certs/ca-certificates.crt etc.new/ssl/certs/
for f in services protocols rpc ethertypes; do
    if [ -f "etc/$f" ]; then cp "etc/$f" "etc.new/$f"; fi
done
[ -f etc.new/services ] && [ -f etc.new/protocols ] || die "netbase /etc/services or /etc/protocols missing"
rm -rf etc
mv etc.new etc
cp -a "$PB/files/rootfs/etc/." etc/
ln -s ../usr/share/zoneinfo/Etc/UTC etc/localtime   # default zone; launcher sets TZ=<IANA id>
rm -rf var
mkdir -p var/cache/fontconfig var/tmp tmp
chmod 0755 tmp var/tmp

# --- PMB OS components --------------------------------------------------------------------
dest_xcb="usr/lib/aarch64-linux-gnu/$libxcb_file"
[ -f "$dest_xcb" ] || die "Debian libxcb file $dest_xcb not found (version drift?)"
install -m 0644 "$BUILD/libxcb/$libxcb_file" "$dest_xcb"
install -m 0644 "$BUILD/pmbshm/libpmbshm.so" usr/lib/libpmbshm.so
# the sound device: ALSA PCM plugin "pmbos" (the launcher's asound.conf names this file; AudioServer.java)
[ -e "usr/lib/$TRIPLET/libasound.so.2" ] || die "libasound.so.2 missing (ROOTFS_OPTIONAL_PACKAGES must contain libasound2)"
install -D -m 0644 "$BUILD/pmbaudio/libasound_module_pcm_pmbos.so" "usr/lib/$TRIPLET/alsa-lib/libasound_module_pcm_pmbos.so"
printf '%s\n' "PMB OS imagefs $PACKSET_VERSION" "debian $DEBIAN_SUITE ($(date -u -d "@$SOURCE_DATE_EPOCH" +%F))" \
    "glibc $glibc_ver + pmbos-rootfs + pmbos-execve" "libxcb $debver + pmbos-tmpdir" "alsa pcm plugin pmbos" > etc/pmbos-release

cd /
packdef imagefs "$DEBIAN_SUITE-$PACKSET_VERSION" rootfs imagefs "" 1 1 \
    "Debian $DEBIAN_SUITE arm64 glibc base (PMBOS_ROOTFS-relocatable glibc with the PMBOS_LOADER exec redirect, /bin/sh, X11/Vulkan/fonts/TLS client libs, SysV shm shim)"
log "imagefs staged: $(du -sh "$root" | cut -f1)"
