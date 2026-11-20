# shellcheck shell=bash
# Shared helpers for build-all.sh (host side) and stages/*.sh (inside the build containers).
# Source it; it enables strict mode. Never executed directly.

set -euo pipefail
shopt -s nullglob

: "${PB_LOG_PREFIX:=pack-builder}"

log()  { printf '[%s %s] %s\n' "$PB_LOG_PREFIX" "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s %s] WARNING: %s\n' "$PB_LOG_PREFIX" "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s %s] ERROR: %s\n' "$PB_LOG_PREFIX" "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

need_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# "11.0" -> "11_0" (version string -> shell variable suffix)
ver_key() { printf '%s' "$1" | tr '.-' '__'; }

# getv PREFIX VERSION -> value of ${PREFIX}_${ver_key VERSION}; dies when undefined.
getv() {
    local n
    n="$1_$(ver_key "$2")"
    [ -n "${!n:-}" ] || die "versions.env: $n is not defined (needed for version $2)"
    printf '%s' "${!n}"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

verify_sha256() { # file expected
    local got
    got="$(sha256_of "$1")"
    [ "$got" = "$2" ] || die "checksum mismatch for $1: expected $2, got $got"
}

# fetch URL SHA256 DEST - idempotent, verified download (partial files are never trusted).
fetch() {
    local url="$1" sha="$2" dest="$3"
    [ -n "$sha" ] || die "no pinned sha256 for $url"
    if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$sha" ]; then
        log "cached: $(basename "$dest")"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    log "download: $url"
    curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 -o "$dest.part" "$url" \
        || die "download failed: $url"
    verify_sha256 "$dest.part" "$sha"
    mv -f "$dest.part" "$dest"
}

# fetch_any SHA256 DEST URL... - like fetch, trying the mirrors in order (first verified wins).
fetch_any() {
    local sha="$1" dest="$2" url got
    shift 2
    [ -n "$sha" ] || die "no pinned sha256 for $(basename "$dest")"
    if [ -f "$dest" ] && [ "$(sha256_of "$dest")" = "$sha" ]; then
        log "cached: $(basename "$dest")"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    for url in "$@"; do
        log "download: $url"
        rm -f "$dest.part"
        if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$dest.part" "$url"; then
            warn "download failed: $url"
            continue
        fi
        got="$(sha256_of "$dest.part")"
        if [ "$got" = "$sha" ]; then
            mv -f "$dest.part" "$dest"
            return 0
        fi
        warn "checksum mismatch for $url: expected $sha, got $got"
    done
    rm -f "$dest.part"
    die "no mirror delivered $(basename "$dest") with sha256 $sha"
}

# Pinned Debian glibc inputs (versions.env): source package files and the stock libc6 .deb.
# Prints "NAME SHA256 SHA1" lines; files live in $SRC/glibc/.
glibc_inputs() {
    local v="${GLIBC_DEBIAN_VERSION#*:}"
    [ -n "$v" ] || die "versions.env: GLIBC_DEBIAN_VERSION is empty (must equal pmbos/tools/loader/VERSION)"
    printf '%s %s %s\n' \
        "glibc_$v.dsc" "$GLIBC_DSC_SHA256" "$GLIBC_DSC_SHA1" \
        "glibc_${v%%-*}.orig.tar.xz" "$GLIBC_ORIG_SHA256" "$GLIBC_ORIG_SHA1" \
        "glibc_$v.debian.tar.xz" "$GLIBC_DEBIAN_TAR_SHA256" "$GLIBC_DEBIAN_TAR_SHA1" \
        "libc6_${v}_arm64.deb" "$LIBC6_DEB_SHA256" "$LIBC6_DEB_SHA1"
}

# ---------------------------------------------------------------------------------------
# Container-side helpers (paths fixed by build-all.sh: /pb = pack-builder (ro), /work = rw)
# ---------------------------------------------------------------------------------------
PB="${PB:-/pb}"
WORK="${WORK:-/work}"
SRC="$WORK/src"
BUILD="$WORK/build"
STAGE="$WORK/stage"
DIST="$WORK/dist"
PACKTOOL="$PB/lib/packtool.py"

# Loads the resolved configuration written by build-all.sh (falls back to versions.env).
load_config() {
    if [ -f "$WORK/config.env" ]; then
        # shellcheck disable=SC1091
        . "$WORK/config.env"
    else
        # shellcheck disable=SC1091
        . "$PB/versions.env"
    fi
    : "${JOBS:=$(nproc)}"
    export SOURCE_DATE_EPOCH
}

# Gives files created by root inside the container back to the invoking host user.
fix_owner() {
    if [ -n "${HOST_UID:-}" ] && [ "$(id -u)" = 0 ]; then
        chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" "$@" 2>/dev/null || true
    fi
}

# Recreates an empty directory.
fresh_dir() {
    rm -rf "$1"
    mkdir -p "$1"
}

# packdef ID VERSION TYPE INSTALL_DIR REQUIRES(csv) RECOMMENDED(0|1) ARM64(0|1) DESCRIPTION
# Declares a staged pack ($STAGE/ID/) for the post-processing stage.
packdef() {
    python3 "$PACKTOOL" packdef --stage "$STAGE" --id "$1" --version "$2" --type "$3" \
        --install-dir "$4" --requires "$5" --recommended "$6" --arm64 "$7" --description "$8"
}
