#!/usr/bin/env python3
"""Validate source-backed graphics module selection, not renderer compatibility."""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path, PurePosixPath
from runtime_core_patchlib import blob_sha

GRAPHICS_MODULES = (
    "d3d8", "d3d9", "d3d10", "d3dcompiler_39", "d3dcompiler_43",
    "d3dx9_43", "d3dx10_43", "d3dx11_43", "d3dxof", "ddraw",
    "gdiplus", "mlang", "propsys", "windowscodecs",
)
TARGET = re.compile(r"(?:dlls|programs)/[A-Za-z0-9_.+-]+/aarch64-windows/[A-Za-z0-9_.+-]+\.(?:dll|exe|drv|sys)")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z_0-9]*)\s*([+:?]?=)\s*(.*)$")
VARIABLE = re.compile(r"\$\(([A-Z_0-9]+)\)")
OPTIONAL_PE_LIBS = {"TIFF_PE_LIBS", "JPEG_PE_LIBS", "PNG_PE_LIBS"}


def assignments(text: str) -> dict[str, str]:
    if "\0" in text or len(text.encode()) > 65536:
        raise ValueError("invalid or oversized Makefile")
    fields: dict[str, str] = {}
    for line in text.replace("\\\n", " ").splitlines():
        match = ASSIGN.fullmatch(line.split("#", 1)[0].strip())
        if not match: continue
        key, op, value = match.groups()
        if op == "+=": fields[key] = fields.get(key, "") + " " + value
        elif op != "?=" or key not in fields: fields[key] = value
    return fields


def validate(manifest: str, makefiles: dict[str, str]) -> dict[str, object]:
    entries = [s for line in manifest.splitlines() if (s := line.split("#", 1)[0].strip())]
    if not entries or len(entries) > 4096 or any(not TARGET.fullmatch(e) for e in entries):
        raise ValueError("invalid runtime target")
    basenames = [PurePosixPath(e).name.lower() for e in entries]
    if len(set(entries)) != len(entries) or len(set(basenames)) != len(basenames):
        raise ValueError("duplicate runtime target or case-insensitive module name")
    names = set(basenames) | {PurePosixPath(name).stem for name in basenames}
    selected = set(entries)
    specs = {path: assignments(text) for path, text in makefiles.items()}
    # Resolve the actual default compiler import library: d3dcompiler means
    # d3dcompiler_47.dll in this Wine tree, not a nonexistent d3dcompiler.dll.
    aliases: dict[str, str] = {}
    for path, fields in specs.items():
        module, alias = fields.get("MODULE", ""), fields.get("IMPORTLIB", "")
        if module and alias and module.lower() in names:
            if alias in aliases and aliases[alias] != module:
                raise ValueError(f"ambiguous import-library alias: {alias}")
            aliases[alias] = module
    dependencies: dict[str, list[str]] = {}
    external: set[str] = set()
    for name in GRAPHICS_MODULES:
        target = f"dlls/{name}/aarch64-windows/{name}.dll"
        if target not in selected: raise ValueError(f"graphics module is not selected: {target}")
        path = f"wine/dlls/{name}/Makefile.in"
        if path not in specs: raise ValueError(f"missing Wine module definition: {path}")
        fields = specs[path]
        if fields.get("MODULE") != name + ".dll": raise ValueError(f"module output mismatch: {path}")
        if fields.get("UNIXLIB", "").strip():
            raise ValueError(f"additional Unix library needs explicit staging integration: {path}")
        raw = fields.get("IMPORTS", "") + " " + fields.get("DELAYIMPORTS", "")
        variables = set(VARIABLE.findall(raw))
        if variables - OPTIONAL_PE_LIBS: raise ValueError(f"unreviewed import variable: {variables}")
        external |= variables
        tokens = VARIABLE.sub("", raw).split()
        resolved = []
        for token in tokens:
            if not re.fullmatch(r"[A-Za-z_0-9.+-]+", token): raise ValueError(f"unsupported import: {token}")
            if token.lower() in names or token in aliases:
                resolved.append(token)
                continue
            static = specs.get(f"wine/libs/{token}/Makefile.in", {}).get("STATICLIB")
            if static != f"lib{token}.a": raise ValueError(f"unselected declared dependency: {name} -> {token}")
        dependencies[name] = sorted(set(resolved))
    return {"selected_graphics_modules": len(GRAPHICS_MODULES), "manifest_targets": len(entries),
            "declared_dependencies": dependencies, "optional_pe_libraries": sorted(external),
            "renderer_certified": False, "dynamic_loads_audited": False}


def load_reviewed(root: Path, fixture: bool) -> dict[str, str]:
    data = json.loads((root / "tests/runtime-bringup/fixtures/graphics-makefiles.json").read_text())
    result = {}
    for path, item in data["files"].items():
        if path.startswith("/") or ".." in PurePosixPath(path).parts: raise ValueError("unsafe source fixture path")
        text = item["content"] if fixture else (root / path).read_text()
        if blob_sha(text.encode()) != item["blob_sha"]:
            raise ValueError(f"Wine definition changed; review dependencies and refresh fixture: {path}")
        result[path] = text
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--fixture", action="store_true", help="Validate captured definitions, not a complete local Wine tree")
    args = parser.parse_args()
    report = validate((args.root / "config/runtime-modules.txt").read_text(), load_reviewed(args.root, args.fixture))
    report["captured_definition_fixture"] = args.fixture
    print(json.dumps(report, indent=2, sort_keys=True))

if __name__ == "__main__":
    main()
