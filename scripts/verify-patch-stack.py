#!/usr/bin/env python3
"""Verify complete applied and optional patch layers in an isolated source copy.

Optional layers may be absent or applied as an ordered prefix. Every candidate
must reverse the entire established base and replay every optional layer; a
matching final hunk alone is not evidence that the patch stack is intact.
"""
from __future__ import annotations
import argparse
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import tempfile


def patch_paths(patch: Path) -> set[PurePosixPath]:
    paths: set[PurePosixPath] = set()
    for line in patch.read_text(encoding="utf-8").splitlines():
        if not line.startswith("diff --git "):
            continue
        fields = shlex.split(line)
        if len(fields) != 4 or not fields[2].startswith("a/") or not fields[3].startswith("b/"):
            raise ValueError(f"Unsupported diff header in {patch.name}: {line}")
        for field in fields[2:]:
            relative = PurePosixPath(field[2:])
            if relative.is_absolute() or not relative.parts or any(part in ("..", ".git") for part in relative.parts):
                raise ValueError(f"Unsafe patch path: {field}")
            paths.add(relative)
    if not paths:
        raise ValueError(f"No patch paths in {patch}")
    return paths


def copy_sources(source: Path, target: Path, paths: set[PurePosixPath]) -> None:
    for relative in sorted(paths):
        original = source.joinpath(*relative.parts)
        cursor = source
        for component in relative.parts:
            cursor /= component
            if cursor.is_symlink():
                raise ValueError(f"Symlink is not an audited source file: {relative}")
        if not original.exists():
            continue
        if not original.is_file():
            raise ValueError(f"Not a regular source file: {relative}")
        destination = target.joinpath(*relative.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, destination)


def verify_stack(source: Path, patches: list[Path], optional: list[Path] | None = None,
                 quiet: bool = False) -> int:
    source = source.resolve(strict=True)
    patches = [patch.resolve(strict=True) for patch in patches]
    optional = [patch.resolve(strict=True) for patch in optional or []]
    paths: set[PurePosixPath] = set()
    for patch in patches + optional:
        paths.update(patch_paths(patch))
    last_error = None
    with tempfile.TemporaryDirectory(prefix="juice-patch-verify-") as directory:
        snapshot = Path(directory) / "snapshot"
        snapshot.mkdir()
        copy_sources(source, snapshot, paths)
        for applied in range(len(optional), -1, -1):
            isolated = Path(directory) / str(applied)
            shutil.copytree(snapshot, isolated)
            subprocess.run(["git", "init", "-q", str(isolated)], check=True)
            command = ["git", "-C", str(isolated), "apply", "--recount"]
            try:
                for patch in reversed(patches + optional[:applied]):
                    subprocess.run(command + ["--reverse", "--check", str(patch)], check=True, capture_output=True)
                    subprocess.run(command + ["--reverse", str(patch)], check=True, capture_output=True)
                # Also prove all optional layers apply, not merely that the
                # current tree can be reduced to the recorded base.
                for patch in patches + optional:
                    subprocess.run(command + ["--check", str(patch)], check=True, capture_output=True)
                    subprocess.run(command + [str(patch)], check=True, capture_output=True)
            except subprocess.CalledProcessError as error:
                last_error = error
                continue
            if not quiet:
                print(f"JUICE_PATCH_STACK_VERIFY_OK layers={len(patches)} optional={len(optional)} "
                      f"applied={applied} paths={len(paths)} isolated=1")
            return applied
    assert last_error is not None
    raise last_error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("patches", type=Path, nargs="+", help="Applied base layers, lowest first")
    parser.add_argument("--optional", type=Path, nargs="*", default=[])
    parser.add_argument("--applied-count", action="store_true")
    args = parser.parse_args()
    try:
        applied = verify_stack(args.source, args.patches, args.optional, args.applied_count)
        if args.applied_count:
            print(applied)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", b"")
        parser.exit(1, f"Patch stack verification failed: {error}\n{detail.decode(errors='replace') if detail else ''}")


if __name__ == "__main__":
    main()
