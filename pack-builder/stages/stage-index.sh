#!/usr/bin/env bash
# Stage "index" (tools container): writes $DIST/index.json (repo index consumed by
# kireiko.dev.pmb.os.runtime) and $DIST/SHA256SUMS. URLs are BASE_URL/<archive>; with an
# empty BASE_URL they are relative file names (resolve them against the index URL).
PB_LOG_PREFIX=index
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
trap 'fix_owner "$DIST"' EXIT
need_cmd python3

if [ -z "${BASE_URL:-}" ]; then
    warn "BASE_URL not set: index.json will contain relative URLs"
fi
python3 "$PACKTOOL" index --dist "$DIST" --base-url "${BASE_URL:-}" --out "$DIST/index.json" \
    --packset "$PACKSET_VERSION" --mtime "$SOURCE_DATE_EPOCH"
log "upload the contents of $DIST (except meta/) to ${BASE_URL:-<your server>}"
