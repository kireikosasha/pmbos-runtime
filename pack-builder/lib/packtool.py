#!/usr/bin/env python3
"""
packtool.py - post-processing for PMB OS runtime packs (pure Python 3.9+, stdlib only;
needs GNU tar, xz and patchelf on PATH for the commands that use them).

Commands
  packdef         declare a staged pack ($STAGE/<id>/ + $STAGE/<id>.pack.json)
  normalize-rootfs  merged-/usr layout, real <root>/lib/ld-linux-aarch64.so.1, relative symlinks
  relativize      rewrite absolute symlinks to relative ones (inside the tree)
  check-needed    every DT_NEEDED of every arm64 ELF must resolve inside imagefs + pack
  finalize        relativize + check-needed + PT_INTERP padding + pmbpack.json + tar.xz
  index           write index.json (+ SHA256SUMS) for all packs in the dist dir
  install         reference installer: exactly what the on-device runtime does
  set-interp      rewrite PT_INTERP of one ELF in place (what the runtime ELF patcher does)
  placeholder     print the PT_INTERP placeholder for a given length

Pack archive contract (consumed by kireiko.dev.pmb.os.runtime):
  * tar (ustar; POSIX pax extended headers only if a path does not fit ustar) + xz.
  * first member is pmbpack.json; only regular files and directories follow (no symlinks,
    no hard links, no device nodes). Empty directories contain a zero-byte ".pmbkeep".
  * pmbpack.json lists symlinks to create, files to chmod +x, ELF files whose PT_INTERP holds
    the placeholder and text files containing the @ROOTFS@ token.
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse

ROOTFS_TOKEN = b"@ROOTFS@"
LD_NAME = "ld-linux-aarch64.so.1"
TRIPLET = "aarch64-linux-gnu"
PLACEHOLDER_HEAD = "/@PMBOS_ROOTFS@"
PLACEHOLDER_TAIL = "/lib/" + LD_NAME
KEEP_FILE = ".pmbkeep"
TEXT_SCAN_LIMIT = 8 * 1024 * 1024
TYPE_ORDER = ["rootfs", "box64", "wine", "vulkan-driver", "sw-driver", "dxvk", "vkd3d", "misc"]

EM_X86_64 = 62
EM_AARCH64 = 183
PT_LOAD, PT_DYNAMIC, PT_INTERP = 1, 2, 3
DT_NULL, DT_NEEDED, DT_STRTAB, DT_STRSZ, DT_SONAME, DT_RPATH, DT_RUNPATH = 0, 1, 5, 10, 14, 15, 29


def log(msg):
    print("[packtool] " + msg, file=sys.stderr, flush=True)


def die(msg):
    print("[packtool] ERROR: " + msg, file=sys.stderr, flush=True)
    sys.exit(1)


# ------------------------------------------------------------------------------------------
# ELF
# ------------------------------------------------------------------------------------------
class Elf:
    """Minimal ELF64 little-endian reader (aarch64 / x86_64)."""

    def __init__(self, path):
        self.path = path
        self.machine = None
        self.etype = None
        self.phdrs = []  # (type, offset, vaddr, filesz)
        self.interp = None
        self.interp_off = None
        self.interp_size = None
        self.needed = []
        self.runpath = []
        self.soname = None
        with open(path, "rb") as f:
            hdr = f.read(64)
            if len(hdr) < 64 or hdr[:4] != b"\x7fELF":
                raise ValueError("not ELF")
            if hdr[4] != 2 or hdr[5] != 1:
                # 32-bit or big endian: we only care about the class/machine for filtering
                self.machine = struct.unpack_from("<H", hdr, 18)[0] if hdr[5] == 1 else None
                self.etype = struct.unpack_from("<H", hdr, 16)[0] if hdr[5] == 1 else None
                self.is64 = False
                return
            self.is64 = True
            self.etype, self.machine = struct.unpack_from("<HH", hdr, 16)
            phoff = struct.unpack_from("<Q", hdr, 32)[0]
            phentsize, phnum = struct.unpack_from("<HH", hdr, 54)
            if phnum == 0 or phentsize < 56:
                return
            f.seek(phoff)
            raw = f.read(phentsize * phnum)
            dyn = None
            for i in range(phnum):
                p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from(
                    "<IIQQQQ", raw, i * phentsize)
                self.phdrs.append((p_type, p_offset, p_vaddr, p_filesz))
                if p_type == PT_INTERP:
                    f.seek(p_offset)
                    data = f.read(p_filesz)
                    self.interp_off, self.interp_size = p_offset, p_filesz
                    self.interp = data.split(b"\0", 1)[0].decode("utf-8", "replace")
                elif p_type == PT_DYNAMIC:
                    dyn = (p_offset, p_filesz)
            if dyn:
                self._read_dynamic(f, *dyn)

    def _vaddr_to_off(self, vaddr):
        for p_type, off, va, sz in self.phdrs:
            if p_type == PT_LOAD and va <= vaddr < va + sz:
                return vaddr - va + off
        return None

    def _read_dynamic(self, f, off, size):
        f.seek(off)
        raw = f.read(size)
        entries = []
        for i in range(0, len(raw) - 15, 16):
            tag, val = struct.unpack_from("<qQ", raw, i)
            if tag == DT_NULL:
                break
            entries.append((tag, val))
        strtab = next((v for t, v in entries if t == DT_STRTAB), None)
        strsz = next((v for t, v in entries if t == DT_STRSZ), None)
        if strtab is None or strsz is None:
            return
        soff = self._vaddr_to_off(strtab)
        if soff is None:
            return
        f.seek(soff)
        table = f.read(strsz)

        def s(i):
            return table[i:table.index(b"\0", i)].decode("utf-8", "replace") if i < len(table) else ""

        for t, v in entries:
            if t == DT_NEEDED:
                self.needed.append(s(v))
            elif t in (DT_RUNPATH, DT_RPATH):
                self.runpath.extend(x for x in s(v).split(":") if x)
            elif t == DT_SONAME:
                self.soname = s(v)


def try_elf(path):
    try:
        return Elf(path)
    except (ValueError, OSError, struct.error, IndexError):
        return None


def is_shared_lib_name(name):
    return name.endswith(".so") or ".so." in name


def placeholder(length):
    pad = length - len(PLACEHOLDER_HEAD) - len(PLACEHOLDER_TAIL)
    if pad < 16:
        die("placeholder length %d too small" % length)
    return PLACEHOLDER_HEAD + "_" * pad + PLACEHOLDER_TAIL


def set_interp_inplace(path, new_interp):
    """Overwrites PT_INTERP in place (NUL padded). Mirrors the runtime ELF patcher."""
    elf = Elf(path)
    if elf.interp_off is None:
        raise ValueError("%s has no PT_INTERP" % path)
    data = new_interp.encode("utf-8")
    if len(data) + 1 > elf.interp_size:
        raise ValueError("%s: interpreter path of %d bytes does not fit PT_INTERP of %d bytes"
                         % (path, len(data), elf.interp_size))
    with open(path, "r+b") as f:
        f.seek(elf.interp_off)
        f.write(data + b"\0" * (elf.interp_size - len(data)))


# ------------------------------------------------------------------------------------------
# Tree helpers
# ------------------------------------------------------------------------------------------
def walk(root):
    """Yields (relpath, abspath, lstat) for every entry below root (no symlink following)."""
    for d, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        for n in sorted(dirs + files):
            p = os.path.join(d, n)
            yield os.path.relpath(p, root).replace(os.sep, "/"), p, os.lstat(p)


def inside(root, path):
    root = os.path.realpath(root)
    path = os.path.normpath(path)
    return path == root or path.startswith(root + os.sep)


def chroot_resolve(root, abs_path, depth=0):
    """Resolves the directory part of abs_path (interpreted inside root, like a chroot)
    through symlinks; the last component is kept as is. Returns a host path inside root."""
    if depth > 40:
        die("symlink loop while resolving %s" % abs_path)
    parts = [x for x in abs_path.split("/") if x and x != "."]
    cur = root
    for i, comp in enumerate(parts[:-1]):
        if comp == "..":
            cur = os.path.dirname(cur) if cur != root else root
            continue
        nxt = os.path.join(cur, comp)
        if os.path.islink(nxt):
            t = os.readlink(nxt)
            if t.startswith("/"):
                base = t
            else:
                base = "/" + os.path.relpath(os.path.normpath(os.path.join(cur, t)), root)
            rest = "/".join(parts[i + 1:])
            return chroot_resolve(root, base.rstrip("/") + "/" + rest, depth + 1)
        cur = nxt
    return os.path.join(cur, parts[-1]) if parts else root


def relativize(root, prune_dangling=False):
    root = os.path.realpath(root)
    fixed = pruned = 0
    for rel, p, st in list(walk(root)):
        if not stat.S_ISLNK(st.st_mode):
            continue
        target = os.readlink(p)
        parent = os.path.dirname(p)
        if target.startswith("/"):
            dest = os.path.normpath(chroot_resolve(root, target))
            newt = os.path.relpath(dest, parent)
            os.unlink(p)
            os.symlink(newt, p)
            target = newt
            fixed += 1
        lexical = os.path.normpath(os.path.join(parent, target))
        if not inside(root, lexical):
            if prune_dangling:
                log("prune escaping symlink %s -> %s" % (rel, target))
                os.unlink(p)
                pruned += 1
                continue
            die("symlink escapes the pack root: %s -> %s" % (rel, target))
        if prune_dangling and not os.path.exists(p):
            log("prune dangling symlink %s -> %s" % (rel, target))
            os.unlink(p)
            pruned += 1
    log("relativize %s: %d absolute symlinks rewritten, %d pruned" % (root, fixed, pruned))


def retarget_relative_links(tree, old_base, new_base):
    """After moving `tree` from old_base to new_base, keeps relative symlinks pointing at the
    same (lexical) location they designated before the move."""
    entries = [(tree, os.lstat(tree))] if os.path.islink(tree) else \
        [(p, st) for _rel, p, st in walk(tree)]
    for p, st in entries:
        if not stat.S_ISLNK(st.st_mode):
            continue
        target = os.readlink(p)
        if target.startswith("/"):
            continue  # absolute links are location independent
        new_parent = os.path.dirname(p)
        old_parent = old_base + new_parent[len(new_base):]
        dest = os.path.normpath(os.path.join(old_parent, target))
        if dest == old_base or dest.startswith(old_base + os.sep):
            dest = new_base + dest[len(old_base):]  # pointed into the moved tree itself
        newt = os.path.relpath(dest, new_parent)
        if newt != target:
            os.unlink(p)
            os.symlink(newt, p)


def move_merge(src, dst, old_base=None, new_base=None):
    """Moves tree src into dst, merging directories; keeps dst's entry on conflicts."""
    if old_base is None:
        old_base, new_base = src, dst
    if not os.path.lexists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.rename(src, dst)
        retarget_relative_links(dst, old_base, new_base)
        return
    if os.path.isdir(src) and not os.path.islink(src) and os.path.isdir(dst) and not os.path.islink(dst):
        for n in os.listdir(src):
            move_merge(os.path.join(src, n), os.path.join(dst, n), old_base, new_base)
        os.rmdir(src)
        return
    log("merge conflict, keeping /usr version: %s" % dst)
    if os.path.isdir(src) and not os.path.islink(src):
        shutil.rmtree(src)
    else:
        os.unlink(src)


