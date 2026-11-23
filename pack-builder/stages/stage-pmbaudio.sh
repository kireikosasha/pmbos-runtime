#!/usr/bin/env bash
# Stage "pmbaudio" (arm64 container): builds libasound_module_pcm_pmbos.so - the ALSA PCM plugin through which the
# programs of the rootfs (Wine's winealsa.drv, through box64's libasound wrapper) play sound in the PMB OS app
# (src/pmbaudio.c) - and runs its self-test against a stand-in for the app's server before anything ships.
PB_LOG_PREFIX=pmbaudio
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
out="$BUILD/pmbaudio"
trap 'fix_owner "$out"' EXIT
need_cmd gcc strip readelf

# alsa-lib's headers: the same Debian release as the libasound.so.2 of the imagefs (ROOTFS_OPTIONAL_PACKAGES).
# Installed here on demand so that the cached arm64 build image stays valid.
if [ ! -f /usr/include/alsa/pcm_external.h ]; then
    log "installing libasound2-dev into the build container"
    apt-get update -q >/dev/null || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends libasound2-dev >/dev/null \
        || die "apt-get install libasound2-dev failed"
fi
[ -f /usr/include/alsa/pcm_external.h ] || die "alsa/pcm_external.h still missing"

fresh_dir "$out"
# (no -fvisibility=hidden: alsa-lib finds the plugin through two exported symbols, everything else is static)
CFLAGS=(-std=gnu11 -O2 -g0 -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -Wall -Wextra -Werror)

log "compiling libasound_module_pcm_pmbos.so"
gcc "${CFLAGS[@]}" -shared -Wl,-soname,libasound_module_pcm_pmbos.so -Wl,-z,now -Wl,-z,relro -Wl,--as-needed \
    -Wl,--no-undefined -o "$out/libasound_module_pcm_pmbos.so" "$PB/src/pmbaudio.c" -lasound
strip --strip-unneeded "$out/libasound_module_pcm_pmbos.so"

exports="$(readelf --dyn-syms -W "$out/libasound_module_pcm_pmbos.so" \
    | awk '$5 == "GLOBAL" && $7 != "UND" {print $8}' | sed 's/@.*//' | sort | tr '\n' ' ')"
[ "$exports" = "__snd_pcm_pmbos_open_dlsym_pcm_001 _snd_pcm_pmbos_open " ] || die "unexpected exported symbols: $exports"

log "compiling self-test"
gcc -std=gnu11 -O1 -Wall -Wextra -Werror -o "$out/pmbaudio-test" "$PB/src/pmbaudio-test.c" -lasound -lpthread

scratch="$(mktemp -d)"
log "running self-test (scratch $scratch)"
if ! "$out/pmbaudio-test" "$out/libasound_module_pcm_pmbos.so" "$scratch"; then
    die "pmbaudio self-test failed"
fi
rm -rf "$scratch"
log "libasound_module_pcm_pmbos.so OK"
