#!/usr/bin/env bash
# CI helper for .github/workflows/build-packs.yml (GitHub-hosted Ubuntu 24.04 runners, x86_64 and arm64).
# Keeps the workflow YAML small; every command is also usable by hand on a Linux box.
#
# Usage: bash pack-builder/github/ci.sh <command> [args]
#   free-disk                       drop preinstalled SDKs the build does not need (runner only)
#   plan                            resolve tag / base URL / versions -> $GITHUB_OUTPUT (env: EVENT_NAME, REF_NAME,
#                                   INPUT_TAG_SUFFIX, INPUT_WINE_VERSIONS, INPUT_BOX64_VARIANTS, INPUT_PRERELEASE,
#                                   INPUT_DRY_RUN, INPUT_VERIFY_WINE, GITHUB_SERVER_URL, GITHUB_REPOSITORY, ...)
#   save NAME PATTERN...            tar+zstd work-dir paths (globs relative to $PB_WORK) -> $PB_ARTIFACTS/NAME.tar.zst
#   restore [DIR]                   unpack every *.tar.zst of DIR (default $PB_ARTIFACTS) into $PB_WORK
#   images-load DIR                 docker load DIR/*.tar.zst (cached build images), then delete them
#   images-save DIR KIND            docker save pmbos-pack-builder-KIND:* -> DIR/KIND.tar.zst (saved=true|false output)
#   imagefs-manifest                Debian packages (+ source package/version) in imagefs -> build/manifest/
#   check-release BASE_URL          verify $PB_WORK/dist/index.json against the archives (sha256, size, URLs, 2 GiB
#                                   asset limit, required types)
#   sources TAG OUTDIR              SOURCES.txt + pmbos-runtime-sources-TAG.tar (upstream sources + this builder)
#   notes TAG BASE_URL OUT          release notes (markdown)
#   publish TAG PRERELEASE FILE...  draft release, upload with retries, verify, publish (gh CLI, GH_TOKEN)
#   smoke TAG PRERELEASE            fetch the published index (tag + latest URL) and a ranged asset like the app does
set -euo pipefail

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PB_HOST="$(cd "$CI_DIR/.." && pwd)"
PB_LOG_PREFIX=ci
# shellcheck source=../lib/common.sh
. "$PB_HOST/lib/common.sh"
shopt -u nullglob

WORK="${PB_WORK:-${GITHUB_WORKSPACE:-$PWD}/work}"
ART="${PB_ARTIFACTS:-${RUNNER_TEMP:-/tmp}/pb-artifacts}"
GH_SERVER="${GITHUB_SERVER_URL:-https://github.com}"
MAX_ASSET=$((2 * 1024 * 1024 * 1024 - 1))   # GitHub release assets must be < 2 GiB
# The app's Windows launcher asks for these types (WinLauncher.requiredTypes); vkd3d is optional there.
REQUIRED_TYPES="rootfs box64 wine dxvk vulkan-driver"

output() { # key value -> $GITHUB_OUTPUT (or stdout)
    if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
    printf '  %s=%s\n' "$1" "$2" >&2
}
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >> "$GITHUB_STEP_SUMMARY"; else cat >&2; fi; }
# zstd packs the inter-job artifacts and cached images: preinstalled on ubuntu-24.04, installed if a runner image
# (e.g. the arm64 partner image) lacks it
need_zstd() {
    command -v zstd >/dev/null 2>&1 && return 0
    warn "zstd not installed on this runner, installing it"
    { sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zstd; } >&2 \
        || die "cannot install zstd"
}
load_work_config() {
    if [ -f "$WORK/config.env" ]; then
        # shellcheck disable=SC1091
        . "$WORK/config.env"
    else
        # shellcheck source=../versions.env
        . "$PB_HOST/versions.env"
    fi
}

cmd_free_disk() {
    df -h / >&2
    local d
    # /opt/hostedtoolcache (setup-python/node/go caches) too: jobs that call free-disk only need docker, bash
    # and zstd on the host; the actions themselves run on the runner's bundled node.
    for d in /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup /opt/hostedtoolcache \
             /usr/local/share/boost /usr/share/swift /usr/local/julia* /opt/az /usr/local/share/powershell \
             /usr/local/share/chromium /usr/local/lib/node_modules /opt/microsoft /opt/google \
             /usr/share/miniconda /usr/local/share/vcpkg /usr/local/aws-cli /usr/local/aws-sam-cli; do
        [ -e "$d" ] && sudo rm -rf "$d"
    done
    docker image prune -af >/dev/null 2>&1 || true
    df -h / >&2
}