def cmd_normalize_rootfs(a):
    root = os.path.realpath(a.root)
    # merged /usr first: absolute symlinks are location independent, relative ones are
    # re-targeted while moving; only then make everything relative.
    for d in ("bin", "sbin", "lib", "lib64"):
        top = os.path.join(root, d)
        if os.path.islink(top) or not os.path.lexists(top):
            continue
        move_merge(top, os.path.join(root, "usr", d))
        os.symlink("usr/" + d, top)
    relativize(root)
    # real loader at <root>/lib/ld-linux-aarch64.so.1
    cand = [os.path.join(root, "usr/lib", TRIPLET, LD_NAME), os.path.join(root, "usr/lib", LD_NAME)]
    real = None
    for c in cand:
        if os.path.exists(c):
            real = os.path.realpath(c)
            break
    if not real or not inside(root, real):
        die("dynamic loader %s not found in rootfs" % LD_NAME)
    elf = Elf(real)
    if elf.machine != EM_AARCH64:
        die("%s is not an aarch64 ELF" % real)
    tmp = os.path.join(root, ".ld.tmp")
    shutil.copy2(real, tmp)
    libdir = os.path.join(root, "lib")
    if os.path.islink(libdir):
        os.unlink(libdir)
    os.makedirs(libdir, exist_ok=True)
    final = os.path.join(libdir, LD_NAME)
    os.replace(tmp, final)
    os.chmod(final, 0o755)
    links = {
        os.path.join(libdir, TRIPLET): "../usr/lib/" + TRIPLET,
        os.path.join(root, "usr/lib", TRIPLET, LD_NAME): "../../../lib/" + LD_NAME,
        os.path.join(root, "usr/lib", LD_NAME): "../../lib/" + LD_NAME,
    }
    if os.path.lexists(real) and real != final:
        os.unlink(real)
    for link, target in links.items():
        if os.path.lexists(link):
            if os.path.isdir(link) and not os.path.islink(link):
                die("unexpected directory at %s" % link)
            os.unlink(link)
        os.makedirs(os.path.dirname(link), exist_ok=True)
        os.symlink(target, link)
    if not os.path.isfile(os.path.join(root, "usr/lib", TRIPLET, "libc.so.6")):
        die("libc.so.6 missing after normalization")
    log("rootfs normalized: real loader at lib/%s" % LD_NAME)


