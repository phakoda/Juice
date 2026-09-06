"""Audited runtime patch editing; no shell commands, network, or fuzzy matches."""
from __future__ import annotations
import difflib
import hashlib
import re
from pathlib import PurePosixPath

HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)\n?$")

def blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()

def sections(text: str) -> list[str]:
    if not text.startswith("diff --git "):
        raise ValueError("expected a standalone git patch")
    return re.split(r"(?=^diff --git )", text, flags=re.MULTILINE)[1:]

def section_path(section: str) -> str:
    match = re.fullmatch(r"diff --git a/(\S+) b/(\S+)", section.splitlines()[0])
    if not match or match[1] != match[2]:
        raise ValueError("renames/quoted paths are not supported by this editor")
    path = PurePosixPath(match[1])
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("unsafe patch path")
    return str(path)

def parse_hunks(section: str) -> tuple[list[str], list[tuple[re.Match[str], list[str], list[str]]]]:
    lines = section.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if HUNK.match(line)]
    if not starts:
        raise ValueError("no text hunks")
    parsed = []
    for index, begin in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(lines)
        header = HUNK.fullmatch(lines[begin])
        assert header
        old, new = [], []
        for line in lines[begin + 1:end]:
            if not line or line[0] not in " +-":
                raise ValueError("unsupported hunk encoding (including missing final newline)")
            if line[0] in " -": old.append(line[1:])
            if line[0] in " +": new.append(line[1:])
        if len(old) != int(header[2] or 1) or len(new) != int(header[4] or 1):
            raise ValueError("corrupt input hunk counts")
        parsed.append((header, old, new))
    return lines[:starts[0]], parsed

def edit_section(section: str, edits: list[dict[str, str]]) -> str:
    metadata, hunks = parse_hunks(section)
    matched = [0] * len(edits)
    changed = []
    for header, old, new in hunks:
        text = "".join(new)
        for i, edit in enumerate(edits):
            count = text.count(edit["old"])
            matched[i] += count
            if count: text = text.replace(edit["old"], edit["new"])
        changed.append((header, old, text.splitlines(keepends=True)))
    if any(count != 1 for count in matched):
        raise ValueError(f"each reviewed postimage must match exactly once: {matched}")
    # Recompute absolute new-file offsets and content hashes rather than leaving
    # stale index lines or hand-edited nested hunk counts in the patch stack.
    output = [line for line in metadata if not line.startswith("index ")]
    delta = 0
    for header, old, new in changed:
        old_start = int(header[1])
        generated = list(difflib.unified_diff(old, new, n=max(len(old), len(new)) + 1))
        if not generated: continue
        new_start = old_start + delta if old_start else 1
        output.append(f"@@ -{old_start},{len(old)} +{new_start},{len(new)} @@{header[5]}\n")
        output.extend(generated[3:])
        delta += len(new) - len(old)
    return "".join(output)

def added_file(section: str) -> bytes:
    metadata, hunks = parse_hunks(section)
    if not any(line == "new file mode 100644\n" for line in metadata):
        raise ValueError("expected a nonexecutable new-file section")
    if len(hunks) != 1 or hunks[0][1] or int(hunks[0][0][1]) != 0:
        raise ValueError("expected one whole-file addition")
    return "".join(hunks[0][2]).encode("utf-8")

def new_file_section(path: str, content: bytes) -> str:
    path = str(PurePosixPath(path))
    if path.startswith("/") or ".." in PurePosixPath(path).parts or any(c.isspace() for c in path):
        raise ValueError("unsafe output path")
    text = content.decode("utf-8")
    if not text or not text.endswith("\n"): raise ValueError("source must end with LF")
    lines = text.splitlines(keepends=True)
    return (f"diff --git a/{path} b/{path}\nnew file mode 100644\n"
            f"index 0000000000000000000000000000000000000000..{blob_sha(content)}\n"
            f"--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{len(lines)} @@\n"
            + "".join("+" + line for line in lines))

def revise_fex(text: str, edits: list[dict[str, str]], additions: dict[str, bytes]) -> str:
    output, seen = [], set()
    for section in sections(text):
        path = section_path(section)
        if path in seen: raise ValueError(f"duplicate patch section: {path}")
        seen.add(path)
        selected = [edit for edit in edits if edit["path"] == path]
        output.append(edit_section(section, selected) if selected else section)
    missing = {edit["path"] for edit in edits} - seen
    if missing: raise ValueError(f"missing FEX sections: {missing}")
    for path, content in sorted(additions.items()):
        if path in seen: raise ValueError(f"already-present addition: {path}")
        output.append(new_file_section(path, content))
    return "".join(output)

def revise_wine(text: str, replacements: dict[str, tuple[str, bytes]], additions: dict[str, bytes]) -> str:
    output, seen = [], set()
    for section in sections(text):
        path = section_path(section)
        if path in seen: raise ValueError(f"duplicate patch section: {path}")
        seen.add(path)
        if path in replacements:
            expected, new = replacements[path]
            if blob_sha(added_file(section)) != expected:
                raise ValueError(f"Wine postimage changed: {path}")
            section = new_file_section(path, new)
        output.append(section)
    if replacements.keys() - seen: raise ValueError("missing Wine replacement")
    for path, content in sorted(additions.items()):
        if path in seen: raise ValueError(f"already-present addition: {path}")
        output.append(new_file_section(path, content))
    return "".join(output)
