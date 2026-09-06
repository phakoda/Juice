#!/usr/bin/env python3
"""Reverse a low-to-high patch stack in an isolated, minimal source copy.

Only regular files named by the patches are copied. The caller's tree is never
patched, even on failure or interruption. This verifies the complete base patch
including newly introduced files changed by an incremental overlay; excluding
those files from the base check can hide unrecorded source drift.
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
            if relative.is_absolute() or not relative.parts or any(
                part in ("..", ".git") for part in relative.parts
            ):
                raise ValueError(f"Unsafe patch path: {field}")
            paths.add(relative)
    if not paths:
        raise ValueError(f"No patch paths in {patch}")
    return paths


def verify_stack(source: Path, patches: list[Path]) -> None:
    source = source.resolve(strict=True)
    patches = [patch.resolve(strict=True) for patch in patches]
    paths: set[PurePosixPath] = set()
    for patch in patches:
        paths.update(patch_paths(patch))
    with tempfile.TemporaryDirectory(prefix="juice-patch-verify-") as directory:
        isolated = Path(directory)
        for relative in sorted(paths):
            original = source.joinpath(*relative.parts)
            # Never follow a symlink out of the source checkout while copying.
            cursor = source
            for component in relative.parts:
                cursor /= component
                if cursor.is_symlink():
                    raise ValueError(f"Symlink is not an audited source file: {relative}")
            if not original.exists():
                continue  # A deleted file may be restored by reversing a patch.
            if not original.is_file():
                raise ValueError(f"Not a regular source file: {relative}")
            target = isolated.joinpath(*relative.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, target)
        subprocess.run(["git", "init", "-q", str(isolated)], check=True)
        for patch in reversed(patches):
            command = ["git", "-C", str(isolated), "apply", "--reverse"]
            subprocess.run(command + ["--check", str(patch)], check=True)
            subprocess.run(command + [str(patch)], check=True)
    print(f"JUICE_PATCH_STACK_VERIFY_OK layers={len(patches)} paths={len(paths)} isolated=1")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("patches", type=Path, nargs="+", help="Lowest/base layer first")
    args = parser.parse_args()
    try:
        verify_stack(args.source, args.patches)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Patch stack verification failed: {error}\n")


if __name__ == "__main__":
    main()
