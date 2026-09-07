#!/usr/bin/env python3
"""Build and audit the embedded IPA. Never re-label a privileged TIPA."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import zipfile

MAGIC = 0xFEEDFACF
ARM64 = 0x100000C
DYLIB_COMMANDS = {0xC, 0xD, 0x80000018, 0x8000001F, 0x20, 0x80000023}
NATIVE_COMPONENTS = {
    "server/wineserver": "JuiceWineServer",
    "dlls/ntdll/ntdll.so": "JuiceNTDLL",
    "dlls/win32u/win32u.so": "JuiceWin32U",
    "dlls/wineios.drv/wineios.so": "JuiceWineIOS",
    "dlls/winevulkan/winevulkan.so": "JuiceWineVulkan",
    "dlls/ws2_32/ws2_32.so": "JuiceWinsock",
    "dlls/crypt32/crypt32.so": "JuiceCrypt",
    "dlls/dnsapi/dnsapi.so": "JuiceDNS",
    "dlls/secur32/secur32.so": "JuiceSecurity",
    "dlls/dwrite/dwrite.so": "JuiceDWrite",
    "dlls/mountmgr.sys/mountmgr.so": "JuiceMountMgr",
    "dlls/opengl32/opengl32.so": "JuiceOpenGL",
}
FORBIDDEN_IMPORTS = {"_fork", "_vfork", "_kill", "_killpg", "_execve", "_execv", "_execvp",
                     "_execl", "_execle", "_execlp", "_posix_spawn", "_posix_spawnp", "_ptrace"}

class PackageError(ValueError):
    pass

def sha(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

def macho(data: bytes | bytearray) -> tuple[tuple[int, ...], list[tuple[int, bytes]], int]:
    if len(data) < 32:
        raise PackageError("truncated Mach-O")
    header = struct.unpack_from("<8I", data)
    if header[0] != MAGIC or header[1] != ARM64 or header[3] not in (2, 6):
        raise PackageError("expected an arm64 iOS executable or dylib")
    count, size = header[4:6]
    if count > 4096 or size > 4 * 1024 * 1024 or 32 + size > len(data):
        raise PackageError("unbounded Mach-O load commands")
    commands, offset, first_data = [], 32, len(data)
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise PackageError("truncated load command header")
        kind, length = struct.unpack_from("<II", data, offset)
        if length < 8 or length % 8 or offset + length > 32 + size:
            raise PackageError("invalid load command size")
        command = bytes(data[offset:offset + length])
        if kind == 0x19:
            if length < 72:
                raise PackageError("truncated segment command")
            sections = struct.unpack_from("<I", command, 64)[0]
            if sections > 1024 or 72 + sections * 80 != length:
                raise PackageError("invalid section array")
            file_offset, file_size = struct.unpack_from("<QQ", command, 40)
            if file_offset + file_size > len(data):
                raise PackageError("segment outside file")
            if file_offset and file_size:
                first_data = min(first_data, file_offset)
            for index in range(sections):
                section = 72 + index * 80
                offset_value = struct.unpack_from("<I", command, section + 48)[0]
                flags = struct.unpack_from("<I", command, section + 64)[0]
                if offset_value and flags & 0xFF not in (1, 12, 18):
                    first_data = min(first_data, offset_value)
        commands.append((kind, command))
        offset += length
    if offset != 32 + size or first_data < offset:
        raise PackageError("overlapping load commands and section data")
    return header, commands, first_data

def command_string(command: bytes, minimum: int = 24) -> str:
    if len(command) < minimum:
        raise PackageError("truncated string command")
    offset = struct.unpack_from("<I", command, 8)[0]
    if not minimum <= offset < len(command):
        raise PackageError("invalid load-command string offset")
    end = command.find(b"\0", offset)
    if end < 0:
        raise PackageError("unterminated load-command string")
    return command[offset:end].decode("utf-8", errors="strict")

def replace_command_string(command: bytes, text: str) -> bytes:
    prefix = bytearray(command[:24])
    encoded = text.encode() + b"\0"
    length = (24 + len(encoded) + 7) & ~7
    struct.pack_into("<II", prefix, 4, length, 24)
    return bytes(prefix) + encoded + bytes(length - 24 - len(encoded))

def symbols(data: bytes) -> tuple[set[str], set[str]]:
    _, commands, _ = macho(data)
    imports, exports = set(), set()
    for kind, command in commands:
        if kind != 2:
            continue
        symoff, count, stroff, strsize = struct.unpack_from("<4I", command, 8)
        if count > 4 * 1024 * 1024 or symoff + count * 16 > len(data) or stroff + strsize > len(data):
            raise PackageError("invalid Mach-O symbol table")
        for index in range(count):
            string, flags, section, description, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
            if flags & 0xE0 or not flags & 1:
                continue
            if string >= strsize:
                raise PackageError("out-of-bounds symbol name")
            end = data.find(b"\0", stroff + string, stroff + strsize)
            if end < 0:
                raise PackageError("unterminated symbol")
            name = data[stroff + string:end].decode("utf-8", errors="strict")
            if flags & 0xE == 0 and not value:
                imports.add(name)
            elif flags & 0xE == 0xE and section:
                exports.add(name)
    return imports, exports

def framework_id(name: str) -> str:
    return f"@rpath/{name}.framework/{name}"

def rewrite_framework(path: Path, name: str, names: dict[str, str]) -> None:
    data = bytearray(path.read_bytes())
    header, commands, first_data = macho(data)
    if header[3] != 6:
        raise PackageError(f"not an embedded dylib: {path}")
    result = []
    for kind, command in commands:
        if kind == 0x1D:
            continue  # stale ad-hoc signature is rebuilt after all path changes
        if kind in DYLIB_COMMANDS:
            old = command_string(command)
            if kind == 0xD:
                new = framework_id(name)
            elif PurePosixPath(old).name in names:
                new = framework_id(names[PurePosixPath(old).name])
            elif old.startswith(("/usr/lib/", "/System/Library/")):
                new = re.sub(r"\.framework/Versions/[A-Za-z0-9]+/", ".framework/", old)
            elif old.startswith("@rpath/") and ".framework/" in old:
                new = old
            else:
                raise PackageError(f"unresolved framework dependency {path.name}: {old}")
            command = replace_command_string(command, new)
        result.append(command)
    joined = b"".join(result)
    if 32 + len(joined) > first_data:
        raise PackageError(f"insufficient load-command padding in {path}; relink with headerpad_max_install_names")
    old_end = 32 + header[5]
    new_end = 32 + len(joined)
    if any(data[old_end:new_end]):
        raise PackageError(f"refusing to overwrite non-padding bytes in {path}")
    data[32:max(old_end, new_end)] = joined + bytes(max(old_end, new_end) - new_end)
    struct.pack_into("<II", data, 16, len(result), len(joined))
    path.write_bytes(data)

def framework(source: Path, directory: Path, name: str) -> Path:
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]+", name):
        raise PackageError("unsafe framework name")
    if not source.is_file() or source.stat().st_size == 0:
        raise PackageError(f"missing compiled runtime component: {source}")
    target = directory / f"{name}.framework"
    target.mkdir(parents=True, exist_ok=True)
    binary = target / name
    shutil.copy2(source, binary)
    binary.chmod(0o755)
    (target / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": f"org.juice.runtime.{name}", "CFBundleExecutable": name,
        "CFBundleName": name, "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "14.0",
        "CFBundleSupportedPlatforms": ["iPhoneOS"], "UIDeviceFamily": [1, 2]}))
    return binary

def pe_audit(path: Path) -> None:
    with path.open("rb") as stream:
        data = stream.read(65536)
    if len(data) < 64 or data[:2] != b"MZ":
        raise PackageError(f"not a Windows module: {path}")
    offset = struct.unpack_from("<I", data, 60)[0]
    if offset + 24 > len(data) or data[offset:offset + 4] != b"PE\0\0":
        raise PackageError(f"truncated Windows module: {path}")
    machine, count = struct.unpack_from("<HH", data, offset + 4)
    optional = struct.unpack_from("<H", data, offset + 20)[0]
    if machine not in (0xAA64, 0xA641, 0xA64E, 0x8664) or optional < 64 or count > 96:
        raise PackageError(f"unsupported guest machine/header: {path}")
    start = offset + 24 + optional
    if start + count * 40 > len(data):
        raise PackageError(f"truncated PE sections: {path}")
    executable = False
    for index in range(count):
        section = start + index * 40
        flags = struct.unpack_from("<I", data, section + 36)[0]
        address = struct.unpack_from("<I", data, section + 12)[0]
        if flags & 0x20000000:
            executable = True
            if address % 16384:
                raise PackageError(f"code not aligned to an iOS VM page: {path}")
    alignment = struct.unpack_from("<I", data, offset + 24 + 32)[0]
    if executable and alignment < 16384:
        raise PackageError(f"executable PE sections share 16-KiB pages: {path}")

def audit_app(app: Path) -> dict:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("JuiceRuntimeBackend") != "embedded-sidestore" or info.get("CFBundleExecutable") != "Juice":
        raise PackageError("not a SideStore application bundle")
    report = {"backend": "embedded-sidestore", "abi": 1, "native_images": [], "pe_modules": 0,
              "device_execution_verified": False}
    all_frameworks = {p.stem for p in (app / "Frameworks").glob("*.framework")}
    required = {"JuiceRuntimeSupport", "JuiceNTDLL", "JuiceWineServer", "JuiceWin32U", "JuiceWineIOS"}
    if not required <= all_frameworks:
        raise PackageError("incomplete native framework set")
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise PackageError(f"IPA must not depend on extraction-time symlinks: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(app).as_posix()
        with path.open("rb") as stream:
            magic = stream.read(4)
        if path.suffix == ".plist":
            plistlib.loads(path.read_bytes())
        if magic != struct.pack("<I", MAGIC):
            if magic[:2] == b"MZ":
                pe_audit(path)
                report["pe_modules"] += 1
            continue
        data = path.read_bytes()
        header, commands, _ = macho(data)
        if path == app / "Juice":
            if header[3] != 2:
                raise PackageError("app executable is not MH_EXECUTE")
        elif len(path.relative_to(app).parts) != 3 or path.parent.parent != app / "Frameworks" or header[3] != 6:
            raise PackageError(f"loose or executable helper in SideStore package: {relative}")
        else:
            framework_info = plistlib.loads((path.parent / "Info.plist").read_bytes())
            if framework_info.get("CFBundlePackageType") != "FMWK" or framework_info.get("CFBundleExecutable") != path.name:
                raise PackageError(f"invalid framework metadata: {relative}")
        imports, exports = symbols(data)
        if path == app / "Juice" or path.name in set(NATIVE_COMPONENTS.values()) | {"JuiceRuntimeSupport"}:
            forbidden = imports & FORBIDDEN_IMPORTS
            if forbidden:
                raise PackageError(f"privileged process imports remain in {relative}: {sorted(forbidden)}")
        exported = {"JuiceNTDLL": {"_JuiceEmbeddedWineABI", "_JuiceEmbeddedWineMain"},
                    "JuiceWineServer": {"_JuiceEmbeddedWineServerABI", "_JuiceEmbeddedWineServerMain"},
                    "JuiceRuntimeSupport": {"_juice_runtime_start", "_juice_runtime_prepare_jit", "_juice_runtime_configure"}}.get(path.name, set())
        if not exported <= exports:
            raise PackageError(f"embedded ABI missing from {relative}: {sorted(exported - exports)}")
        for kind, command in commands:
            if kind not in DYLIB_COMMANDS or kind == 0xD:
                continue
            dependency = command_string(command)
            if dependency.startswith("@rpath/"):
                parts = PurePosixPath(dependency).parts
                if len(parts) != 3 or not parts[1].endswith(".framework") or parts[1][:-10] not in all_frameworks:
                    raise PackageError(f"unresolvable framework reference: {dependency}")
            elif not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise PackageError(f"non-sandbox dependency: {dependency}")
        report["native_images"].append({"path": relative, "bytes": len(data), "sha256": sha(path)})
    for runtime in ("Grape", "Grape-X64"):
        manifest = json.loads((app / runtime / "Runtime.json").read_text())
        if manifest.get("backend") != "embedded-sidestore" or manifest.get("abi") != 1:
            raise PackageError(f"invalid runtime manifest: {runtime}")
    return report

def copy_required(source: Path, target: Path) -> None:
    if not source.is_file() or not source.stat().st_size:
        raise PackageError(f"required input missing: {source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)

def build(root: Path, output: Path) -> dict:
    stage = root / "build/sidestore/package"
    app = stage / "Payload/Juice.app"
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(root / "build/sidestore/app/Juice.app", app)
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["JuiceRuntimeBackend"] = "embedded-sidestore"
    info["CFBundleShortVersionString"] = "0.3.0"
    info["CFBundleVersion"] = os.environ.get("GITHUB_RUN_NUMBER", "1")
    info_path.write_bytes(plistlib.dumps(info))
    native = Path(os.environ.get("JUICE_WINE_BUILD", root / "build/sidestore/native"))
    pe = Path(os.environ.get("JUICE_PE_BUILD", root / "build/sidestore/arm64-pe"))
    hybrid = Path(os.environ.get("JUICE_ARM64EC_PE_BUILD", root / "build/sidestore/hybrid-pe"))
    fex = Path(os.environ.get("JUICE_FEX_BUILD", root / "build/sidestore/fex-arm64ec"))
    frameworks = app / "Frameworks"
    names = {}
    native_paths = []
    for relative, name in NATIVE_COMPONENTS.items():
        native_paths.append((framework(native / relative, frameworks, name), name))
        names[Path(relative).name] = name
    support = root / "build/sidestore/frameworks/JuiceRuntimeSupport.framework/JuiceRuntimeSupport"
    native_paths.append((framework(support, frameworks, "JuiceRuntimeSupport"), "JuiceRuntimeSupport"))
    names["JuiceRuntimeSupport"] = "JuiceRuntimeSupport"
    libraries = root / "build/sidestore/libraries"
    subprocess.run(["bash", str(root / "scripts/bundle-ios-libraries.sh"), str(libraries)], check=True)
    for index, source in enumerate(sorted(p for p in libraries.iterdir() if p.is_file())):
        with source.open("rb") as stream:
            magic = stream.read(4)
        if magic == struct.pack("<I", MAGIC):
            name = "JuiceGnuTLS" if source.name == "libgnutls.30.dylib" else f"JD{index:03d}"
            native_paths.append((framework(source, frameworks, name), name))
            names[source.name] = name
        elif source.name == "ca-certificates.pem":
            copy_required(source, app / "Libraries" / source.name)
    # The existing fetcher pins the MoltenVK archive and verifies its checksum.
    subprocess.run(["bash", str(root / "scripts/fetch-moltenvk-linux.sh")], check=True)
    candidates = list((root / "build/deps").glob("moltenvk-*/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework"))
    if len(candidates) != 1:
        raise PackageError(f"expected one pinned MoltenVK framework, found {len(candidates)}")
    shutil.copytree(candidates[0], frameworks / "MoltenVK.framework", symlinks=False)
    native_paths.append((frameworks / "MoltenVK.framework/MoltenVK", "MoltenVK"))
    names["MoltenVK"] = "MoltenVK"
    for binary, name in native_paths:
        rewrite_framework(binary, name, names)

    targets = [line.split("#", 1)[0].strip() for line in (root / "config/runtime-modules.txt").read_text().splitlines()]
    targets = [t for t in targets if t]
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    for runtime in ("Grape", "Grape-X64"):
        dest = app / runtime
        dlls = dest / "runtime/lib/wine/aarch64-windows"
        wine_build = dest / "build/wine-ios"
        for target in targets:
            if not re.fullmatch(r"(?:dlls|programs)/[A-Za-z0-9_.+-]+/aarch64-windows/[A-Za-z0-9_.+-]+\.(?:dll|drv|exe|sys)", target):
                raise PackageError(f"unsafe runtime manifest path: {target}")
            source = hybrid if runtime == "Grape-X64" and target.startswith("dlls/") else pe
            copy_required(source / target, dlls / Path(target).name)
        for module in ("ntdll", "apisetschema"):
            copy_required(dlls / f"{module}.dll", wine_build / f"dlls/{module}/aarch64-windows/{module}.dll")
        if runtime == "Grape-X64":
            copy_required(fex / "Bin/libarm64ecfex.dll", dlls / "libarm64ecfex.dll")
        copy_required(native / "loader/wine.inf", wine_build / "loader/wine.inf")
        nls = sorted((root / "wine/nls").glob("*.nls"))
        if not nls:
            raise PackageError("no NLS tables")
        for file in nls:
            copy_required(file, wine_build / "nls" / file.name)
        for file in sorted((native / "include").glob("*.winmd")):
            copy_required(file, wine_build / "include" / file.name)
        # DOS drive links are created inside the installed app's data container.
        # Never follow template symlinks (particularly a possible z: -> /) on
        # the build host, and never rely on an IPA extractor preserving links.
        template = root / "packaging/prefix-template"
        for source in sorted(template.rglob("*")):
            relative = source.relative_to(template)
            if "dosdevices" in relative.parts or source.is_symlink():
                continue
            if source.is_file() and source.name != ".juice-prefix-ready":
                copy_required(source, dest / "prefix-template" / relative)
        # Prefix images must come from THIS build too, not historical binaries.
        system32 = dest / "prefix-template/drive_c/windows/system32"
        for file in system32.glob("*"):
            if file.is_file() and file.suffix.lower() in (".exe", ".dll", ".drv", ".sys"):
                if (dlls / file.name).is_file():
                    copy_required(dlls / file.name, file)
                else:
                    file.unlink()
        if runtime == "Grape-X64":
            copy_required(dlls / "libarm64ecfex.dll", system32 / "libarm64ecfex.dll")
        copy_required(root / "wine/dlls/winevulkan/winevulkan.json", dlls / "winevulkan.json")
        manifest = {"backend": "embedded-sidestore", "abi": 1, "revision": revision,
                    "native_guest": "arm64", "translated_guest": "x86_64" if runtime == "Grape-X64" else None,
                    "guest_subprocesses": False, "guest_x86_32": False, "max_guest_sessions_per_host": 1,
                    "prefix_bootstrap": "preseeded", "device_execution_verified": False}
        (dest / "Runtime.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for relative in ("wine/COPYING.LIB", "LICENSE", "docs/SIDESTORE-EMBEDDED-RUNTIME.md"):
        source = root / relative
        if source.is_file():
            copy_required(source, app / "RuntimeNotices" / source.name)
    report = audit_app(app)
    entitlements = root / "config/sidestore-entitlements.plist"
    requested = plistlib.loads(entitlements.read_bytes())
    if requested != {"get-task-allow": True}:
        raise PackageError("private or unexpected SideStore app entitlement")
    ldid = os.environ.get("LDID") or str(root / "build/ios-toolchain/bin/ldid")
    if not Path(ldid).is_file():
        raise PackageError("ldid is required for an auditable SideStore signing input")
    for binary, _ in native_paths:
        subprocess.run([ldid, "-S", "-Cadhoc", str(binary)], check=True)
        embedded = subprocess.check_output([ldid, "-e", str(binary)])
        if embedded.strip() and plistlib.loads(embedded):
            raise PackageError(f"framework has unexpected entitlements: {binary}")
    subprocess.run([ldid, f"-S{entitlements}", "-Cadhoc", str(app / "Juice")], check=True)
    actual = plistlib.loads(subprocess.check_output([ldid, "-e", str(app / "Juice")]))
    if actual != requested:
        raise PackageError("app signature entitlements differ from SideStore policy")
    report = audit_app(app)
    report["requested_entitlements"] = actual
    report["revision"] = revision
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_suffix(".ipa.part")
    with zipfile.ZipFile(partial, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for file in sorted(stage.rglob("*")):
            if file.is_file():
                archive.write(file, file.relative_to(stage).as_posix())
    with zipfile.ZipFile(partial) as archive:
        bad = archive.testzip()
        if bad:
            raise PackageError(f"CRC failed for {bad}")
    partial.replace(output)
    output.with_suffix(".ipa.sha256").write_text(f"{sha(output)}  {output.name}\n")
    output.with_suffix(".audit.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"JUICE_SIDESTORE_IPA_OK path={output} bytes={output.stat().st_size} revision={revision} device_verified=0")
    return report

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--audit-app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.audit_app:
            print(json.dumps(audit_app(args.audit_app), indent=2))
        else:
            root = args.root.resolve()
            output = (args.output or root / "dist/Juice-SideStore.ipa").resolve()
            if output.parent != root / "dist" or output.suffix != ".ipa":
                raise PackageError("SideStore IPA output must be directly inside dist/")
            build(root, output)
        return 0
    except (OSError, ValueError, struct.error, subprocess.CalledProcessError) as error:
        print(f"JUICE_SIDESTORE_PACKAGE_REJECTED: {error}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
