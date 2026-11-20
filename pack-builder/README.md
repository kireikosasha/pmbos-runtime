# PMB OS runtime pack builder

Reproducible Linux pipeline that produces the plug&play runtime packs installed by
`kireiko.dev.pmb.os.runtime` (see `pmbos/docs/ARCHITECTURE.md`, "Runtime packs") and the
repo `index.json` that points at them.

| Pack id | type | installDir (relative to `files/pmbos/runtime/`) | Content |
|---|---|---|---|
| `imagefs` | rootfs | `imagefs` | Debian bookworm arm64 glibc **rebuilt with the PMBOS_ROOTFS + PMBOS_LOADER patches** (loader at `lib/ld-linux-aarch64.so.1`), `bin/sh` (dash), X11/xcb (patched libxcb), Vulkan loader, FreeType/fontconfig + DejaVu/Liberation, GnuTLS + CA bundle, ALSA/Pulse client libs, `usr/lib/libpmbshm.so`, `/etc` (templates + netbase services/protocols), `usr/share/zoneinfo`, `tmp/` |
| `box64` | box64 | `imagefs` | `usr/bin/box64` (generic ARMv8 dynarec, patched), `usr/lib/box64-x86_64-linux-gnu/*`, `etc/box64.box64rc` |
| `box64-<soc>` | box64 | `imagefs` | `usr/bin/box64-<soc>` (e.g. `sd8g2`, `sd888`), needs `box64` |
| `wine-<ver>` | wine | `imagefs` | `opt/wine-<ver>/` new WoW64 build (x86_64 unix side + x86_64/i386 PE), patched server dir |
| `wine-mono-<ver>` | misc | `imagefs` | `opt/wine-addons/mono/wine-mono-<ver>/` (required by the matching wine) |
| `wine-gecko-<ver>` | misc | `imagefs` | `opt/wine-addons/gecko/wine-gecko-<ver>-{x86,x86_64}/` (optional) |
| `mesa-<ver>` | vulkan-driver | `imagefs` | `opt/mesa-<ver>/`: Turnip (Adreno, KGSL) Vulkan ICD + Zink `libGL.so.1`/`libEGL.so.1`, X11 WSI |
| `dxvk-<ver>` | dxvk | `components/dxvk-<ver>` | `x64/*.dll` (-> system32), `x32/*.dll` (-> syswow64) |
| `vkd3d-proton-<ver>` | vkd3d | `components/vkd3d-proton-<ver>` | `x64/*.dll`, `x32/*.dll` |

Pinned upstream versions (all in `versions.env`, every download SHA-256 verified):
Debian bookworm (glibc = Debian source package **2.36-9+deb12u14**, rebuilt - exactly the version
of the stock `ld.so` the APK ships, `pmbos/tools/loader/VERSION`; `build-all.sh` refuses a
mismatch), libxcb 1.15, box64 0.4.4 (commit `2f130fab`), Wine 11.0 (stable,
recommended) + 11.22 (devel), wine-mono 10.4.1 / 11.3.0, wine-gecko 2.47.4, Mesa 26.3.1,
DXVK 3.1.1, VKD3D-Proton 3.1.

## Requirements

* Linux host, **x86_64** or **arm64**, with `bash` and `docker` (or `DOCKER=podman`).
* Cross-architecture containers via qemu-user binfmt_misc. This is only needed for the stages whose
  image architecture differs from the host. On an arm64 host, a run without the `images` and `wine` stages
  (`-s fetch,pmbshm,...`) needs no emulation, and the CI workflow relies on this.
  * x86_64 host -> arm64 containers: `docker run --privileged --rm tonistiigi/binfmt --install arm64`
  * arm64 host -> amd64 container (wine): `... --install amd64`
* ~40 GB free disk, a few hours on 8+ cores (Wine, Mesa and glibc dominate; under qemu
  glibc/Mesa/box64 take considerably longer than natively on arm64 - the glibc rebuild alone is
  roughly 1-3 h under qemu-user, ~15 min natively).
* Network access to deb.debian.org (snapshot.debian.org once the pinned glibc leaves the pool),
  dl.winehq.org, archive.mesa3d.org, xorg.freedesktop.org, github.com and pypi.org (Mesa build tools).