def cmd_relativize(a):
    relativize(a.root, a.prune_dangling)


# ------------------------------------------------------------------------------------------
# check-needed
# ------------------------------------------------------------------------------------------
def check_needed(rootfs, pack, extra_dirs, ignore):
    rootfs = os.path.realpath(rootfs)
    pack = os.path.realpath(pack)
    base_dirs = [os.path.join(rootfs, d) for d in
                 ("usr/lib/" + TRIPLET, "usr/lib", "lib/" + TRIPLET, "lib")]
    pack_dirs = set(os.path.join(pack, d) for d in extra_dirs)
    elfs = []
    for rel, p, st in walk(pack):
        if not stat.S_ISREG(st.st_mode) or st.st_size < 64:
            continue
        e = try_elf(p)
        if e is None or e.machine != EM_AARCH64 or not e.is64:
            continue
        elfs.append((rel, p, e))
        if is_shared_lib_name(os.path.basename(p)):
            pack_dirs.add(os.path.dirname(p))
    missing = []
    for rel, p, e in elfs:
        dirs = []
        for rp in e.runpath:
            rp = rp.replace("$ORIGIN", os.path.dirname(p)).replace("${ORIGIN}", os.path.dirname(p))
            if rp.startswith("/"):
                rp = os.path.join(rootfs, rp.lstrip("/"))
            dirs.append(rp)
        dirs += sorted(pack_dirs) + base_dirs
        for n in e.needed:
            if n in ignore:
                continue
            if not any(os.path.exists(os.path.join(d, n)) for d in dirs):
                missing.append("%s: %s" % (rel, n))
    if missing:
        die("unresolved DT_NEEDED entries (add the providing Debian package to ROOTFS_PACKAGES):\n  "
            + "\n  ".join(missing))
    log("check-needed %s: %d arm64 ELF objects OK" % (pack, len(elfs)))