cmd_plan() {
    [ -z "${INPUT_WINE_VERSIONS:-}" ] || export WINE_VERSIONS="$INPUT_WINE_VERSIONS"
    [ -z "${INPUT_BOX64_VARIANTS:-}" ] || export BOX64_VARIANTS="$INPUT_BOX64_VARIANTS"
    # shellcheck source=../versions.env
    . "$PB_HOST/versions.env"
    WINE_VERSIONS="$(echo $WINE_VERSIONS)"      # normalise whitespace
    BOX64_VARIANTS="$(echo $BOX64_VARIANTS)"
    [ -n "$WINE_VERSIONS" ] || die "WINE_VERSIONS is empty"
    local v json="" tag suffix
    for v in $WINE_VERSIONS; do
        [[ "$v" =~ ^[0-9][0-9A-Za-z.-]*$ ]] || die "bad wine version '$v'"
        getv WINE_URL "$v" >/dev/null; getv WINE_SHA256 "$v" >/dev/null; getv WINE_MONO "$v" >/dev/null
        [ -f "$PB_HOST/patches/wine-${v%%.*}-pmbos-tmpdir.patch" ] || die "no patches/wine-${v%%.*}-pmbos-tmpdir.patch for $v"
        json="${json:+$json,}\"$v\""
    done
    case " $BOX64_VARIANTS " in *" generic "*) ;; *) die "BOX64_VARIANTS must contain 'generic'" ;; esac
    for v in $BOX64_VARIANTS; do [[ "$v" =~ ^[a-z0-9]+$ ]] || die "bad box64 variant '$v'"; done

    if [ "${EVENT_NAME:-}" = push ]; then
        tag="${REF_NAME:-}"
    else
        suffix="${INPUT_TAG_SUFFIX:-}"
        suffix="${suffix#packs-}"
        [ -n "$suffix" ] || suffix="$PACKSET_VERSION-r${GITHUB_RUN_NUMBER:-0}"
        tag="packs-$suffix"
    fi
    [[ "$tag" =~ ^packs-[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad release tag '$tag' (packs-<letters, digits, . _ ->)"
    local prerelease=false dry=false verify="${INPUT_VERIFY_WINE:-auto}"
    [ "${INPUT_PRERELEASE:-false}" = true ] && prerelease=true
    [ "${INPUT_DRY_RUN:-false}" = true ] && dry=true
    case "$verify" in auto|0|1) ;; *) die "verify_wine must be auto, 0 or 1" ;; esac
    local repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
    local base="$GH_SERVER/$repo/releases/download/$tag"

    if [ "$dry" = false ] && command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
        local draft
        if draft="$(gh release view "$tag" --repo "$repo" --json isDraft -q .isDraft 2>/dev/null)"; then
            [ "$draft" = true ] || die "release $tag already exists in $repo: pick another tag_suffix (or delete it)"
            warn "a draft release $tag exists (earlier failed run); the publish job replaces it"
        fi
    fi

    log "plan:"
    output tag "$tag"
    output base_url "$base"
    output prerelease "$prerelease"
    output dry_run "$dry"
    output verify_wine "$verify"
    output packset "$PACKSET_VERSION"
    output wine_versions "$WINE_VERSIONS"
    output wine_matrix "[$json]"
    output box64_variants "$BOX64_VARIANTS"
    output cfg_hash "$(printf '%s|%s' "$WINE_VERSIONS" "$BOX64_VARIANTS" | sha256sum | cut -c1-12)"
    summary <<EOF
### PMB OS runtime packs: plan
| | |
|---|---|
| release tag | \`$tag\`$([ "$prerelease" = true ] && echo ' (prerelease)')$([ "$dry" = true ] && echo ' - **dry run, nothing is published**') |
| archive base URL | $base |
| app index URL | $GH_SERVER/$repo/releases/latest/download/index.json |
| packset | $PACKSET_VERSION |
| wine | $WINE_VERSIONS (recommended: ${WINE_VERSIONS%% *}) |
| box64 variants | $BOX64_VARIANTS |
| glibc | $GLIBC_DEBIAN_VERSION (= loader/VERSION) |
EOF
}

cmd_save() {
    local name="${1:?name}" p m
    shift
    need_zstd
    local paths=()
    for p in "$@"; do
        for m in $(cd "$WORK" && compgen -G "$p" || true); do paths+=("$m"); done
    done
    [ "${#paths[@]}" -gt 0 ] || die "save $name: nothing matches $* in $WORK"
    mkdir -p "$ART"
    log "save $name: ${paths[*]}"
    # sudo: stages run as root in the containers; fix_owner hands most files back, not necessarily all
    sudo tar -C "$WORK" --numeric-owner -cf - "${paths[@]}" | zstd -q -T0 -3 -c > "$ART/$name.tar.zst"
    ls -l "$ART/$name.tar.zst" >&2
}

cmd_restore() {
    local dir="${1:-$ART}" f n=0
    need_zstd
    mkdir -p "$WORK"
    for f in "$dir"/*.tar.zst; do
        [ -f "$f" ] || continue
        log "restore $(basename "$f")"
        zstd -q -dc "$f" | sudo tar -C "$WORK" --numeric-owner -xpf -
        rm -f "$f"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || die "restore: no *.tar.zst in $dir"
    sudo chown -R "$(id -u):$(id -g)" "$WORK"
}

cmd_images_load() {
    local dir="${1:?dir}" f
    need_zstd
    for f in "$dir"/*.tar.zst; do
        [ -f "$f" ] || continue
        log "docker load $(basename "$f")"
        zstd -q -dc "$f" | docker load >&2 || warn "docker load of $f failed (the image is rebuilt)"
        rm -f "$f"   # free the disk: images-save writes a new file when the cache missed
    done
}

cmd_images_save() {
    local dir="${1:?dir}" kind="${2:?kind}" imgs
    need_zstd
    imgs="$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E "^pmbos-pack-builder-$kind:" || true)"
    if [ -z "$imgs" ]; then
        warn "no pmbos-pack-builder-$kind image to cache"
        output saved false
        return 0
    fi
    mkdir -p "$dir"
    # shellcheck disable=SC2086
    docker save $imgs | zstd -q -T0 -3 -c > "$dir/$kind.tar.zst"
    ls -l "$dir/$kind.tar.zst" >&2
    output saved true
}

cmd_imagefs_manifest() {
    local raw="$WORK/build/rootfs-raw" out="$WORK/build/manifest"
    mkdir -p "$out"
    [ -d "$raw" ] || die "$raw missing (run stage rootfs first)"
    # package version source source-version, from the dpkg database if mmdebstrap wrote one, else from the
    # first line of every package's changelog.Debian.gz ("source (version) suite; urgency=...")
    {
        if [ -s "$raw/var/lib/dpkg/status" ]; then
            awk '
                function flush() {
                    if (p != "" && st ~ /installed$/) {
                        sn = p; sv = v
                        if (s != "") { split(s, a, " "); sn = a[1]; if (a[2] != "") { sv = a[2]; gsub(/[()]/, "", sv) } }
                        print p, v, sn, sv
                    }
                    p = v = s = st = ""
                }
                /^Package: / { p = $2 } /^Version: / { v = $2 } /^Status: / { st = $0 }
                /^Source: / { s = substr($0, 9) }
                /^$/ { flush() } END { flush() }' "$raw/var/lib/dpkg/status"
        else
            local d line
            for d in "$raw"/usr/share/doc/*/; do
                d="${d%/}"
                [ -L "$d" ] && continue
                [ -f "$d/changelog.Debian.gz" ] || continue
                line="$(zcat "$d/changelog.Debian.gz" | sed -n '1s/^\([^ ]*\) (\([^)]*\)).*/\1 \2/p')"
                [ -n "$line" ] && echo "$(basename "$d") ? $line"
            done
        fi
    } | LC_ALL=C sort -u > "$out/imagefs-packages.txt"
    [ -s "$out/imagefs-packages.txt" ] || die "could not list the imagefs Debian packages"
    log "imagefs packages: $(wc -l < "$out/imagefs-packages.txt")"
}

cmd_check_release() {
    local base="${1:?base url}"
    [ -f "$WORK/dist/index.json" ] || die "$WORK/dist/index.json missing (run stage index)"
    (cd "$WORK/dist" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS does not match the archives"
    python3 -I - "$WORK/dist" "$base" "$MAX_ASSET" "$REQUIRED_TYPES" <<'PY' | summary
import hashlib, json, os, sys, urllib.parse
dist, base, max_asset, required = sys.argv[1], sys.argv[2].rstrip("/"), int(sys.argv[3]), sys.argv[4].split()
idx = json.load(open(os.path.join(dist, "index.json")))
err = []
if idx.get("format") != 1:
    err.append("index format %r != 1" % idx.get("format"))
comps = idx.get("components") or []
if not comps:
    err.append("no components")
ids = {c["id"] for c in comps}
files = set()
rows = []
total = 0
for c in comps:
    url = c["url"]
    if not url.startswith(base + "/"):
        err.append("%s: url %s is not below %s" % (c["id"], url, base))
        continue
    name = urllib.parse.unquote(url[len(base) + 1:])
    if "/" in name or name in files:
        err.append("%s: bad or duplicate asset name %s" % (c["id"], name))
    files.add(name)
    path = os.path.join(dist, name)
    if not os.path.isfile(path):
        err.append("%s: %s missing" % (c["id"], name))
        continue
    size = os.path.getsize(path)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    if size != c["size"]:
        err.append("%s: size %d != index %d" % (c["id"], size, c["size"]))
    if h.hexdigest() != c["sha256"].lower():
        err.append("%s: sha256 differs from the index" % c["id"])
    if size > max_asset:
        err.append("%s: %s is %d bytes, GitHub release assets must be < 2 GiB (lower XZ_OPTS or drop content)" % (c["id"], name, size))
    if c.get("archive") != "tar.xz":
        err.append("%s: archive %r" % (c["id"], c.get("archive")))
    for r in c.get("requires", []):
        if r not in ids and not r.startswith("type:"):
            err.append("%s requires %s which is not in the index" % (c["id"], r))
    total += size
    rows.append("| %s | %s | %s | %s | %.1f MiB | %.1f MiB |" % (c["id"], c["version"], c["type"],
                "yes" if c.get("recommended") else "", size / 1048576.0, c.get("installedSize", 0) / 1048576.0))
for t in required:
    of_type = [c for c in comps if c["type"] == t]
    if not of_type:
        err.append("required type %s missing" % t)
    elif not any(c.get("recommended") for c in of_type):
        err.append("no recommended component of type %s" % t)
extra = sorted(set(os.listdir(dist)) - files - {"index.json", "SHA256SUMS", "meta"})
if extra:
    err.append("unexpected files in dist: %s" % ", ".join(extra))
print("### Release contents (%d packs, %.1f MiB)" % (len(comps), total / 1048576.0))
print("| id | version | type | recommended | archive | installed |")
print("|---|---|---|---|---|---|")
print("\n".join(rows))
if err:
    for e in err:
        print("ERROR: " + e, file=sys.stderr)
    sys.exit(1)
print("\nindex.json verified: every URL below %s, sha256 + size match, all < 2 GiB, types %s present." % (base, ", ".join(required)))
PY
}

cmd_sources() {
    local tag="${1:?tag}" out="${2:?outdir}"
    load_work_config
    local src="$WORK/src" stg="$WORK/sources-tmp"
    [ -d "$src" ] || die "$src missing (restore the pb-src artifact)"
    rm -rf "$stg"
    mkdir -p "$stg/upstream/glibc" "$stg/builder" "$out"
    local v gv="${GLIBC_DEBIAN_VERSION#*:}" f
    cp "$src/libxcb-$LIBXCB_VERSION.tar.xz" "$src/mesa-$MESA_VERSION.tar.xz" "$stg/upstream/"
    for v in $WINE_VERSIONS; do cp "$src/wine-$v.tar.xz" "$stg/upstream/"; done
    for f in "glibc_$gv.dsc" "glibc_${gv%%-*}.orig.tar.xz" "glibc_$gv.debian.tar.xz"; do
        cp "$src/glibc/$f" "$stg/upstream/glibc/"
    done
    git -c safe.directory='*' -C "$src/box64-$BOX64_COMMIT" archive --format=tar.gz \
        --prefix="box64-$BOX64_VERSION/" -o "$stg/upstream/box64-$BOX64_VERSION-${BOX64_COMMIT:0:12}.tar.gz" "$BOX64_COMMIT"
    # the complete build recipe: this pack builder (stages, patches, docker files, versions.env) + loader pin
    tar -C "$PB_HOST" --exclude=./out --exclude=__pycache__ -cf - . | tar -C "$stg/builder" -xf -
    mkdir -p "$stg/loader"
    cp "$PB_HOST/../loader/VERSION" "$stg/loader/VERSION"

    local packages="$WORK/build/manifest/imagefs-packages.txt"
    {
        echo "PMB OS runtime packs $tag - corresponding sources"
        echo "Built by ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-?} at commit ${GITHUB_SHA:-?}"
        echo "Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-?}/actions/runs/${GITHUB_RUN_ID:-?}"
        echo
        echo "Every binary in this release is built from, or repackaged from, the sources listed here."
        echo "pmbos-runtime-sources-$tag.tar (asset of this release) contains: upstream/ = the exact source"
        echo "archives of everything compiled (sha256 below), builder/ = the build scripts, patches/ and"
        echo "Dockerfiles used (run builder/build-all.sh to rebuild), loader/VERSION = glibc pin."
        echo
        echo "== Compiled from source (sources in upstream/) =="
        echo "glibc     Debian $GLIBC_DEBIAN_VERSION  LGPL-2.1-or-later (+ GPL-2.0 parts)"
        echo "          https://snapshot.debian.org/package/glibc/$GLIBC_DEBIAN_VERSION/"
        echo "          .dsc $GLIBC_DSC_SHA256"
        echo "          .orig.tar.xz $GLIBC_ORIG_SHA256"
        echo "          .debian.tar.xz $GLIBC_DEBIAN_TAR_SHA256"
        echo "          patches: builder/patches/glibc-${gv%%-*}-pmbos-rootfs.patch, builder/patches/glibc-${gv%%-*}-pmbos-execve.patch"
        echo "libxcb    $LIBXCB_VERSION  MIT  $LIBXCB_URL"
        echo "          sha256 $LIBXCB_SHA256  patch: builder/patches/libxcb-$LIBXCB_VERSION-pmbos-tmpdir.patch"
        echo "box64     $BOX64_VERSION (commit $BOX64_COMMIT)  MIT  $BOX64_GIT"
        echo "          patch: builder/patches/box64-$BOX64_VERSION-pmbos-shm-plt.patch; variants: $BOX64_VARIANTS"
        for v in $WINE_VERSIONS; do
            echo "wine      $v  LGPL-2.1-or-later  $(getv WINE_URL "$v")"
            echo "          sha256 $(getv WINE_SHA256 "$v")  patch: builder/patches/wine-${v%%.*}-pmbos-tmpdir.patch"
        done
        echo "mesa      $MESA_VERSION  MIT (+ other permissive licenses, docs/license.rst)  $MESA_URL"
        echo "          sha256 $MESA_SHA256  (unmodified; meson options in builder/stages/stage-mesa.sh)"
        echo "libpmbshm $PACKSET_VERSION  part of this builder: builder/src/pmbshm.c"
        echo
        echo "== Redistributed unmodified upstream binaries (repacked) =="
        echo "DXVK          $DXVK_VERSION  zlib/libpng  $DXVK_URL"
        echo "              source: https://github.com/doitsujin/dxvk/tree/v$DXVK_VERSION"
        echo "VKD3D-Proton  $VKD3D_VERSION  LGPL-2.1-or-later  $VKD3D_URL"
        echo "              source: https://github.com/HansKristian-Work/vkd3d-proton/tree/v$VKD3D_VERSION (with submodules)"
        local m
        declare -A seen=()
        for v in $WINE_VERSIONS; do
            m="$(getv WINE_MONO "$v")"
            [ -n "${seen[$m]:-}" ] && continue
            seen[$m]=1
            echo "wine-mono     $m  MIT / LGPL / MPL mix  $(getv WINE_MONO_URL "$m")"
            echo "              source: https://dl.winehq.org/wine/wine-mono/$m/ (wine-mono-$m-src.tar.xz)"
        done
        echo "wine-gecko    $WINE_GECKO_VERSION  MPL-2.0  $WINE_GECKO_X86_URL"
        echo "              $WINE_GECKO_X64_URL"
        echo "              source: https://dl.winehq.org/wine/wine-gecko/$WINE_GECKO_VERSION/ (wine-gecko-$WINE_GECKO_VERSION-src.tar.xz)"
        echo
        echo "== Debian $DEBIAN_SUITE arm64 binary packages in imagefs (unmodified except libc6 and libxcb1, see above) =="
        echo "Sources: https://snapshot.debian.org/package/<source>/<source version>/ ; licenses: usr/share/doc/<package>/copyright in imagefs"
        if [ -s "$packages" ]; then
            echo "package version source source-version"
            cat "$packages"
        else
            echo "(package list not available for this build)"
        fi
    } > "$out/SOURCES.txt"
    cp "$out/SOURCES.txt" "$stg/SOURCES.txt"
    tar -C "$stg" --owner=0 --group=0 --numeric-owner --sort=name -cf "$out/pmbos-runtime-sources-$tag.tar" .
    rm -rf "$stg"
    ls -l "$out" >&2
}

cmd_notes() {
    local tag="${1:?tag}" base="${2:?base}" out="${3:?out}"
    load_work_config
    local repo="${GITHUB_REPOSITORY:-?}"
    {
        echo "Runtime packs for PMB OS (Windows apps: imagefs rootfs, box64, Wine, Mesa Turnip/Zink, DXVK, VKD3D-Proton)."
        echo
        echo "The app downloads them automatically from \`$GH_SERVER/$repo/releases/latest/download/index.json\`"
        echo "(newest non-prerelease release). This release's own index: \`$base/index.json\`."
        echo
        echo "* packset $PACKSET_VERSION, glibc $GLIBC_DEBIAN_VERSION (+ pmbos patches, = APK loader), box64 $BOX64_VERSION ($BOX64_VARIANTS),"
        echo "  Wine $WINE_VERSIONS (recommended: ${WINE_VERSIONS%% *}), Mesa $MESA_VERSION, DXVK $DXVK_VERSION, VKD3D-Proton $VKD3D_VERSION"
        echo "* built from $repo@${GITHUB_SHA:-?} by $GH_SERVER/$repo/actions/runs/${GITHUB_RUN_ID:-?}"
        echo "* \`SHA256SUMS\` lists every archive; \`index.json\` carries sha256 + size, verified by the app."
        echo "* Sources and licenses: \`SOURCES.txt\` and \`pmbos-runtime-sources-$tag.tar\` (upstream source archives,"
        echo "  patches and the complete build scripts). Wine, glibc and VKD3D-Proton are LGPL-2.1+, box64 and Mesa MIT,"
        echo "  DXVK zlib, wine-gecko MPL-2.0."
        echo
        python3 -I - "$WORK/dist/index.json" <<'PY'
import json, sys
idx = json.load(open(sys.argv[1]))
print("| pack | version | type | size |")
print("|---|---|---|---|")
for c in idx["components"]:
    print("| %s%s | %s | %s | %.1f MiB |" % (c["id"], " (recommended)" if c.get("recommended") else "",
          c["version"], c["type"], c["size"] / 1048576.0))
PY
    } > "$out"
}

gh_retry() { # gh with retries (transient API / upload errors)
    local i
    for i in 1 2 3 4 5; do
        if gh "$@"; then return 0; fi
        warn "gh $1 $2 failed (attempt $i), retrying"
        sleep $((i * 10))
    done
    return 1
}

cmd_publish() {
    local tag="${1:?tag}" prerelease="${2:?prerelease}"
    shift 2
    local repo="${GITHUB_REPOSITORY:?}" f draft names
    need_cmd gh
    [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN not set"
    [ -f "${NOTES_FILE:-}" ] || die "NOTES_FILE not set"
    for f in "$@"; do [ -f "$f" ] || die "asset $f missing"; done
    names="$(for f in "$@"; do basename "$f"; done | sort)"
    [ -z "$(uniq -d <<<"$names")" ] || die "duplicate asset names: $(uniq -d <<<"$names" | tr '\n' ' ')"
    if draft="$(gh release view "$tag" --repo "$repo" --json isDraft -q .isDraft 2>/dev/null)"; then
        [ "$draft" = true ] || die "release $tag already exists (and is published)"
        log "deleting the draft $tag left by an earlier run"
        gh release delete "$tag" --repo "$repo" --yes
    fi
    log "creating draft release $tag"
    gh_retry release create "$tag" --repo "$repo" --draft --target "${GITHUB_SHA:?}" \
        --title "PMB OS runtime packs $tag" --notes-file "$NOTES_FILE"
    for f in "$@"; do
        log "upload $(basename "$f") ($(du -h "$f" | cut -f1))"
        gh_retry release upload "$tag" "$f" --repo "$repo" --clobber
    done
    # every asset present with the local size (uploads are not resumable; catch truncated ones)
    local listed
    listed="$(gh release view "$tag" --repo "$repo" --json assets -q '.assets[] | "\(.name) \(.size)"')"
    for f in "$@"; do
        grep -qxF "$(basename "$f") $(stat -c %s "$f")" <<<"$listed" \
            || die "asset $(basename "$f") missing or wrong size on the release"
    done
    log "publishing $tag"
    if [ "$prerelease" = true ]; then
        gh_retry release edit "$tag" --repo "$repo" --draft=false --prerelease
    else
        gh_retry release edit "$tag" --repo "$repo" --draft=false --latest
    fi
    summary <<EOF
### Published
* release: $GH_SERVER/$repo/releases/tag/$tag$([ "$prerelease" = true ] && echo ' (prerelease: not used by the app default URL)')
* app index URL: $GH_SERVER/$repo/releases/latest/download/index.json
EOF
}

cmd_smoke() {
    local tag="${1:?tag}" prerelease="${2:?prerelease}"
    local repo="${GITHUB_REPOSITORY:?}" tmp i ok
    local base="$GH_SERVER/$repo/releases/download/$tag"
    tmp="$(mktemp -d)"
    # like the app: follow 302 github.com -> signed CDN URL
    curl -fsSL --retry 5 --retry-all-errors -o "$tmp/index.json" "$base/index.json"
    cmp -s "$tmp/index.json" "$WORK/dist/index.json" || die "published index.json differs from the built one"
    log "tag index OK: $base/index.json"
    if [ "$prerelease" != true ]; then
        ok=0
        for i in 1 2 3 4 5 6; do
            if curl -fsSL -o "$tmp/latest.json" "$GH_SERVER/$repo/releases/latest/download/index.json" \
                    && cmp -s "$tmp/latest.json" "$WORK/dist/index.json"; then ok=1; break; fi
            sleep 10
        done
        [ "$ok" = 1 ] || die "releases/latest/download/index.json does not serve this release's index"
        log "latest index OK: $GH_SERVER/$repo/releases/latest/download/index.json"
    fi
    # resumable downloads: a Range request must survive the redirect and return 206 with the right bytes
    local first url name code
    first="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"][0]["url"])' "$WORK/dist/index.json")"
    name="$(basename "$first")"
    code="$(curl -sSL --retry 5 -r 1000-4095 -o "$tmp/range.bin" -w '%{http_code}' "$first")"
    [ "$code" = 206 ] || die "Range request for $name answered $code (expected 206)"
    [ "$(stat -c %s "$tmp/range.bin")" = 3096 ] && cmp -s -i 1000:0 -n 3096 "$WORK/dist/$name" "$tmp/range.bin" \
        || die "Range content mismatch for $name"
    log "Range/206 through the redirect OK ($name)"
    url="$GH_SERVER/$repo/releases/latest/download/index.json"
    summary <<EOF
* smoke test passed: index.json (tag$([ "$prerelease" != true ] && echo ' + latest')) and a ranged download of \`$name\`
* set nothing in the app: its default index URL is $url
EOF
    rm -rf "$tmp"
}

cmd="${1:-}"
[ -n "$cmd" ] || { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 2; }
shift
case "$cmd" in
    free-disk) cmd_free_disk "$@" ;;
    plan) cmd_plan "$@" ;;
    save) cmd_save "$@" ;;
    restore) cmd_restore "$@" ;;
    images-load) cmd_images_load "$@" ;;
    images-save) cmd_images_save "$@" ;;
    imagefs-manifest) cmd_imagefs_manifest "$@" ;;
    check-release) cmd_check_release "$@" ;;
    sources) cmd_sources "$@" ;;
    notes) cmd_notes "$@" ;;
    publish) cmd_publish "$@" ;;
    smoke) cmd_smoke "$@" ;;
    *) die "unknown command: $cmd" ;;
esac
