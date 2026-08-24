#!/usr/bin/env python3
"""Create/apply a content-exact directory delta using per-file zstd patches."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def members(root):
    return {path.relative_to(root).as_posix(): path for path in root.rglob("*")
            if path.is_symlink() or path.is_file()}


def tree_digest(root):
    value = hashlib.sha256()
    for name, path in sorted(members(root).items()):
        if path.is_symlink():
            record = f"L\0{name}\0{os.readlink(path)}\n".encode()
        else:
            record = f"F\0{name}\0{stat.S_IMODE(path.stat().st_mode):o}\0{digest(path)}\n".encode()
        value.update(record)
    return value.hexdigest()


def safe_path(root, name):
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise SystemExit(f"unsafe delta path: {name}")
    return root / relative


def create_delta(base, target, output):
    base_files, target_files = members(base), members(target)
    with tempfile.TemporaryDirectory(prefix="juice-release-delta-") as temporary:
        stage = Path(temporary)
        blobs = stage / "blobs"
        blobs.mkdir()
        entries = []
        blob_index = 0

        for name, target_path in sorted(target_files.items()):
            base_path = base_files.get(name)
            mode = stat.S_IMODE(target_path.lstat().st_mode)
            if target_path.is_symlink():
                link = os.readlink(target_path)
                if base_path is not None and base_path.is_symlink() and os.readlink(base_path) == link:
                    continue
                entries.append({"kind": "symlink", "path": name, "target": link})
                continue
            if base_path is not None and not base_path.is_symlink() and digest(base_path) == digest(target_path):
                if stat.S_IMODE(base_path.stat().st_mode) != mode:
                    entries.append({"kind": "mode", "path": name, "mode": mode})
                continue

            blob = f"{blob_index:04d}.zst"
            blob_index += 1
            blob_path = blobs / blob
            if base_path is not None and not base_path.is_symlink():
                command = ["zstd", "-q", "-f", "-10", "--long=31",
                           f"--patch-from={base_path}", str(target_path), "-o", str(blob_path)]
                kind = "patch"
            else:
                command = ["zstd", "-q", "-f", "-10", str(target_path), "-o", str(blob_path)]
                kind = "full"
            subprocess.run(command, check=True)
            entries.append({"kind": kind, "path": name, "blob": blob, "mode": mode,
                            "sha256": digest(target_path)})

        for name in sorted(set(base_files) - set(target_files)):
            entries.append({"kind": "delete", "path": name})

        manifest = {"format": 1, "target_tree_sha256": tree_digest(target), "entries": entries}
        (stage / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        tar_path = stage / "delta.tar"
        with tarfile.open(tar_path, "w") as archive:
            archive.add(stage / "manifest.json", arcname="manifest.json")
            archive.add(blobs, arcname="blobs")
        subprocess.run(["zstd", "-q", "-f", "-19", str(tar_path), "-o", str(output)], check=True)
        print(f"JUICE_RELEASE_DELTA_CREATED entries={len(entries)} tree={manifest['target_tree_sha256']} output={output}")


def apply_delta(base, delta):
    with tempfile.TemporaryDirectory(prefix="juice-release-delta-") as temporary:
        stage = Path(temporary)
        tar_path = stage / "delta.tar"
        subprocess.run(["zstd", "-q", "-d", "-f", str(delta), "-o", str(tar_path)], check=True)
        with tarfile.open(tar_path, "r") as archive:
            archive.extractall(stage, filter="data")
        manifest = json.loads((stage / "manifest.json").read_text())
        if manifest.get("format") != 1:
            raise SystemExit("unsupported Juice release delta format")
        for entry in manifest["entries"]:
            destination = safe_path(base, entry["path"])
            kind = entry["kind"]
            if kind == "delete":
                if destination.is_dir() and not destination.is_symlink():
                    shutil.rmtree(destination)
                else:
                    destination.unlink(missing_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            if kind == "symlink":
                destination.unlink(missing_ok=True)
                destination.symlink_to(entry["target"])
                continue
            if kind == "mode":
                destination.chmod(entry["mode"])
                continue
            blob = stage / "blobs" / entry["blob"]
            replacement = destination.with_name(destination.name + ".juice-delta")
            if kind == "patch":
                subprocess.run(["zstd", "-q", "-d", "--long=31", f"--patch-from={destination}",
                                str(blob), "-o", str(replacement)], check=True)
            elif kind == "full":
                subprocess.run(["zstd", "-q", "-d", str(blob), "-o", str(replacement)], check=True)
            else:
                raise SystemExit(f"unknown delta operation: {kind}")
            if digest(replacement) != entry["sha256"]:
                raise SystemExit(f"delta output checksum mismatch: {entry['path']}")
            replacement.chmod(entry["mode"])
            os.replace(replacement, destination)
        actual = tree_digest(base)
        if actual != manifest["target_tree_sha256"]:
            raise SystemExit(f"release tree checksum mismatch: expected {manifest['target_tree_sha256']}, got {actual}")
        print(f"JUICE_RELEASE_DELTA_APPLIED tree={actual} root={base}")


parser = argparse.ArgumentParser()
subparsers = parser.add_subparsers(dest="command", required=True)
create = subparsers.add_parser("create")
create.add_argument("base", type=Path)
create.add_argument("target", type=Path)
create.add_argument("output", type=Path)
apply = subparsers.add_parser("apply")
apply.add_argument("base", type=Path)
apply.add_argument("delta", type=Path)
args = parser.parse_args()
if args.command == "create":
    create_delta(args.base.resolve(), args.target.resolve(), args.output.resolve())
else:
    apply_delta(args.base.resolve(), args.delta.resolve())