def cmd_check_needed(a):
    check_needed(a.rootfs, a.pack, a.libdir or [], set(a.ignore or []))


# ------------------------------------------------------------------------------------------
# packdef / finalize
# ------------------------------------------------------------------------------------------
def cmd_packdef(a):
    d = {
        "id": a.id,
        "version": a.version,
        "type": a.type,
        "installDir": a.install_dir,
        "requires": [x for x in a.requires.split(",") if x],
        "recommended": a.recommended == "1",
        "arm64": a.arm64 == "1",
        "description": a.description,
    }
    if a.type not in TYPE_ORDER:
        die("unknown pack type %s" % a.type)
    root = os.path.join(a.stage, a.id)
    if not os.path.isdir(root):
        die("staged tree missing: %s" % root)
    with open(os.path.join(a.stage, a.id + ".pack.json"), "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
        f.write("\n")
    log("declared pack %s %s (%s)" % (a.id, a.version, a.type))


def patch_interp(root, ph):
    patched = []
    for rel, p, st in walk(root):
        if not stat.S_ISREG(st.st_mode) or st.st_size < 64:
            continue
        e = try_elf(p)
        if e is None or e.machine != EM_AARCH64 or not e.is64 or e.interp is None:
            continue
        if is_shared_lib_name(os.path.basename(p)):
            # PT_INTERP of a shared object is only used when it is executed directly
            # (e.g. libc.so.6 printing its version); the loader ignores it otherwise.
            continue
        if e.interp != ph:
            mode = st.st_mode
            subprocess.run(["patchelf", "--set-interpreter", ph, p], check=True)
            os.chmod(p, stat.S_IMODE(mode))
            e2 = Elf(p)
            if e2.interp != ph or e2.interp_size < len(ph) + 1:
                die("patchelf did not set the interpreter of %s" % rel)
        patched.append(rel)
    return patched


def break_hardlinks_and_specials(root):
    for rel, p, st in list(walk(root)):
        if stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
            tmp = p + ".pmbtmp"
            shutil.copy2(p, tmp)
            os.replace(tmp, p)
        elif not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)):
            log("removing special file %s" % rel)
            os.unlink(p)


