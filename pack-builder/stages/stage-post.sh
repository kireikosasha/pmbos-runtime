#!/usr/bin/env bash
# Stage "post" (tools container): for every staged pack ($STAGE/<id>.pack.json):
#   copy -> relative symlinks -> DT_NEEDED check (arm64) -> PT_INTERP padding (patchelf)
#   -> pmbpack.json -> deterministic tar.xz in $DIST + $DIST/meta/<id>.json
# Staged trees are never modified, so this stage can be re-run.
PB_LOG_PREFIX=post
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$BUILD/post" "$DIST"' EXIT
need_cmd python3 patchelf tar xz

[ -d "$STAGE/imagefs" ] || die "imagefs is not staged (run stage rootfs)"
if [ -z "${ONLY_PACKS:-}" ]; then
    rm -rf "$DIST"   # full run: no stale archives/metadata from earlier version sets
fi
mkdir -p "$DIST/meta" "$BUILD/post"

defs=("$STAGE"/*.pack.json)
[ "${#defs[@]}" -gt 0 ] || die "no staged packs"
for def in "${defs[@]}"; do
    id="$(basename "$def" .pack.json)"
    [ -z "${ONLY_PACKS:-}" ] || case " $ONLY_PACKS " in *" $id "*) ;; *) continue ;; esac
    log "finalizing $id"
    work="$BUILD/post/$id"
    rm -rf "$work"
    cp -a "$STAGE/$id" "$work"
    rm -f "$DIST/meta/$id.json"
    libdirs=()
    case "$id" in
        mesa-*) libdirs=(--libdir "opt/$id/lib") ;;
    esac
    python3 "$PACKTOOL" finalize --packdef "$def" --root "$work" --rootfs "$STAGE/imagefs" \
        --dist "$DIST" --placeholder-len "$INTERP_PLACEHOLDER_LEN" --mtime "$SOURCE_DATE_EPOCH" \
        --xz-opts "$XZ_OPTS" "${libdirs[@]}"
    rm -rf "$work"
done
log "packs written to $DIST"
