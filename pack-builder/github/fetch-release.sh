#!/usr/bin/env bash
# Downloads runtime packs of a GitHub release of the packs repo (built by workflows/build-packs.yml) into
# pmbos/packs-bundle/, from where the Gradle build of :pmbos embeds them into the APK as assets/pmbos/packs/...
# (pmbos/README.md, "Встроенные паки"). PMB OS then installs them offline.
#
# Usage: bash pmbos/tools/pack-builder/github/fetch-release.sh [TAG|latest] [options]
#   TAG                   release tag (e.g. packs-1.0.0-r7); default "latest" = newest non-prerelease release
#   --types a,b,...       only components of these types (rootfs,box64,wine,dxvk,vkd3d,vulkan-driver,misc...);
#                         the "requires" closure is always added, whatever its type
#   --only-recommended    only components marked "recommended" (+ their "requires" closure)
#   --out DIR             output dir (default: pmbos/packs-bundle)
#   --repo OWNER/NAME     packs repo (default kireikosasha/pmbos-runtime, env PMBOS_PACKS_REPO)
#   --base-url URL        take index.json/SHA256SUMS/archives from URL/ instead of GitHub (file:// works; tests)
#   --dry-run             only print what would be bundled
#
# Downloads resume (curl -C -) and are retried; each archive is checked against the size + sha256 of index.json
# AND the line of SHA256SUMS. Archives already present with the right sha256 are reused (also from a previous
# bundle). The written index.json lists only the selected components, with "url" rewritten to the asset file
# name (relative) and the original URL kept as "originUrl" (network fallback of the app). Archives of the previous
# bundle that are no longer selected are deleted. index.json is written last, so an interrupted run never leaves
# a bundle whose index lists missing archives (the Gradle build only bundles a dir that has index.json).
#
# Needs: bash, curl, python3 (JSON, sha256). Works in Git Bash on Windows.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$(cd "$HERE/../../.." && pwd)"          # pmbos/
REPO="${PMBOS_PACKS_REPO:-kireikosasha/pmbos-runtime}"
TAG=latest
TYPES=""
ONLY_REC=0
OUT="$MOD/packs-bundle"
BASE=""
DRY=0

die() { echo "fetch-release: error: $*" >&2; exit 1; }
log() { echo "fetch-release: $*" >&2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --types) [ $# -ge 2 ] || die "--types needs a value"; TYPES="$2"; shift 2 ;;
        --types=*) TYPES="${1#*=}"; shift ;;
        --only-recommended) ONLY_REC=1; shift ;;
        --out) [ $# -ge 2 ] || die "--out needs a value"; OUT="$2"; shift 2 ;;
        --out=*) OUT="${1#*=}"; shift ;;
        --repo) [ $# -ge 2 ] || die "--repo needs a value"; REPO="$2"; shift 2 ;;
        --repo=*) REPO="${1#*=}"; shift ;;
        --base-url) [ $# -ge 2 ] || die "--base-url needs a value"; BASE="$2"; shift 2 ;;
        --base-url=*) BASE="${1#*=}"; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) TAG="$1"; shift ;;
    esac
done

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
    for c in python3 python; do
        if "$c" -c "import json, hashlib" >/dev/null 2>&1; then PY="$c"; break; fi
    done
fi
[ -n "$PY" ] || die "python3 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
# native paths for a Windows python under Git Bash / MSYS
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

if [ -z "$BASE" ]; then
    if [ "$TAG" = latest ]; then BASE="https://github.com/$REPO/releases/latest/download"
    else BASE="https://github.com/$REPO/releases/download/$TAG"; fi
fi
BASE="${BASE%/}"

CURL_RETRY=(--retry 5 --retry-delay 3 --connect-timeout 30)
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then CURL_RETRY+=(--retry-all-errors); fi

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STAGE="$OUT/.fetch"            # resumable downloads; removed after a successful run
mkdir -p "$STAGE"

fetch_small() { # url dest
    curl -fsSL "${CURL_RETRY[@]}" -o "$2.tmp" "$1" || return 1
    mv -f "$2.tmp" "$2"
}

log "release: $BASE/"
fetch_small "$BASE/index.json" "$STAGE/index.src.json" \
    || die "cannot download $BASE/index.json (no such release? not published yet?)"
fetch_small "$BASE/SHA256SUMS" "$STAGE/SHA256SUMS.src" || die "cannot download $BASE/SHA256SUMS"

# ---- plan: select components, cross-check index vs SHA256SUMS, write the bundle index (to the stage dir)
PLAN="$STAGE/plan.tsv"
"$PY" -I - "$(win "$STAGE/index.src.json")" "$(win "$STAGE/SHA256SUMS.src")" "$BASE" "$TYPES" "$ONLY_REC" \
    "$(win "$STAGE/index.json")" "$(win "$PLAN")" "$TAG" <<'PYEOF'