def build_manifest(root, d, ph, patched):
    symlinks, executables, text_patch = [], [], []
    files = 0
    size = 0
    for rel, p, st in walk(root):
        if rel == "pmbpack.json":
            continue
        if stat.S_ISLNK(st.st_mode):
            symlinks.append([os.readlink(p), rel])
        elif stat.S_ISREG(st.st_mode):
            files += 1
            size += st.st_size
            if st.st_mode & 0o111:
                executables.append(rel)
            if st.st_size <= TEXT_SCAN_LIMIT:
                with open(p, "rb") as f:
                    data = f.read()
                if ROOTFS_TOKEN in data:
                    if b"\0" in data:
                        die("binary file contains the %s token: %s" % (ROOTFS_TOKEN.decode(), rel))
                    text_patch.append(rel)
    # remove symlinks from the tree; the runtime recreates them from the manifest
    for _target, rel in symlinks:
        os.unlink(os.path.join(root, rel))
    # keep empty directories visible to extractors that only create parents of files
    for dpath, dirs, fls in os.walk(root, topdown=False):
        if not os.listdir(dpath) and dpath != root:
            open(os.path.join(dpath, KEEP_FILE), "wb").close()
    symlinks.sort(key=lambda x: x[1])
    return {
        "format": 1,
        "id": d["id"],
        "version": d["version"],
        "type": d["type"],
        "installDir": d["installDir"],
        "requires": d["requires"],
        "description": d["description"],
        "interpPlaceholder": ph,
        "patchInterp": sorted(patched),
        "textPatch": sorted(text_patch),
        "symlinks": symlinks,
        "executables": sorted(executables),
        "files": files,
        "installedSize": size,
    }


