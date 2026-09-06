#!/usr/bin/env python3
"""Extract production code used by the portable integration regressions."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from runtime_core_patchlib import sections, section_path, parse_hunks, added_file, revise_fex


def one_function(text: str, marker: str) -> str:
    if text.count(marker) != 1:
        raise ValueError(f"expected exactly one production function: {marker}")
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 0
    for pos in range(opening, len(text)):
        if text[pos] == "{": depth += 1
        elif text[pos] == "}":
            depth -= 1
            if depth == 0: return text[start:pos + 1] + "\n"
    raise ValueError("unterminated production function")


def placement(text: str) -> str:
    marker = "      // Ensure a replacement buffer is selected before Align16B writes padding.\n"
    end = "      CodeBuffers.LatestOffset = GetCursorOffset();\n"
    candidates = []
    for section in sections(text):
        if section_path(section) != "FEXCore/Source/Interface/Core/JIT/JIT.cpp": continue
        for _, _, new in parse_hunks(section)[1]:
            postimage = "".join(new)
            if marker in postimage:
                start = postimage.index(marker)
                finish = postimage.index(end, start) + len(end)
                candidates.append(postimage[start:finish])
    if len(candidates) != 1: raise ValueError("expected one production placement block")
    return candidates[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", action="store_true",
                        help="Explicit source-subset mode; does NOT validate the complete FEX patch")
    args = parser.parse_args()
    root, out = args.root.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    fixture = (root / "tests/runtime-bringup/fixtures/fex-reviewed-hunks.patch").read_text()
    additions = {"FEXCore/Source/Interface/Core/" + path.name: path.read_bytes()
                 for path in sorted((root / "patches/fex-runtime").glob("*.h"))}
    if args.fixture:
        edits = json.loads((root / "scripts/runtime_core_fex_edits.json").read_text())
        fex = revise_fex(fixture, edits, additions)
        print("RUNTIME_CORE_TEST_SOURCE reviewed_hunk_fixture=1 complete_fex_patch=0")
    else:
        fex = (root / "patches/fex-runtime-core.patch").read_text()
        print("RUNTIME_CORE_TEST_SOURCE reviewed_hunk_fixture=0 runtime_core_overlay=1")
    found = {}
    for section in sections(fex):
        path = section_path(section)
        if path in additions:
            if path in found: raise ValueError("duplicate FEX helper")
            content = added_file(section)
            if content != additions[path]: raise ValueError(f"FEX helper/source drift: {path}")
            found[path] = content
            (out / Path(path).name).write_bytes(content)
    if found.keys() != additions.keys(): raise ValueError("FEX patch missing runtime helpers; synchronize patches first")
    (out / "placement_new.inc").write_text(placement(fex))
    (out / "placement_legacy.inc").write_text(placement(fixture))
    vulkan = (root / "wine/dlls/wineios.drv/vulkan.m").read_text()
    query = one_function(vulkan, "static VkBool32 iosdrv_get_physical_device_presentation_support(")
    (out / "presentation_query.inc").write_text(query)

if __name__ == "__main__":
    main()
