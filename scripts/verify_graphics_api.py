#!/usr/bin/env python3
"""Audit packaged Wine builtins; do not equate module presence with API support."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import struct
import sys
from pathlib import Path
from typing import BinaryIO, NoReturn

NAME = re.compile(r"[a-z0-9][a-z0-9_.+-]*\Z")
TARGET = re.compile(r"(?:dlls|programs)/[A-Za-z0-9_.+-]+/aarch64-windows/[A-Za-z0-9_.+-]+\.(?:dll|exe|drv|sys)\Z")
ASSIGN = re.compile(r"^([A-Z][A-Z0-9_]*)\s*(\+?=)\s*(.*?)\s*$", re.MULTILINE)
VARIABLE = re.compile(r"\$\([A-Z0-9_]+\)")

class AuditError(ValueError):
    pass

def read_bounded(path: Path, root: Path, maximum: int = 1024 * 1024) -> str:
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root.resolve()) or not resolved.is_file():
        raise AuditError(f"not a regular file inside the source root: {path}")
    with resolved.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum or b"\0" in data:
        raise AuditError(f"invalid or oversized source input: {path}")
    return data.decode("utf-8", errors="strict")

def entries(text: str) -> list[str]:
    return [line for raw in text.splitlines() if (line := raw.split("#", 1)[0].strip())]

def assignments(text: str) -> dict[str, str]:
    # Only read literal declarations. Never evaluate Make expressions or shell.
    logical = text.replace("\\\n", " ")
    result: dict[str, str] = {}
    for match in ASSIGN.finditer(logical):
        name, operator, value = match.groups()
        value = value.split("#", 1)[0].strip()
        result[name] = (result.get(name, "") + " " + value).strip() if operator == "+=" else value
    return result

def audit(root: Path) -> dict:
    root = root.resolve()
    raw_manifest = read_bounded(root / "config/runtime-modules.txt", root)
    manifest = entries(raw_manifest)
    if not manifest or len(manifest) > 4096 or any(not TARGET.fullmatch(t) or ".." in t.split("/") for t in manifest):
        raise AuditError("invalid runtime target manifest")
    filenames = [Path(t).name.casefold() for t in manifest]
    if len(filenames) != len(set(filenames)):
        raise AuditError("duplicate or case-colliding packaged module")
    packaged = {Path(t).name.casefold(): t for t in manifest}
    catalog = entries(read_bounded(root / "config/graphics-api-modules.txt", root))
    if not catalog or len(catalog) > 1024 or len(catalog) != len(set(catalog)) or any(not NAME.fullmatch(n) or ".." in n for n in catalog):
        raise AuditError("invalid graphics/API catalog")
    modules, errors = [], []
    for name in sorted(catalog):
        expected = f"dlls/{name}/aarch64-windows/{name}.dll"
        if packaged.get(name + ".dll") != expected:
            errors.append(f"{name}: missing or mismatched runtime target")
            continue
        try:
            declarations = assignments(read_bounded(root / f"wine/dlls/{name}/Makefile.in", root))
        except FileNotFoundError:
            errors.append(f"{name}: no source module in the pinned Wine tree")
            continue
        if declarations.get("MODULE") != name + ".dll":
            errors.append(f"{name}: Wine MODULE does not match the catalog")
            continue
        imports_text = " ".join(declarations.get(key, "") for key in ("IMPORTS", "DELAYIMPORTS"))
        expressions = sorted(set(VARIABLE.findall(imports_text)))
        literals = VARIABLE.sub("", imports_text).split()
        dependencies = []
        for dependency in literals:
            if not NAME.fullmatch(dependency) or ".." in dependency:
                raise AuditError(f"{name}: nonliteral import declaration: {dependency}")
            makefile = root / f"wine/dlls/{dependency}/Makefile.in"
            if not makefile.exists():
                continue  # Static/import-only libraries, e.g. uuid, need no DLL.
            module = assignments(read_bounded(makefile, root)).get("MODULE", "")
            if not module.endswith((".dll", ".drv")):
                continue
            dependencies.append(module)
            if module.casefold() not in packaged:
                errors.append(f"{name}: imported Wine module is not packaged: {module}")
        spec = root / f"wine/dlls/{name}/{name}.spec"
        stubs = None
        if spec.exists():
            stubs = sum(bool(re.search(r"^\s*(?:@|\d+)\s+stub\b", line))
                        for line in read_bounded(spec, root).splitlines())
        modules.append({"name": name, "target": expected, "imports": sorted(set(dependencies)),
                        "configured_import_expressions": expressions, "declared_stub_exports": stubs})
    if errors:
        raise AuditError("\n".join(errors))
    return {"schema_version": 1, "catalog_count": len(modules), "packaged_count": len(manifest),
            "manifest_sha256": hashlib.sha256(raw_manifest.encode()).hexdigest(), "modules": modules,
            "scope": "literal source imports; configured libraries, dynamic loads and runtime behavior are not certified"}

def make_targets(report: dict, makefile: str, arch: str) -> list[str]:
    choices = {"aarch64": ("aarch64",), "arm64ec": ("arm64ec", "aarch64"), "i386": ("i386",)}
    if arch not in choices:
        raise AuditError("unsupported PE build architecture")
    known = set(re.findall(r"^([^\s:#]+):", makefile, flags=re.MULTILINE))
    targets = []
    for module in report["modules"]:
        name = module["name"]
        matches = [f"dlls/{name}/{a}-windows/{name}.dll" for a in choices[arch]
                   if f"dlls/{name}/{a}-windows/{name}.dll" in known]
        if len(matches) != 1:
            raise AuditError(f"{name}: expected one configured {arch} PE target; found {matches}")
        targets.extend(matches)
    return targets

def arm64ec_image_evidence(stream: BinaryIO, pe_offset: int, coff: bytes, file_size: int) -> dict:
    """Require CHPE code metadata or positive proof of a code-free forwarder.

    A641 identifies intermediate COFF objects, not final ARM64EC DLLs. Linked
    EC images use AMD64 plus a CHPEMetadataPointer in the PE32+ load configuration.
    Wine's --data-only export forwarders contain no code and need no CHPE. They
    are accepted only after verifying absent execution hooks and bounded pure
    forwarder exports, never by filename. This is structural, not semantic proof.
    """
    def reject(message: str) -> NoReturn:
        raise AuditError(f"invalid ARM64EC image: {message}")

    def read_at(offset: int, count: int) -> bytes:
        if offset < 0 or count < 0 or offset > file_size or count > file_size - offset:
            reject("truncated or out-of-file metadata")
        stream.seek(offset)
        data = stream.read(count)
        if len(data) != count:
            reject("short metadata read")
        return data

    sections_count = struct.unpack_from("<H", coff, 6)[0]
    optional_size = struct.unpack_from("<H", coff, 20)[0]
    if not 1 <= sections_count <= 96 or not 200 <= optional_size <= 4096:
        reject("section count or optional header size")
    optional = read_at(pe_offset + 24, optional_size)
    if struct.unpack_from("<H", optional)[0] != 0x20B:
        reject("expected a PE32+ optional header")
    directories = struct.unpack_from("<I", optional, 108)[0]
    if not 11 <= directories <= (optional_size - 112) // 8:
        reject("missing or truncated load-configuration directory")
    image_base = struct.unpack_from("<Q", optional, 24)[0]
    image_size, headers_size = struct.unpack_from("<II", optional, 56)
    section_offset = pe_offset + 24 + optional_size
    if not section_offset + sections_count * 40 <= headers_size <= min(file_size, image_size):
        reject("invalid image/header bounds")
    sections = []
    executable_sections = False
    for i in range(sections_count):
        entry = read_at(section_offset + i * 40, 40)
        virtual_size, address, raw_size, raw_offset = struct.unpack_from("<IIII", entry, 8)
        if address + max(virtual_size, raw_size) > image_size or raw_offset + raw_size > file_size:
            reject("section extends beyond the image or file")
        sections.append((address, raw_size, raw_offset))
        executable_sections |= bool(struct.unpack_from("<I", entry, 36)[0] & 0x20000020)

    def rva_offset(rva: int, count: int) -> int:
        if rva <= 0 or count <= 0 or rva >= image_size or count > image_size - rva:
            reject("out-of-image metadata RVA")
        candidates = [rva] if rva + count <= headers_size else []
        candidates += [raw + rva - address for address, size, raw in sections
                       if address <= rva and rva - address + count <= size]
        if len(candidates) != 1:
            reject("unmapped or ambiguous metadata RVA")
        return candidates[0]

    config_rva, config_size = struct.unpack_from("<II", optional, 112 + 10 * 8)
    if config_rva == 0 and config_size == 0:
        if executable_sections or any(struct.unpack_from("<I", optional, offset)[0]
                                      for offset in (4, 16, 20)):
            reject("code or entry point without CHPE metadata")
        # Only exports, resources, signatures and debug data are compatible
        # with this code-free case. In particular, reject TLS callbacks, CLR,
        # imports, IAT, exception and relocation directories rather than guess.
        for i in range(directories):
            if i not in (0, 2, 4, 6) and any(struct.unpack_from("<II", optional, 112 + i * 8)):
                reject("execution-related directory in a code-free forwarder")
        export_rva, export_size = struct.unpack_from("<II", optional, 112)
        if not 40 <= export_size <= 1024 * 1024:
            reject("missing or unbounded forwarder export directory")
        exports = read_at(rva_offset(export_rva, export_size), export_size)

        def export_bytes(rva: int, count: int) -> bytes:
            if count <= 0 or rva < export_rva or rva - export_rva + count > export_size:
                reject("direct export or out-of-bounds forwarder data")
            rva_offset(rva, count)  # Reject overlapping mappings, even for a subrange.
            return exports[rva - export_rva:rva - export_rva + count]

        def export_string(rva: int) -> str:
            export_bytes(rva, 1)
            start = rva - export_rva
            end = exports.find(b"\0", start, min(start + 1024, export_size))
            if end <= start or any(byte < 33 or byte > 126 for byte in exports[start:end]):
                reject("invalid or unterminated forwarder/export string")
            return exports[start:end].decode("ascii")

        module_rva, ordinal_base, function_count, name_count, functions_rva, names_rva, ordinals_rva = \
            struct.unpack_from("<IIIIIII", exports, 12)
        if not 1 <= function_count <= 65536 or name_count > function_count or ordinal_base + function_count > 0x100000000:
            reject("unbounded forwarder export counts")
        if not re.fullmatch(r"[A-Za-z0-9_+.-]+", export_string(module_rva)):
            reject("invalid forwarder module name")
        functions = list(struct.unpack(f"<{function_count}I", export_bytes(functions_rva, function_count * 4)))
        forwarders = 0
        for rva in functions:
            if not rva:  # Sparse ordinal tables are legitimate, not executable exports.
                continue
            module, separator, symbol = export_string(rva).rpartition(".")
            if not separator or not symbol or not re.fullmatch(r"[A-Za-z0-9_+.-]+", module) or ".." in module:
                reject("invalid forwarded module/symbol")
            if symbol.startswith("#") and (not re.fullmatch(r"#[0-9]{1,5}", symbol) or not 1 <= int(symbol[1:]) <= 65535):
                reject("invalid forwarded ordinal")
            forwarders += 1
        if not forwarders:
            reject("no forwarded exports")
        if name_count:
            names = struct.unpack(f"<{name_count}I", export_bytes(names_rva, name_count * 4))
            ordinals = struct.unpack(f"<{name_count}H", export_bytes(ordinals_rva, name_count * 2))
            for name_rva, ordinal in zip(names, ordinals):
                export_string(name_rva)
                if ordinal >= function_count or not functions[ordinal]:
                    reject("named forwarder has no valid ordinal target")
        return {"kind": "forwarder-only", "forwarded_exports": forwarders}
    if not 208 <= config_size <= 4096:
        reject("missing or undersized CHPE load configuration")
    config = read_at(rva_offset(config_rva, config_size), config_size)
    declared_size = struct.unpack_from("<I", config)[0]
    if not 208 <= declared_size <= config_size:
        reject("inconsistent load-configuration size")
    metadata_va = struct.unpack_from("<Q", config, 200)[0]
    metadata = read_at(rva_offset(metadata_va - image_base, 12), 12)
    version, code_map_rva, code_map_count = struct.unpack("<III", metadata)
    if version not in (1, 2) or code_map_count > 1024 * 1024:
        reject("unsupported CHPE version or unbounded code map")
    if code_map_count:
        rva_offset(code_map_rva, code_map_count * 8)
    return {"kind": "chpe", "version": version, "code_map_entries": code_map_count}


def inspect_build(build: Path, targets: list[str], arch: str) -> list[dict]:
    expected = {"aarch64": 0xAA64, "arm64ec": 0x8664, "i386": 0x14C}[arch]
    result = []
    for target in targets:
        path = build / target
        with path.open("rb") as stream:
            file_size = os.fstat(stream.fileno()).st_size
            dos = stream.read(64)
            if len(dos) != 64 or dos[:2] != b"MZ":
                raise AuditError(f"{target}: missing PE DOS header")
            offset = struct.unpack_from("<I", dos, 60)[0]
            if offset < 64 or offset > 1024 * 1024:
                raise AuditError(f"{target}: invalid PE header offset")
            stream.seek(offset)
            pe = stream.read(24)
            if len(pe) != 24 or pe[:4] != b"PE\0\0" or struct.unpack_from("<H", pe, 4)[0] != expected:
                raise AuditError(f"{target}: wrong PE signature or machine")
            if not struct.unpack_from("<H", pe, 22)[0] & 0x2000:
                raise AuditError(f"{target}: expected a DLL image")
            try:
                evidence = arm64ec_image_evidence(stream, offset, pe, file_size) if arch == "arm64ec" else None
            except AuditError as error:
                raise AuditError(f"{target}: {error}") from error
            stream.seek(0)
            hasher = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(block)
            digest = hasher.hexdigest()
        entry = {"path": target, "machine": expected, "architecture": arch, "sha256": digest, "bytes": file_size}
        if evidence is not None:
            entry["architecture_evidence"] = evidence
        result.append(entry)
    return result

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--build", type=Path)
    parser.add_argument("--arch", choices=("aarch64", "arm64ec", "i386"), default="aarch64")
    parser.add_argument("--targets", action="store_true", help="print configured make targets, one per line")
    args = parser.parse_args()
    try:
        report = audit(args.root)
        if args.targets and not args.build:
            parser.error("--targets requires --build")
        if args.build:
            targets = make_targets(report, read_bounded(args.build / "Makefile", args.build, 64 * 1024 * 1024), args.arch)
            if args.targets:
                print("\n".join(targets))
                return 0
            report["built_architecture"] = args.arch
            report["built_modules"] = inspect_build(args.build, targets, args.arch)
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    except (OSError, UnicodeError, AuditError) as error:
        print(f"JUICE_GRAPHICS_API_REJECTED: {error}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