def ustar_ok(name):
    b = name.encode("utf-8")
    if len(b) <= 100:
        return True
    if len(b) > 255:
        return False
    for i in range(len(b) - 1, -1, -1):
        if b[i:i + 1] == b"/" and i <= 155 and len(b) - i - 1 <= 100:
            return True
    return False


def make_archive(root, out, mtime, xz_opts):
    names = ["pmbpack.json"]
    for rel, p, st in walk(root):
        if rel == "pmbpack.json":
            continue
        if stat.S_ISLNK(st.st_mode):
            die("symlink left in tree: %s" % rel)
        names.append(rel + "/" if stat.S_ISDIR(st.st_mode) else rel)
    fmt = "ustar" if all(ustar_ok(n) for n in names) else "pax"
    if fmt == "pax":
        log("note: some paths do not fit ustar, using POSIX pax extended headers")
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".list", encoding="utf-8",
                                     newline="\n") as lf:
        for n in names:
            lf.write(n.rstrip("/") + "\n")
        listfile = lf.name
    tmp_out = out + ".part"
    tar_cmd = ["tar", "--create", "--file=-", "--format=" + fmt, "--no-recursion",
               "--numeric-owner", "--owner=0", "--group=0", "--mtime=@%d" % mtime,
               "--mode=u+rw,go-w", "--hard-dereference", "-C", root,
               "--verbatim-files-from", "-T", listfile]
    if fmt == "pax":
        tar_cmd.insert(3, "--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime")
    try:
        with open(tmp_out, "wb") as fo:
            p1 = subprocess.Popen(tar_cmd, stdout=subprocess.PIPE)
            p2 = subprocess.Popen(["xz", "-c"] + xz_opts.split(), stdin=p1.stdout, stdout=fo)
            p1.stdout.close()
            r2 = p2.wait()
            r1 = p1.wait()
        if r1 != 0 or r2 != 0:
            die("archiving failed (tar=%d xz=%d)" % (r1, r2))
        os.replace(tmp_out, out)
    finally:
        os.unlink(listfile)
        if os.path.exists(tmp_out):
            os.unlink(tmp_out)
    return fmt


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_finalize(a):
    with open(a.packdef) as f:
        d = json.load(f)
    root = os.path.realpath(a.root)
    ph = placeholder(a.placeholder_len)
    is_rootfs = d["type"] == "rootfs"
    relativize(root, prune_dangling=is_rootfs)
    if d["arm64"]:
        check_needed(a.rootfs if not is_rootfs else root, root, a.libdir or [], set())
    break_hardlinks_and_specials(root)
    patched = patch_interp(root, ph) if d["arm64"] else []
    man = build_manifest(root, d, ph, patched)
    with open(os.path.join(root, "pmbpack.json"), "w") as f:
        json.dump(man, f, indent=1, sort_keys=False)
        f.write("\n")
    os.makedirs(a.dist, exist_ok=True)
    fname = "%s-%s.tar.xz" % (d["id"], d["version"])
    if d["id"].endswith("-" + d["version"]):
        fname = "%s.tar.xz" % d["id"]
    out = os.path.join(a.dist, fname)
    fmt = make_archive(root, out, a.mtime, a.xz_opts)
    meta = {
        "id": d["id"],
        "version": d["version"],
        "type": d["type"],
        "file": fname,
        "sha256": sha256_file(out),
        "size": os.path.getsize(out),
        "installedSize": man["installedSize"],
        "archive": "tar.xz",
        "installDir": d["installDir"],
        "requires": d["requires"],
        "recommended": d["recommended"],
        "description": d["description"],
    }
    if d["arm64"]:
        # explicit for every native pack; the app defaults only rootfs/box64/vulkan-driver to arm64-v8a
        meta["abi"] = ["arm64-v8a"]
    os.makedirs(os.path.join(a.dist, "meta"), exist_ok=True)
    with open(os.path.join(a.dist, "meta", d["id"] + ".json"), "w") as f:
        json.dump(meta, f, indent=2, sort_keys=True)
        f.write("\n")
    log("packed %s (%s, %d files, %d symlinks, %d interp-patched, %d text-patched, %.1f MiB)"
        % (fname, fmt, man["files"], len(man["symlinks"]), len(patched), len(man["textPatch"]),
           meta["size"] / 1048576.0))