import json, sys, time, urllib.parse, posixpath
src, sums_path, base, types, only_rec, out_index, out_plan, tag = sys.argv[1:9]
idx = json.load(open(src, encoding="utf-8"))
if idx.get("format", 1) > 1:
    sys.exit("index format %s is newer than this script understands" % idx.get("format"))
comps = [c for c in idx.get("components", []) if isinstance(c, dict) and c.get("id") and c.get("type")]
by_id = {c["id"]: c for c in comps}
sums = {}
for line in open(sums_path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    parts = line.split(None, 1)
    if len(parts) != 2 or len(parts[0]) != 64:
        sys.exit("bad SHA256SUMS line: %r" % line)
    sums[parts[1].lstrip("*").strip()] = parts[0].lower()

def is_abs(u):
    i = u.find(":")
    return i > 1 and u[:i].replace("+", "").replace("-", "").replace(".", "").isalnum() and u[0].isalpha()

def safe(c, name):
    # the name becomes a path below --out (and an APK asset): no traversal, absolute paths, backslashes or NUL,
    # checked AFTER %-decoding ("%2e%2e%2f" would otherwise escape the bundle dir)
    segs = name.split("/")
    if (not name or name.startswith("/") or "\\" in name or "\0" in name or ":" in segs[0]
            or any(s in ("", ".", "..") for s in segs)):
        sys.exit("%s: unsafe asset name %r" % (c["id"], name))
    return name

def asset_name(c):
    u = (c.get("url") or "").strip()
    if u and not is_abs(u):
        p = urllib.parse.unquote(u.split("?")[0].split("#")[0])
        return safe(c, posixpath.normpath(p) if not p.startswith("/") else p)
    if u:
        name = urllib.parse.unquote(urllib.parse.urlsplit(u).path.rsplit("/", 1)[-1])
        if name and name not in (".", ".."):
            return safe(c, name)
    return safe(c, "%s-%s.%s" % (c["id"], c.get("version", "0"), c.get("archive") or "tar.xz"))

def satisfies(c, t):
    return c["type"] == t or t in (c.get("provides") or [])

def vkey(v):
    out = []
    for s in str(v).replace("-", ".").replace("_", ".").replace("+", ".").split("."):
        out.append((1, int(s), "") if s.isdigit() else (0, 0, s))
    return out

want_types = [t.strip() for t in types.split(",") if t.strip()]
sel = [c for c in comps
       if (not want_types or any(satisfies(c, t) for t in want_types))
       and (only_rec != "1" or c.get("recommended"))]
if not sel:
    sys.exit("no component matches (types=%s, only-recommended=%s); index has: %s"
             % (types or "all", only_rec == "1", ", ".join("%s(%s)" % (c["id"], c["type"]) for c in comps)))
# "requires" closure (ids, or "type:<t>" -> recommended/newest of that type), like RuntimeManager does
chosen, order = set(), []
def add(c, stack=()):
    if c["id"] in chosen:
        return
    if c["id"] in stack:
        sys.exit("dependency cycle at %s" % c["id"])
    for r in c.get("requires") or []:
        if r.startswith("type:"):
            t = r[5:]
            if any(satisfies(by_id[i], t) for i in chosen):
                continue
            # a selected component of that type, else the recommended one, else the newest
            pool = ([x for x in sel if satisfies(x, t)] or [x for x in comps if satisfies(x, t) and x.get("recommended")]
                    or [x for x in comps if satisfies(x, t)])
            if not pool:
                sys.exit("%s requires a '%s' component, none in the release" % (c["id"], t))
            add(max(pool, key=lambda x: vkey(x.get("version", "0"))), stack + (c["id"],))
        else:
            if r not in by_id:
                sys.exit("%s requires '%s', which is not in the release" % (c["id"], r))
            add(by_id[r], stack + (c["id"],))
    chosen.add(c["id"])
    order.append(c)
for c in sel:
    add(c)
extra = [c["id"] for c in order if c not in sel]

plan, out_comps, total = [], [], 0
for c in order:
    name = asset_name(c)
    sha = (c.get("sha256") or "").lower()
    size = int(c.get("size") or 0)
    if len(sha) != 64:
        sys.exit("%s: index has no sha256" % c["id"])
    if size <= 0:
        sys.exit("%s: index has no size" % c["id"])
    if sums.get(name) != sha:
        sys.exit("%s: sha256 in index.json (%s) and SHA256SUMS (%s) disagree for %s"
                 % (c["id"], sha, sums.get(name, "missing"), name))
    u = (c.get("url") or "").strip()
    origin = u if is_abs(u) else base + "/" + urllib.parse.quote(name)
    plan.append("\t".join([c["id"], name, origin, sha, str(size)]))
    oc = dict(c)
    oc["url"] = name
    oc["originUrl"] = origin
    out_comps.append(oc)
    total += size
new = dict(idx)
new["components"] = out_comps
new["bundled"] = {"tag": tag, "from": base, "fetched": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
with open(out_index, "w", encoding="utf-8", newline="\n") as f:
    json.dump(new, f, indent=2)
    f.write("\n")
with open(out_plan, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(plan) + "\n")
sys.stderr.write("fetch-release: %d components, %.1f MiB%s\n" % (len(order), total / 1048576.0,
                 (" (added as requirements: %s)" % ", ".join(extra)) if extra else ""))
for c in order:
    sys.stderr.write("  %-22s %-14s %-14s %s\n" % (c["id"], c["type"], c.get("version", ""),
                     "recommended" if c.get("recommended") else ""))
PYEOF

sha_of() { "$PY" -I -c 'import hashlib,sys
h=hashlib.sha256()
with open(sys.argv[1],"rb") as f:
    for b in iter(lambda: f.read(1<<20), b""): h.update(b)
print(h.hexdigest())' "$(win "$1")"; }
size_of() { wc -c < "$1" | tr -d ' '; }

if [ "$DRY" = 1 ]; then
    log "dry run: nothing downloaded"
    # keep the resumable downloads of an interrupted earlier run
    rm -f "$STAGE/index.src.json" "$STAGE/SHA256SUMS.src" "$STAGE/index.json" "$PLAN"
    rmdir "$STAGE" 2>/dev/null || true
    exit 0
fi

# ---- download + verify
# From here on the old bundle is incomplete: drop its index first, so Gradle never bundles a half-updated dir.
rm -f "$OUT/index.json"
while IFS=$'\t' read -r id name url sha size; do
    [ -n "$id" ] || continue
    dst="$STAGE/$name"
    mkdir -p "$(dirname "$dst")"
    # reuse a verified copy: an earlier interrupted run, or the previous bundle (moved, not copied)
    reused=0
    for have in "$dst" "$OUT/$name"; do
        if [ -f "$have" ] && [ "$(size_of "$have")" = "$size" ] && [ "$(sha_of "$have")" = "$sha" ]; then
            [ "$have" = "$dst" ] || mv -f "$have" "$dst"
            reused=1
            break
        fi
    done
    if [ "$reused" = 1 ]; then log "ok      $name (already here)"; continue; fi
    rm -f "$dst"
    ok=0
    for attempt in 1 2 3; do
        have=0; [ -f "$dst.part" ] && have="$(size_of "$dst.part")"
        if [ "$have" -lt "$size" ]; then
            if [ "$have" -gt 0 ]; then log "resume  $name ($have of $size bytes)"; else log "get     $name ($size bytes)"; fi
            curl -fL "${CURL_RETRY[@]}" -C - --progress-bar -o "$dst.part" "$url" \
                || { log "download of $name failed (attempt $attempt), retrying"; sleep 3; continue; }
        fi
        got="$(size_of "$dst.part")"
        if [ "$got" != "$size" ]; then
            log "size mismatch for $name: $got, expected $size - starting over"; rm -f "$dst.part"; continue
        fi
        if [ "$(sha_of "$dst.part")" != "$sha" ]; then
            log "sha256 mismatch for $name - starting over"; rm -f "$dst.part"; continue
        fi
        mv -f "$dst.part" "$dst"; ok=1; break
    done
    [ "$ok" = 1 ] || die "could not download a verified $name from $url"
    log "ok      $name"
done < "$PLAN"

# ---- assemble: archives first, index.json last
keep="$(cut -f2 "$PLAN")"
while IFS=$'\t' read -r id name url sha size; do
    [ -n "$id" ] || continue
    mkdir -p "$(dirname "$OUT/$name")"
    mv -f "$STAGE/$name" "$OUT/$name"
done < "$PLAN"
# drop archives of a previous bundle that are not selected any more
find "$OUT" -path "$STAGE" -prune -o -type f \( -name '*.tar.xz' -o -name '*.tar.zst' -o -name '*.tar.gz' \
        -o -name '*.tar' -o -name '*.zip' -o -name '*.part' \) -print | while read -r f; do
    rel="${f#"$OUT"/}"
    if ! printf '%s\n' "$keep" | grep -qxF "$rel"; then log "remove  $rel (not selected)"; rm -f "$f"; fi
done
while IFS=$'\t' read -r id name url sha size; do
    [ -n "$id" ] && printf '%s  %s\n' "$sha" "$name"
done < "$PLAN" > "$OUT/SHA256SUMS"
total=0
while IFS=$'\t' read -r id name url sha size; do [ -n "$id" ] && total=$((total + size)); done < "$PLAN"
mv -f "$STAGE/index.json" "$OUT/index.json.tmp"
mv -f "$OUT/index.json.tmp" "$OUT/index.json"
rm -rf "$STAGE"
log "bundle ready: $OUT ($(wc -l < "$OUT/SHA256SUMS" | tr -d ' ') archives, $((total / 1048576)) MiB)"
log "next: ./gradlew :app:assembleDebug   (the APK grows by about that much; see pmbos/README.md)"
