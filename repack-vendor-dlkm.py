#!/usr/bin/env python3
"""Replace explicitly selected modules in a copy of an ext4 vendor_dlkm image."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile


SPARSE_MAGIC = b"\x3a\xff\x26\xed"
MODULE_PATH = re.compile(r"(?:/lib/modules)?(?:/[A-Za-z0-9_.+-]+)+\.ko\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, cwd=None, allow_no_exports=False):
    result = subprocess.run(args, cwd=cwd, env={**os.environ, "LC_ALL": "C"},
                            text=True, capture_output=True)
    if result.returncode and allow_no_exports and "No data available" in result.stderr:
        require(not result.stdout.strip(), "Unexpected data when kmod reported no exports")
        return ""
    require(not result.returncode, f"{args[0]} failed: {(result.stderr or result.stdout).strip()}")
    return result.stdout


def debug(image, command, *, work, write=False):
    # debugfs can exit zero on request errors. Check stderr as well as readback.
    result = subprocess.run(["debugfs", *(["-w"] if write else []), "-R", command, image],
                            cwd=work, env={**os.environ, "LC_ALL": "C"}, text=True, capture_output=True)
    errors = [line for line in result.stderr.splitlines() if line and not line.startswith("debugfs ")]
    require(not result.returncode and not errors,
            f"debugfs {command}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def file_path(path):
    path = path.resolve(strict=True)
    require(path.is_file(), f"Not a regular file: {path}")
    return path


def image_info(path):
    size = path.stat().st_size
    with path.open("rb") as f:
        if f.read(4) == SPARSE_MAGIC:
            return "sparse", False
        f.seek(1024)
        if f.read(4) == b"\xe2\xe1\xf5\xe0":
            return "erofs", False
        f.seek(1080)
        require(f.read(2) == b"\x53\xef", "Not an ext4 vendor_dlkm filesystem or Android sparse image")
        f.seek(-64, os.SEEK_END)
        return "ext4", f.read(4) == b"AVBf"


def fs_bytes(image, work):
    info = debug(image, "stats", work=work)
    items = [re.search(rf"^{key}:\s+(\d+)\s*$", info, re.M) for key in ("Block count", "Block size")]
    require(all(items), "Cannot determine ext4 filesystem size")
    length = int(items[0][1]) * int(items[1][1])
    require(0 < length <= image.stat().st_size, "Truncated ext4 filesystem")
    return length


def check_fs(image):
    run("e2fsck", "-f", "-n", image)


def list_modules(image, work):
    # Walk directory entries without extracting data or applying image ownership to host files.
    pending = ["/lib/modules"]
    seen = set()
    modules = []
    while pending:
        directory = pending.pop()
        for line in debug(image, f"ls -p {directory}", work=work).splitlines():
            if not line:
                continue
            entry = re.fullmatch(r"/(\d+)/([0-7]+)/\d+/\d+/([^/]+)/\d*/", line)
            require(entry, f"Unexpected directory entry in {directory}: {line}")
            number, mode, name = entry.groups()
            if name in (".", ".."):
                continue
            path = f"{directory}/{name}"
            if stat.S_ISDIR(int(mode, 8)):
                require(number not in seen and re.fullmatch(r"[A-Za-z0-9_.+-]+", name),
                        f"Unsupported directory entry: {path}")
                seen.add(number)
                pending.append(path)
            elif stat.S_ISREG(int(mode, 8)) and MODULE_PATH.fullmatch(path):
                modules.append(path)
    return sorted(modules)


def inode(image, target, work):
    info = debug(image, f"stat {target}", work=work)
    fields = re.search(r"Type: regular\s+Mode:\s+([0-7]+)\s+Flags:\s+(0x[\da-f]+)", info)
    ids = re.search(r"User:\s+(\d+)\s+Group:\s+(\d+)\s+Project:\s+(\d+)", info)
    require(fields and ids and re.search(r"Links:\s+1\b", info), f"Not a single-link regular module: {target}")
    require(int(fields[2], 16) in (0, 0x80000) and ids[3] == "0",
            f"Unsupported inode flags or project ID on {target}")
    entries = debug(image, f"ea_list {target}", work=work)
    attrs = {}
    for line in entries.splitlines():
        if not line.strip() or line.strip() == "Extended attributes:":
            continue
        m = re.match(r"\s+([\w.-]+)\s+\((\d+)\)", line, re.ASCII)
        require(m and m[1] not in attrs, f"Cannot read extended attributes of {target}: {line}")
        attrs[m[1]] = int(m[2])
    times = {}
    for field in ("atime", "mtime", "ctime", "crtime"):
        m = re.search(rf"^\s*{field}:\s+(0x[\da-f]+):(\w+)", info, re.M)
        if m:
            times[field] = (m[1], "0x" + m[2])
    return (fields[1], ids[1], ids[2], attrs, times)


def module_field(path, key):
    return run("modinfo", "-F", key, path).splitlines()


def symbols(path, flag):
    with path.open("rb") as f:
        require(f.read(4) == b"\x7fELF", f"Expected an uncompressed ELF module: {path}")
    text = run("modprobe", flag, path, allow_no_exports=(flag == "--show-exports"))
    result = {}
    for line in text.splitlines():
        columns = line.split()
        require(len(columns) == 2 and re.fullmatch(r"0x[0-9a-fA-F]+", columns[0]),
                f"Cannot parse module symbol version: {line}")
        require(columns[1] not in result, f"Duplicate symbol in {path}: {columns[1]}")
        result[columns[1]] = int(columns[0], 16)
    return result


def abi_manifest(files):
    result = {}
    for path in files:
        for line in file_path(path).read_text().splitlines():
            cols = line.split()
            require(not cols or (len(cols) >= 3 and re.fullmatch(r"0x[\da-fA-F]+", cols[0])),
                    f"Invalid Module.symvers line: {line}")
            if cols:
                crc = int(cols[0], 16)
                require(result.setdefault(cols[1], crc) == crc, f"Conflicting CRC for {cols[1]}")
    return result


def elf_identity(path):
    with path.open("rb") as f:
        head = f.read(20)
    require(len(head) == 20 and head[:4] == b"\x7fELF" and head[4] in (1, 2) and head[5] in (1, 2),
            f"Not an uncompressed ELF module: {path}")
    require(int.from_bytes(head[16:18], "little" if head[5] == 1 else "big") == 1,
            f"Not a relocatable ELF module: {path}")
    return head[4:7] + head[18:20]


def undefined_symbols(path):
    return {m[1] for line in run("readelf", "--wide", "--symbols", path).splitlines()
            if (m := re.search(r"\bUND\s+(\S+)", line))}


def compare(stock, new, manifest):
    require(elf_identity(stock) == elf_identity(new), "Module ELF class, byte order or architecture differs")
    for key in ("name", "vermagic", "depends", "alias", "softdep", "weakdep"):
        require(sorted(module_field(stock, key)) == sorted(module_field(new, key)), f"Module {key} differs")
    require(module_field(new, "name") and module_field(new, "vermagic"), "Module lacks name or vermagic")
    if module_field(stock, "signer"):
        for key in ("signer", "sig_key"):
            require(module_field(stock, key) == module_field(new, key), f"Module {key} differs from the signed input")
    old_crc = symbols(stock, "--show-modversions")
    new_crc = symbols(new, "--show-modversions")
    if "modversions" in " ".join(module_field(stock, "vermagic")).split():
        require(old_crc.get("module_layout") and new_crc.get("module_layout"), "Missing module_layout CRC")
    require(old_crc.items() <= new_crc.items(), "An existing import CRC changed or disappeared")
    require(symbols(stock, "--show-exports") == symbols(new, "--show-exports"), "Module exports or their CRCs differ")
    added = new_crc.keys() - old_crc.keys()
    require(all(manifest.get(s) == new_crc[s] for s in added),
            "New imports need matching --symvers CRCs: " + ", ".join(sorted(s for s in added if manifest.get(s) != new_crc[s])))
    unversioned = undefined_symbols(new) - undefined_symbols(stock) - new_crc.keys()
    require(not unversioned, "New unversioned imports cannot be verified: " + ", ".join(sorted(unversioned)))
    return len(old_crc), len(added)


def replace(image, target, module, work, manifest, strip):
    mode, uid, gid, attrs, times = inode(image, target, work)
    stock, to_write, readback = (work / n for n in ("stock.ko", "replacement.ko", "readback.ko"))
    debug(image, f"dump {target} stock.ko", work=work)
    require(stock.is_file() and stock.stat().st_size, f"Unable to read {target}")
    shutil.copyfile(module, to_write)
    if strip:
        require(not module_field(to_write, "signer"), "Strip a module before signing it, not afterward")
        run(strip, "--strip-debug", to_write)
    old_count, added_count = compare(stock, to_write, manifest)
    for i, (name, size) in enumerate(attrs.items()):
        debug(image, f"ea_get -f attr{i} {target} {name}", work=work)
        require((work / f"attr{i}").stat().st_size == size, f"Could not read xattr {name}")

    debug(image, f"rm {target}", work=work, write=True)
    debug(image, f"write replacement.ko {target}", work=work, write=True)
    regular_mode = f"0{stat.S_IFREG | int(mode, 8):o}"
    for field, value in (("mode", regular_mode), ("uid", uid), ("gid", gid)):
        debug(image, f"set_inode_field {target} {field} {value}", work=work, write=True)
    for i, name in enumerate(attrs):
        debug(image, f"ea_set -f attr{i} {target} {name}", work=work, write=True)
    for name, (seconds, extra) in times.items():
        debug(image, f"set_inode_field {target} {name} @{int(seconds, 16)}", work=work, write=True)
        debug(image, f"set_inode_field {target} {name}_extra {extra}", work=work, write=True)

    require(inode(image, target, work) == (mode, uid, gid, attrs, times), f"Inode metadata changed: {target}")
    for i, name in enumerate(attrs):
        debug(image, f"ea_get -f after{i} {target} {name}", work=work)
        require((work / f"attr{i}").read_bytes() == (work / f"after{i}").read_bytes(), f"Xattr changed: {name}")
    debug(image, f"dump {target} readback.ko", work=work)
    digest = sha(to_write)
    require(sha(readback) == digest, f"Module data differs after writing {target}; check ext4 free space")
    print(f"{target}: verified {old_count} existing and {added_count} additional import CRCs; sha256 {digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Raw ext4 or Android sparse ext4 image")
    parser.add_argument("--output", type=Path, help="New raw ext4 image (never overwritten)")
    parser.add_argument("--list", action="store_true", help="List existing .ko paths below /lib/modules")
    parser.add_argument("--replace", action="append", default=[], metavar="IMAGE_PATH=LOCAL_KO",
                        help="Replace an existing uncompressed .ko (repeatable); a basename means /lib/modules/NAME.ko")
    parser.add_argument("--symvers", type=Path, action="append", default=[], help="Trusted CRC table for new imports (repeatable)")
    parser.add_argument("--strip-debug", metavar="LLVM_STRIP", help="Strip debug sections from unsigned replacements")
    parser.add_argument("--for-resigning", action="store_true",
                        help="For AVB-bearing input, output only the raw filesystem; it must be signed again")
    args = parser.parse_args()
    if args.list and (args.output or args.replace or args.for_resigning or args.strip_debug or args.symvers):
        parser.error("--list only needs --input")
    if not args.list and (not args.output or not args.replace):
        parser.error("Specify --list or use --output with at least one --replace")
    try:
        source = file_path(args.input)
        output = args.output.absolute() if args.output else None
        if output:
            require(not os.path.lexists(output), f"Output exists: {output}")
            require(output.parent.is_dir(), f"Create the output directory first: {output.parent}")
        replacements = {}
        for value in args.replace:
            target, sep, local = value.partition("=")
            if "/" not in target:
                target = "/lib/modules/" + target
            elif not target.startswith("/"):
                target = "/" + target
            require(sep and local and MODULE_PATH.fullmatch(target) and target.startswith("/lib/modules/")
                    and not {".", ".."}.intersection(target.split("/")), f"Invalid .ko replacement: {value}")
            require(target not in replacements, f"Duplicate replacement: {target}")
            replacements[target] = file_path(Path(local))
        manifest = abi_manifest(args.symvers)
        strip = shutil.which(args.strip_debug) if args.strip_debug else None
        require(not args.strip_debug or strip, f"Cannot find strip tool: {args.strip_debug}")
        before = sha(source) if output else None
        with tempfile.TemporaryDirectory(prefix="vendor-dlkm-", dir=output.parent if output else None) as directory:
            work = Path(directory)
            image = work / "filesystem.img"
            fmt, avb = image_info(source)
            if fmt == "sparse":
                run("simg2img", source, image)
                fmt, avb = image_info(image)
            elif output and fmt == "ext4":
                shutil.copyfile(source, image)
            else:
                image = source
            require(fmt == "ext4", "EROFS images are not supported; use the device's Android image build tools")
            if args.list:
                check_fs(image)
                for path in list_modules(image, work):
                    print(path)
                return
            partition_bytes = image.stat().st_size
            length = fs_bytes(image, work)
            if avb:
                require(args.for_resigning, "AVB footer detected. Use --for-resigning only if you can re-sign the output")
                with image.open("r+b") as fd:
                    fd.truncate(length)
                print(f"AVB input: {partition_bytes} bytes; unsigned filesystem: {length} bytes. Re-sign before use.")
            else:
                require(partition_bytes == length, "Unrecognized data after ext4; use the device's Android image build tools")
            check_fs(image)
            for number, (target, module) in enumerate(replacements.items()):
                job = work / f"module{number}"
                job.mkdir()
                replace(image, target, module, job, manifest, strip)
            check_fs(image)
            require(image.stat().st_size == length and sha(source) == before, "Image geometry or source file changed")
            # Publish only a fully verified image, without a race that could overwrite --output.
            os.link(image, output)
            print(f"Output: {output}\nSHA-256: {sha(output)}\nInput preserved: {before}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