# ------------------------------------------------------------------------------------------
# index
# ------------------------------------------------------------------------------------------
def cmd_index(a):
    metas = []
    mdir = os.path.join(a.dist, "meta")
    for n in sorted(os.listdir(mdir)) if os.path.isdir(mdir) else []:
        if n.endswith(".json"):
            with open(os.path.join(mdir, n)) as f:
                m = json.load(f)
            path = os.path.join(a.dist, m["file"])
            if not os.path.isfile(path):
                die("archive missing for %s: %s" % (m["id"], path))
            if sha256_file(path) != m["sha256"]:
                die("archive changed after packing: %s" % path)
            metas.append(m)
    if not metas:
        die("no packs found in %s" % mdir)
    ids = set(m["id"] for m in metas)
    for m in metas:
        for r in m["requires"]:
            if r not in ids:
                die("%s requires %s which is not part of this repo" % (m["id"], r))
    metas.sort(key=lambda m: (TYPE_ORDER.index(m["type"]), m["id"]))
    base = a.base_url.rstrip("/")
    comps = []
    for m in metas:
        url = urllib.parse.quote(m["file"])
        if base:
            url = base + "/" + url
        comps.append({
            "id": m["id"],
            "version": m["version"],
            "type": m["type"],
            "url": url,
            "sha256": m["sha256"],
            "size": m["size"],
            "installedSize": m["installedSize"],
            "archive": m["archive"],
            "installDir": m["installDir"],
            "requires": m["requires"],
            "recommended": m["recommended"],
            "description": m["description"],
        })
        if m.get("abi"):
            comps[-1]["abi"] = m["abi"]
    gen = datetime.datetime.fromtimestamp(a.mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    index = {"format": 1, "name": a.name, "packset": a.packset, "generated": gen, "components": comps}
    with open(a.out, "w") as f:
        json.dump(index, f, indent=2)
        f.write("\n")
    with open(os.path.join(a.dist, "SHA256SUMS"), "w") as f:
        for m in metas:
            f.write("%s  %s\n" % (m["sha256"], m["file"]))
    log("index: %d components -> %s" % (len(comps), a.out))


# ------------------------------------------------------------------------------------------
# reference installer
# ------------------------------------------------------------------------------------------
def safe_join(base, rel):
    p = os.path.normpath(os.path.join(base, rel))
    if not inside(base, p):
        die("path escapes install dir: %s" % rel)
    return p


def expand(dest, patterns):
    out = []
    allfiles = None
    for pat in patterns:
        if any(c in pat for c in "*?["):
            if allfiles is None:
                allfiles = [rel for rel, p, st in walk(dest) if stat.S_ISREG(st.st_mode)]
            out.extend(r for r in allfiles if fnmatch.fnmatchcase(r, pat))
        else:
            out.append(pat)
    return out


def cmd_install(a):
    runtime = os.path.realpath(a.runtime)
    rootfs = os.path.join(runtime, "imagefs")
    with tarfile.open(a.archive, "r:xz") as tf:
        first = tf.next()
        if first is None or first.name != "pmbpack.json":
            die("first archive member must be pmbpack.json")
        man = json.load(tf.extractfile(first))
        dest = safe_join(runtime, man["installDir"])
        os.makedirs(dest, exist_ok=True)
        # several packs share installDir "imagefs": keep manifests out of the install dir
        mdir = os.path.join(runtime, "manifests")
        os.makedirs(mdir, exist_ok=True)
        with open(os.path.join(mdir, man["id"] + ".json"), "w") as f:
            json.dump(man, f, indent=1)
        for m in tf:
            if m.name == "pmbpack.json":
                continue
            p = safe_join(dest, m.name)
            if m.isdir():
                os.makedirs(p, exist_ok=True)
            elif m.isfile():
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with tf.extractfile(m) as src, open(p, "wb") as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)
                os.chmod(p, 0o644)
            else:
                die("unsupported member type in %s: %s" % (a.archive, m.name))
    for target, link in man["symlinks"]:
        lp = safe_join(dest, link)
        os.makedirs(os.path.dirname(lp), exist_ok=True)
        if os.path.lexists(lp):
            if os.path.isdir(lp) and not os.path.islink(lp):
                shutil.rmtree(lp)
            else:
                os.unlink(lp)
        os.symlink(target, lp)
    for rel in expand(dest, man["executables"]):
        os.chmod(safe_join(dest, rel), 0o755)
    interp = rootfs + "/lib/" + LD_NAME
    for rel in expand(dest, man["patchInterp"]):
        set_interp_inplace(safe_join(dest, rel), interp)
    for rel in expand(dest, man["textPatch"]):
        p = safe_join(dest, rel)
        with open(p, "rb") as f:
            data = f.read()
        with open(p, "wb") as f:
            f.write(data.replace(ROOTFS_TOKEN, rootfs.encode("utf-8")))
    log("installed %s %s into %s" % (man["id"], man["version"], dest))