* `pmbos/tools/loader/VERSION` next to the pack builder (the glibc pin is checked against it).

Nothing is installed on the host; every step runs in one of three images built from
`docker/` (`tools` = host arch, `arm64`, `amd64`), all based on the pinned Debian image.

## Usage

```bash
cd pmbos/tools/pack-builder
bash build-all.sh -u https://github.com/<owner>/<repo>/releases/download/runtime-1.0.0   # or ./build-all.sh
```

Options: `-w DIR` work dir (default `./out`), `-s stage,stage` run a subset, `-p "ids"` re-pack
only some staged packs, `-j N` jobs, `--no-verify`. Any variable of `versions.env` can be
overridden from the environment:

```bash
WINE_VERSIONS=11.0 BOX64_VARIANTS=generic ./build-all.sh -u https://example.org/pmbos/runtime
./build-all.sh -s post,verify,index -u https://example.org/pmbos/runtime   # re-pack only
```

Stages (in order): `images` (build env images), `fetch` (verified downloads, incl. the pinned glibc
source package and Debian's `libc6` .deb of the same version: pool, then snapshot.debian.org),
`pmbshm` (build + self-test of the SysV shm shim), `libxcb` (patched libxcb.so.1), `glibc` (the
pinned Debian glibc source + `patches/glibc-2.36-pmbos-rootfs.patch` +
`patches/glibc-2.36-pmbos-execve.patch`, `debian/rules install_libc` with `nocheck`; extracts the
stock `ld.so` = the APK's `libpmbld.so` from the `.deb` (sha256-checked); self-tests:
`src/glibc-rootfs-test.c`, `tests/execve-redirect-hosttest.sh`, and `src/glibc-execve-test.c` with
`PMBOS_LOADER` = the rebuilt and = the stock loader), `rootfs` (mmdebstrap extract, libc6 files
replaced by the rebuild, `/bin/sh`, `/etc`, trimming), `box64`, `wine`, `mesa`, `repack` (DXVK,
VKD3D-Proton, wine-mono, wine-gecko), `post` (pack finalization), `verify` (install every archive
with the reference installer in a scratch runtime dir and smoke-test it, also in LOADER mode
through the stock loader), `index`.

Output in `out/dist/`: `<id>-<version>.tar.xz` (or `<id>.tar.xz` when the id already ends
with the version), `index.json`, `SHA256SUMS`, `meta/` (build metadata, not needed online).

## Hosting

The repo is static files; the runtime downloads `index.json`, then each archive by its `url`,
and verifies `sha256` + `size`. Any HTTPS server works; it should support `Range` requests
(resumable downloads).

**GitHub Actions + Releases (default hosting of the app).** `github/` holds a workflow that builds every
pack on GitHub-hosted runners and publishes a release in the public repo `kireikosasha/pmbos-runtime`.
arm64 stages run natively on `ubuntu-24.04-arm`, so no qemu is needed, and each Wine version gets its own
x86_64 job. The app's `RuntimeManager.DEFAULT_REPO_URL` is
`https://github.com/kireikosasha/pmbos-runtime/releases/latest/download/index.json`. Setup and update steps
(Russian) are in `github/README.md`. `github/export.sh <clone>` copies this directory, `../loader/VERSION`
and the workflow into a checkout of that repo. To run a stage subset per job, `WINE_BUILD_VERSIONS=<v>`
builds only that version in stage wine. "recommended" still follows the first entry of `WINE_VERSIONS`.

**GitHub Releases by hand** (archives must be < 2 GiB each, all are far below):

```bash
TAG=runtime-1.0.0
./build-all.sh -u "https://github.com/<owner>/<repo>/releases/download/$TAG"
gh release create "$TAG" out/dist/*.tar.xz out/dist/index.json out/dist/SHA256SUMS \
    --title "PMB OS runtime $TAG" --notes "Runtime packs for PMB OS"
# repo URL for the app (settings key runtime.repoUrl):
#   https://github.com/<owner>/<repo>/releases/download/runtime-1.0.0/index.json
```

**Any static server** (nginx, S3, Cloudflare R2, ...): upload the contents of `out/dist/`
(except `meta/`) to the directory that `-u` points at. If `-u` is omitted the index contains
relative URLs (bare file names) that the client resolves against the index URL.

## Pack format (contract with `kireiko.dev.pmb.os.runtime`)

* Archive: tar + xz (`xz -9e --threads=0 --check=crc32`, plain LZMA2, **no BCJ/ARM64 filter**;
  -9e implies a 64 MiB dictionary in the decoder - lower with `XZ_OPTS` if needed).
  Tar is `ustar` (decoders must honour the 155-byte `prefix` field); POSIX `pax` extended
  headers (`x` entries with `path`) are used only if some path does not fit ustar.
  Deterministic: sorted names, mtime = `SOURCE_DATE_EPOCH`, uid/gid 0.
* The **first member is `pmbpack.json`**; only regular files and directories follow. No
  symlinks, hard links or device nodes are stored in the tar; empty directories contain a
  zero-byte `.pmbkeep`.
* `pmbpack.json`:

```json
{
 "format": 1, "id": "box64", "version": "0.4.4", "type": "box64", "installDir": "imagefs",
 "requires": ["imagefs"], "description": "...",
 "interpPlaceholder": "/@PMBOS_ROOTFS@____...____/lib/ld-linux-aarch64.so.1",
 "patchInterp": ["usr/bin/box64"],
 "textPatch": [],
 "symlinks": [["../usr/lib/aarch64-linux-gnu", "lib/aarch64-linux-gnu"]],
 "executables": ["usr/bin/box64"],
 "files": 12, "installedSize": 51234567
}
```

  * all paths are relative to the pack's install dir (`runtime/<installDir>`);
  * `interpPlaceholder` is exactly `INTERP_PLACEHOLDER_LEN` (255) characters; `PT_INTERP` of every
    file in `patchInterp` contains it (NUL-terminated). **DIRECT exec mode** (host targetSdk <= 28,
    the kernel execs imagefs files): the runtime must rewrite it **in place** to
    `<abs runtime>/imagefs/lib/ld-linux-aarch64.so.1` + NUL padding up to `p_filesz`.
    **LOADER mode** (targetSdk >= 29, see "Exec modes"): no rewrite is needed - the loader is
    exec'd explicitly and ignores the program's `PT_INTERP`, and the glibc execve redirect only
    looks at its basename (`ld-linux*`), which the placeholder already has. Rewriting anyway is
    harmless. The packs carry the placeholder in both cases;
  * `textPatch`: replace every `@ROOTFS@` with the absolute imagefs path;
  * `symlinks`: `[target, linkpath]`, targets are always relative and stay inside the pack's
    install dir (except the deliberate `opt/wine-<v>/share/wine/{mono,gecko}` -> `opt/wine-addons/...`
    links which point at other packs installed into the same `imagefs`). Create parents as needed;
  * `executables`: chmod 0755 (everything else may be 0644);
  * `patchInterp`/`textPatch`/`executables` currently contain exact paths; a runtime should still
    accept `*` globs (ARCHITECTURE.md example).
  * Several packs share `installDir: "imagefs"`: do not extract `pmbpack.json` into the install
    dir; keep per-pack manifests elsewhere (needed for uninstall).
* `lib/packtool.py install --runtime DIR ARCHIVE` is the **reference installer** - it does exactly
  the above and is what the `verify` stage uses.

`index.json`:

```json
{"format":1,"name":"PMB OS runtime packs","packset":"1.0.0","generated":"2026-01-01T00:00:00Z",
 "components":[{"id":"imagefs","version":"bookworm-1.0.0","type":"rootfs",
   "url":"https://.../imagefs-bookworm-1.0.0.tar.xz","sha256":"...","size":123,"installedSize":456,
   "archive":"tar.xz","installDir":"imagefs","requires":[],"recommended":true,"description":"..."}]}
```

## Patches (`patches/`)

| File | Upstream | Purpose |
|---|---|---|
| `libxcb-1.15-pmbos-tmpdir.patch` | libxcb 1.15 (bookworm) | X11 unix socket at `$PMBOS_TMPDIR/.X11-unix/X<n>`, no abstract-socket attempt then |
| `libxcb-1.17.0-pmbos-tmpdir.patch` | libxcb 1.17.0 (trixie) | same, rebased |
| `wine-11-pmbos-tmpdir.patch` | Wine 11.0 (applies to 11.22) | wineserver dir `$PMBOS_TMPDIR/.wine-<uid>/server-*` (server + ntdll) |
| `box64-0.4.4-pmbos-shm-plt.patch` | box64 v0.4.4 | x86_64 `shmget/shmat/shmdt/shmctl` go through the PLT so the LD_PRELOAD shm emulation is honoured |
| `glibc-2.36-pmbos-rootfs.patch` | glibc 2.36 (Debian bookworm 2.36-9+deb12u14, after Debian's quilt series; also plain 2.36) | libc opens `/etc/{resolv.conf,hosts,nsswitch.conf,services,protocols,passwd,group,shadow,networks,...,gai.conf,host.conf,localtime}`, `/usr/share/zoneinfo` and runs `/bin/sh` (system, popen, wordexp, execvp ENOEXEC fallback) below `$PMBOS_ROOTFS` |
| `glibc-2.36-pmbos-execve.patch` | same tree, applied after the rootfs patch (also plain 2.36) | `execve()` (and so execv*/posix_spawn*/system/popen/wordexp) runs dynamically linked glibc programs and `#!` scripts through `$PMBOS_LOADER` (Android LOADER mode, see "Exec modes"); replaces the `execve` syscall stub with `sysdeps/unix/sysv/linux/execve.c` + `pmbos-execve.h` |

Each patch starts with a description block; with the variable unset every patched component
behaves exactly like upstream. All were verified to apply with `--fuzz=0` (the glibc patches, in
order, against Debian's 2.36-9+deb12u14 tree with its full quilt series applied, and against
plain 2.36).

## Exec modes (Android)

* **DIRECT** (host targetSdk <= 28): the kernel execs imagefs files; `PT_INTERP` rewritten by the
  runtime (`patchInterp`) to `<imagefs>/lib/ld-linux-aarch64.so.1` (the rebuilt loader).
* **LOADER** (targetSdk >= 29: SELinux forbids `execve()` of app data files, but allows `execve()`
  of the APK's extracted native libraries and `mmap(PROT_EXEC)` of app data files): the APK ships
  Debian's **stock** `ld.so` of the pinned version as `<nativeLibraryDir>/libpmbld.so`
  (`pmbos/tools/loader`). The launcher starts
  `libpmbld.so --library-path <libdirs> --argv0 <argv0> <imagefs>/usr/bin/box64 <wine>/bin/wine ...`
  and exports `PMBOS_LOADER` / `PMBOS_LOADER_LIBPATH` / `PMBOS_ROOTFS` (below); from then on the
  imagefs libc (`glibc-2.36-pmbos-execve.patch`) rewrites every exec of a glibc program into the
  same form. Version coupling: the stock ld.so runs the rebuilt `libc.so.6`, so both are the same
  Debian version (`GLIBC_DEBIAN_VERSION` = `loader/VERSION`; the patches change no rtld code and no
  struct layout). Stage glibc tests exactly that combination; stage verify starts box64 and the
  imagefs `/bin/sh` that way.

Redirect rules (details: the header of `patches/glibc-2.36-pmbos-execve.patch` and of
`pmbos-execve.h` in it):
* Variables come from the `envp` passed to `execve` when non-empty there, else from the calling
  process; ignored in AT_SECURE processes. `PMBOS_LOADER` must be absolute.
  `PMBOS_LOADER_LIBPATH` **replaces** `LD_LIBRARY_PATH` for the redirected program's loader (ld.so
  semantics of `--library-path`): give it the full list (e.g. the same value as `LD_LIBRARY_PATH`),
  or leave it empty/unset to make ld.so use `LD_LIBRARY_PATH`.
* Redirected = ELF of the libc's machine (aarch64), `ET_EXEC`/`ET_DYN`, `PT_INTERP` basename
  starting with `ld-linux` (classification by content, not by path). Not redirected (plain
  syscall): static programs, other loaders (`/system/bin/linker64`), other machines/formats,
  non-regular/unreadable/missing files, files without execute permission (ld.so would not
  check it; the kernel then says EACCES).
* `#!` scripts: parsed like Linux (256 bytes, interpreter + one optional argument); an absolute
  interpreter that does not exist becomes `$PMBOS_ROOTFS<interp>` (`#!/bin/sh`, `#!/usr/bin/env`);
  the interpreter is then handled like a target with `[interp, optarg, script, args...]` (its
  argv[0] is the path actually used). Scripts are always resolved in libc: SELinux checks the
  script file itself, so even `#!/system/bin/sh` scripts in app data need it. Max 4 nested
  scripts (ELOOP).
* `ENOEXEC` instead of SELinux's `EACCES` for executable regular files in no known format
  (keeps execvp's `/bin/sh` fallback); `E2BIG` before allocating when the kernel's pointer limit
  would be exceeded; async-signal-/vfork-safe (posix_spawn).
* Not covered: `execveat()`/`fexecve()` (direct execveat syscall), raw `syscall(SYS_execve)`,
  static binaries in app data (cannot run in LOADER mode at all), and `/proc/self/exe` of a
  redirected process (= `libpmbld.so`; argv and `AT_EXECFN` are right). Only arm64-v8a has a
  loader.

## App-side contract (PMB OS Windows launcher)

The imagefs glibc has no chroot: it finds its configuration through one environment variable
and a few files the app maintains.

* **`PMBOS_ROOTFS=<absolute imagefs path, no trailing slash>`** in the environment of **every**
  process the launcher spawns (in addition to `PMBOS_TMPDIR`/`PMBOS_SHM_DIR`). libc then reads
  `$PMBOS_ROOTFS/etc/resolv.conf`, `.../etc/hosts`, `.../etc/nsswitch.conf`, `.../etc/services`,
  `.../etc/protocols`, `.../etc/passwd`, `.../etc/group`, `.../etc/host.conf`, `.../etc/gai.conf`,
  `.../etc/localtime`, `.../usr/share/zoneinfo/<TZ>` and runs `$PMBOS_ROOTFS/bin/sh` for
  `system()`/`popen()`/`wordexp()`. Unset -> stock glibc paths (which do not exist on Android).
  No fallback to the absolute path while it is set.
* **`<imagefs>/etc/resolv.conf`** is written by the app **before each launch** (write a temp file
  in `etc/`, then rename): one `nameserver <addr>` line per DNS server of the active network
  (`ConnectivityManager.getLinkProperties(getActiveNetwork()).getDnsServers()`, API 23+;
  IPv6 link-local servers as `fe80::...%<iface>` with `LinkProperties.getInterfaceName()`), a
  `search` line from `getDomains()` if non-empty, and `options timeout:2 attempts:2`. glibc
  re-reads the file when it changes. The shipped file (1.1.1.1, 8.8.8.8) is only the fallback when
  no network/DNS information is available.
* **`<imagefs>/etc/passwd` and `<imagefs>/etc/group`** are written by the app before each launch
  from the shipped templates `etc/passwd.in` / `etc/group.in`, replacing `@PMBOS_UID@` with
  `android.os.Process.myUid()` and `@PMBOS_GID@` with the app's gid (same value). The shipped
  `passwd`/`group` only contain root/nobody, so without this step `getpwuid(getuid())` fails
  (wine then relies on `HOME`/`USER`). `@ROOTFS@` in the templates is already substituted at
  install time (`textPatch`).
* **`TZ=<IANA zone id>`** (`java.util.TimeZone.getDefault().getID()`, e.g. `Europe/Berlin`) is
  recommended: resolved in `<imagefs>/usr/share/zoneinfo`; `etc/localtime` -> `Etc/UTC` otherwise.
* **LOADER mode only** (targetSdk >= 29), in the environment of every process:
  `PMBOS_LOADER=<ApplicationInfo.nativeLibraryDir>/libpmbld.so` (absolute; native libraries must
  be extracted on install), `PMBOS_LOADER_LIBPATH=<colon list of library dirs>` (same value as
  `LD_LIBRARY_PATH`, see "Exec modes"), and `PMBOS_ROOTFS` as above. Start the first process as
  `libpmbld.so --library-path <PMBOS_LOADER_LIBPATH> --argv0 <imagefs>/usr/bin/box64
  <imagefs>/usr/bin/box64 <args>` (box64 re-execs itself through its argv[0], which the
  redirect handles). Unset `PMBOS_LOADER` in DIRECT mode.

## Testing the execve redirect without Docker

```bash
bash tests/execve-redirect-hosttest.sh                       # any host C compiler (also MinGW)
bash tests/execve-redirect-hosttest.sh --clang "$NDK/toolchains/llvm/prebuilt/<host>/bin/clang" \
    --glibc-sysroot <extracted Debian arm64 libc6-dev + linux-libc-dev> \
    --elf loader:<some glibc program> --elf plain:pmbos/src/main/jniLibs/arm64-v8a/libpmbld.so
```

It extracts `pmbos-execve.h` and `execve.c` from the patch, so it tests exactly the patched code:
the unit test (`src/glibc-execve-hosttest.c`: argv rewriting, `#!` parsing, PMBOS_ROOTFS mapping,
ENOEXEC/E2BIG/ELOOP, fd leaks, against a fake file system and an Android kernel model), an
aarch64-linux-android24 compile, a type check of the glibc glue against Debian's headers, and the
classifier on real binaries. Stage glibc runs it too, plus the real integration test.

## Updating versions

1. Change the version + URL + SHA-256 in `versions.env` (`sha256sum <file>` of the upstream
   artifact; for box64 the commit id of the tag).
2. Wine: a new major version needs `patches/wine-<major>-pmbos-tmpdir.patch`; add
   `WINE_URL_<v>`, `WINE_SHA256_<v>`, `WINE_MONO_<v>` (from `dlls/mscoree/mscoree_private.h`) and
   the matching `WINE_MONO_URL_*`/`WINE_MONO_SHA256_*`.
3. box64: rename/rebase `patches/box64-<ver>-pmbos-shm-plt.patch`.
4. Debian suite: `LIBXCB_VERSION` must equal the suite's libxcb1 upstream version (checked).
5. glibc is pinned to the APK's loader: bump `pmbos/tools/loader` first (`fetch-loader.sh`
   rewrites `loader/VERSION`), then set `GLIBC_DEBIAN_VERSION`, the source package hashes
   (`GLIBC_{DSC,ORIG,DEBIAN_TAR}_SHA256/_SHA1`: the `Checksums-Sha256` of the `.dsc`, `sha1sum`
   for the snapshot.debian.org fallback) and `LIBC6_DEB_SHA256/_SHA1`, `LOADER_SHA256` (= the
   `deb_*`/`loader_sha256` values of `loader/VERSION`). `build-all.sh` dies on any difference.
   A new upstream release (e.g. trixie's 2.41) needs rebased
   `patches/glibc-<upstream>-pmbos-{rootfs,execve}.patch` (the stage refuses to build without
   them). The rootfs stage warns when the suite's current `libc6` is newer than the pin (all
   libc6 files are replaced by the pinned rebuild).
6. Bump `PACKSET_VERSION` when the imagefs content changes.

## Files

```
build-all.sh            host orchestrator (docker)
versions.env            every pinned input
lib/common.sh           shell helpers (host + containers)
lib/packtool.py         ELF/PT_INTERP, manifests, deterministic tar.xz, index, reference installer
stages/stage-*.sh       one script per stage, run inside the containers
docker/Dockerfile.*     build environments (tools = host arch, arm64, amd64)
patches/*.patch         upstream patches (documented)
src/pmbshm.c            libpmbshm.so: SysV shm emulation (LD_PRELOAD)
src/pmbshm-test.c       its contract self-test (run at build and verify time)
src/glibc-rootfs-test.c self-test of the PMBOS_ROOTFS glibc (stage glibc) + imagefs smoke test (verify)
src/glibc-execve-test.c integration test of the PMBOS_LOADER execve redirect (stage glibc, both loaders)
src/glibc-execve-hosttest.c  unit test of the redirect logic (fake file system, Android kernel model)
tests/execve-redirect-hosttest.sh  runs it on any host (extracts the code from the patch)
github/                 GitHub Actions: workflows/build-packs.yml, ci.sh (job helpers), export.sh (copy to the
                        public packs repo), README.md (owner guide, Russian), REPO_README.md
files/rootfs/etc/       /etc templates (fonts.conf with @ROOTFS@, passwd(.in), group(.in), hosts,
                        nsswitch.conf, resolv.conf fallback, host.conf)
```
