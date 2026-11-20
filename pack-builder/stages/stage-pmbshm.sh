#!/usr/bin/env bash
# Stage "pmbshm" (arm64 container): builds libpmbshm.so (SysV shm emulation, LD_PRELOAD)
# and runs its self-test against the contract before anything ships.
PB_LOG_PREFIX=pmbshm
# shellcheck source=../lib/common.sh
. /pb/lib/common.sh
load_config
out="$BUILD/pmbshm"
trap 'fix_owner "$out"' EXIT
need_cmd gcc strip readelf

fresh_dir "$out"
CFLAGS=(-std=gnu11 -O2 -g0 -fPIC -fvisibility=hidden -D_GNU_SOURCE -D_FORTIFY_SOURCE=2
        -fstack-protector-strong -Wall -Wextra -Werror)

log "compiling libpmbshm.so"
gcc "${CFLAGS[@]}" -shared -Wl,-soname,libpmbshm.so -Wl,-z,now -Wl,-z,relro -Wl,--as-needed \
    -o "$out/libpmbshm.so" "$PB/src/pmbshm.c" -ldl -lpthread
strip --strip-unneeded "$out/libpmbshm.so"

exports="$(readelf --dyn-syms -W "$out/libpmbshm.so" \
    | awk '$5 == "GLOBAL" && $7 != "UND" {print $8}' | sed 's/@.*//' | sort | tr '\n' ' ')"
# shm* = SysV emulation; mmap/mmap64/mprotect = W^X fallback (see pmbshm.c)
[ "$exports" = "mmap mmap64 mprotect shmat shmctl shmdt shmget " ] || die "unexpected exported symbols: $exports"

log "compiling self-test"
gcc -std=gnu11 -O1 -Wall -Wextra -Werror -o "$out/pmbshm-test" "$PB/src/pmbshm-test.c" -lpthread

shmdir="$(mktemp -d)"
log "running self-test (PMBOS_SHM_DIR=$shmdir)"
if ! PMBOS_SHM_DIR="$shmdir" LD_PRELOAD="$out/libpmbshm.so" "$out/pmbshm-test" "$shmdir"; then
    die "libpmbshm self-test failed"
fi
rm -rf "$shmdir"
log "libpmbshm.so OK"