def cmd_set_interp(a):
    set_interp_inplace(a.file, a.interp)


def cmd_placeholder(a):
    print(placeholder(a.len))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)

    p = sp.add_parser("packdef")
    p.add_argument("--stage", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--type", required=True)
    p.add_argument("--install-dir", required=True)
    p.add_argument("--requires", default="")
    p.add_argument("--recommended", default="0")
    p.add_argument("--arm64", default="0")
    p.add_argument("--description", default="")
    p.set_defaults(fn=cmd_packdef)

    p = sp.add_parser("normalize-rootfs")
    p.add_argument("root")
    p.set_defaults(fn=cmd_normalize_rootfs)

    p = sp.add_parser("relativize")
    p.add_argument("root")
    p.add_argument("--prune-dangling", action="store_true")
    p.set_defaults(fn=cmd_relativize)

    p = sp.add_parser("check-needed")
    p.add_argument("--rootfs", required=True)
    p.add_argument("--pack", required=True)
    p.add_argument("--libdir", action="append", help="extra lib dir relative to the pack root")
    p.add_argument("--ignore", action="append")
    p.set_defaults(fn=cmd_check_needed)

    p = sp.add_parser("finalize")
    p.add_argument("--packdef", required=True)
    p.add_argument("--root", required=True, help="writable copy of the staged tree")
    p.add_argument("--rootfs", required=True, help="staged imagefs tree (for check-needed)")
    p.add_argument("--dist", required=True)
    p.add_argument("--libdir", action="append")
    p.add_argument("--placeholder-len", type=int, default=255)
    p.add_argument("--mtime", type=int, required=True)
    p.add_argument("--xz-opts", default="-9e --threads=0 --check=crc32")
    p.set_defaults(fn=cmd_finalize)

    p = sp.add_parser("index")
    p.add_argument("--dist", required=True)
    p.add_argument("--base-url", default="")
    p.add_argument("--out", required=True)
    p.add_argument("--name", default="PMB OS runtime packs")
    p.add_argument("--packset", default="")
    p.add_argument("--mtime", type=int, required=True)
    p.set_defaults(fn=cmd_index)

    p = sp.add_parser("install")
    p.add_argument("--runtime", required=True, help="runtime dir (contains imagefs/, components/)")
    p.add_argument("archive")
    p.set_defaults(fn=cmd_install)

    p = sp.add_parser("set-interp")
    p.add_argument("file")
    p.add_argument("interp")
    p.set_defaults(fn=cmd_set_interp)

    p = sp.add_parser("placeholder")
    p.add_argument("--len", type=int, default=255)
    p.set_defaults(fn=cmd_placeholder)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
