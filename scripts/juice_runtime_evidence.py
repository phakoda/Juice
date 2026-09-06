#!/usr/bin/env python3
"""Validate and summarize reported device measurements; never invent outcomes.

This tool does not run Windows programs, collect device telemetry, or certify
the supplied measurements. Use real device-run outputs and retain their logs.
All comparisons keep cold/warm/sustained phases separate.
"""
from __future__ import annotations
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import sys
from typing import Any

MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_RUNS = 10000
MAX_FRAMES = 1_000_000
MAX_MILLISECONDS = 86_400_000.0
MIN_FRAME_MILLISECONDS = 1e-9
PHASES = ("cold", "warm", "sustained")
STATES = {"pass", "fail", "untested", "not_applicable"}
THERMAL = {"nominal", "fair", "serious", "critical", "unknown"}
REQUIRED_CHECKS = ("launch", "ui", "file_io", "exit")

class EvidenceError(ValueError):
    pass

def require(condition: bool, message: str) -> None:
    if not condition:
        raise EvidenceError(message)

def text(value: Any, label: str, limit: int = 1024) -> str:
    require(isinstance(value, str) and bool(value.strip()) and
            len(value) <= limit and "\0" not in value, f"Invalid {label}")
    return value

def number(value: Any, label: str, *, positive: bool = False) -> float:
    require(type(value) in (int, float), f"{label} must be numeric, not Boolean")
    try:
        result = float(value)
    except (OverflowError, ValueError) as exc:
        raise EvidenceError(f"Invalid {label}") from exc
    require(math.isfinite(result) and (result > 0 if positive else result >= 0),
            f"{label} must be finite and {'positive' if positive else 'nonnegative'}")
    require(result <= MAX_MILLISECONDS, f"{label} exceeds the one-day observation bound")
    if positive:
        require(result >= MIN_FRAME_MILLISECONDS, f"{label} is below the supported timing precision")
    return result

def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result

def load(path: Path) -> dict[str, Any]:
    with path.open("rb") as stream:
        data = stream.read(MAX_FILE_BYTES + 1)
    require(len(data) <= MAX_FILE_BYTES, "Evidence file exceeds 32 MiB")
    try:
        result = json.loads(data.decode("utf-8-sig"), object_pairs_hook=unique_object)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise EvidenceError("Evidence must be valid UTF-8 JSON") from exc
    return validate(result)

def validate(data: Any) -> dict[str, Any]:
    require(isinstance(data, dict) and type(data.get("schema_version")) is int
            and data["schema_version"] == 1, "Expected schema_version 1")
    work = data.get("workload")
    env = data.get("environment")
    require(isinstance(work, dict) and isinstance(env, dict), "Missing workload/environment")
    for key in ("id", "version", "architecture"):
        text(work.get(key), f"workload.{key}")
    resolution = work.get("resolution")
    require(isinstance(resolution, list) and len(resolution) == 2 and
            all(type(x) is int and 0 <= x <= 32768 for x in resolution) and
            ((resolution[0] == 0) == (resolution[1] == 0)),
            "resolution must be [width,height], or [0,0] for a non-rendering CLI workload")
    for key in ("device", "os", "installation", "measurement_source"):
        text(env.get(key), f"environment.{key}")
    require(isinstance(env.get("juice_commit"), str) and
            re.fullmatch(r"[0-9a-fA-F]{40}", env["juice_commit"]) is not None,
            "juice_commit must be the full 40-character Git SHA")
    require(isinstance(env.get("runtime_sha256"), str) and
            re.fullmatch(r"[0-9a-fA-F]{64}", env["runtime_sha256"]) is not None,
            "runtime_sha256 must identify the runtime")
    runs = data.get("runs")
    require(isinstance(runs, list) and len(runs) <= MAX_RUNS, "Invalid runs array")
    seen: set[str] = set()
    frames_total = 0
    for index, run in enumerate(runs):
        require(isinstance(run, dict), f"Run {index} must be an object")
        identifier = text(run.get("id"), "run.id", 256)
        require(identifier not in seen, f"Duplicate run id: {identifier}")
        seen.add(identifier)
        require(run.get("phase") in PHASES, f"Invalid phase in {identifier}")
        outcome = run.get("outcome")
        require(outcome in ("pass", "fail", "untested"), f"Invalid outcome in {identifier}")
        checks = run.get("checks")
        require(isinstance(checks, dict) and all(k in checks for k in REQUIRED_CHECKS),
                f"{identifier}: launch/ui/file_io/exit checks are required")
        require(all(isinstance(k, str) and isinstance(v, str) and v in STATES
                    for k, v in checks.items()), f"Invalid check status in {identifier}")
        failed = "fail" in checks.values()
        incomplete = "untested" in checks.values()
        if outcome == "pass":
            require(not failed and not incomplete and checks["launch"] == "pass" and checks["exit"] == "pass",
                    f"{identifier}: incomplete or failed checks cannot be reported as pass")
        elif outcome == "fail":
            require(failed, f"{identifier}: fail requires a failed check")
        else:
            require(not failed and incomplete, f"{identifier}: untested requires an untested check and no failure")
        state = run.get("thermal_state", "unknown")
        require(isinstance(state, str) and state in THERMAL, f"Invalid thermal state in {identifier}")
        if "launch_ms" in run:
            number(run["launch_ms"], "launch_ms")
        frames = run.get("frame_ms", [])
        require(isinstance(frames, list), f"frame_ms must be an array in {identifier}")
        frames_total += len(frames)
        require(frames_total <= MAX_FRAMES, "Too many frame samples")
        for value in frames:
            number(value, "frame_ms", positive=True)
        for key in ("peak_rss_bytes", "dropped_frames", "coalesced_frames"):
            if key in run:
                require(type(run[key]) is int and 0 <= run[key] <= 2**63 - 1,
                        f"{key} must be a nonnegative 64-bit integer")
    return data

def stats(values: list[float]) -> dict[str, Any] | None:
    if not values:
        return None
    ordered = sorted(values)
    return {"count": len(values), "median": statistics.median(ordered),
            "p95": ordered[max(0, math.ceil(len(ordered) * .95) - 1)],
            "mean": statistics.fmean(ordered), "min": ordered[0], "max": ordered[-1]}

def summarize(data: dict[str, Any]) -> dict[str, Any]:
    validate(data)
    groups: dict[str, Any] = {}
    for phase in PHASES:
        runs = [r for r in data["runs"] if r["phase"] == phase]
        usable = [r for r in runs if r["outcome"] == "pass"]
        frames = [float(x) for r in usable for x in r.get("frame_ms", [])]
        frame_stats = stats(frames)
        thermal: dict[str, int] = {}
        for run in runs:
            state = run.get("thermal_state", "unknown")
            thermal[state] = thermal.get(state, 0) + 1
        groups[phase] = {
            "outcomes": {s: sum(r["outcome"] == s for r in runs) for s in ("pass", "fail", "untested")},
            "launch_ms": stats([float(r["launch_ms"]) for r in usable if "launch_ms" in r]),
            "frame_ms": frame_stats,
            "mean_fps": 1000.0 / frame_stats["mean"] if frame_stats else None,
            "peak_rss_bytes": max((r["peak_rss_bytes"] for r in usable if "peak_rss_bytes" in r), default=None),
            "thermal_states": thermal,
        }
    return {
        "schema_version": 1,
        "evidence_status": "reported measurements; not independently certified",
        "percentile_method": "nearest rank; frame samples pooled within phase; passed runs only",
        "workload": data["workload"], "environment": data["environment"],
        "phases": groups,
    }

def compare(baseline: dict[str, Any], candidate: dict[str, Any],
            allow_different_device: bool = False) -> dict[str, Any]:
    a, b = summarize(baseline), summarize(candidate)
    require(a["workload"] == b["workload"], "Workload/version/architecture/resolution differ")
    different = {}
    for key in ("device", "os", "installation"):
        if a["environment"][key] != b["environment"][key]:
            different[key] = [a["environment"][key], b["environment"][key]]
    require(not different or allow_different_device,
            "Device/OS/installation differ; explicitly use --allow-different-device for a cross-platform comparison")
    changes = {}
    for phase in PHASES:
        changes[phase] = {}
        for metric in ("launch_ms", "frame_ms"):
            old, new = a["phases"][phase][metric], b["phases"][phase][metric]
            for percentile in ("median", "p95"):
                x = old[percentile] if old else None
                y = new[percentile] if new else None
                changes[phase][f"{metric}_{percentile}"] = {
                    "baseline": x, "candidate": y,
                    "latency_reduction_percent": (100.0 * (x - y) / x)
                    if x is not None and y is not None and x > 0 else None,
                }
    return {"baseline": a, "candidate": b, "differences": different,
            "comparison": changes,
            "caveat": "Different hardware/OS is not an isolated software speedup." if different else
                       "Reported sample comparison; no causal or statistical significance claim."}

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    summary = sub.add_parser("summary")
    summary.add_argument("evidence", type=Path)
    comp = sub.add_parser("compare")
    comp.add_argument("baseline", type=Path)
    comp.add_argument("candidate", type=Path)
    comp.add_argument("--allow-different-device", action="store_true")
    args = parser.parse_args()
    try:
        result = summarize(load(args.evidence)) if args.command == "summary" else compare(
            load(args.baseline), load(args.candidate), args.allow_different_device)
        print(json.dumps(result, ensure_ascii=False, allow_nan=False, indent=2))
        return 0
    except (EvidenceError, OSError) as exc:
        print(f"Evidence rejected: {exc}", file=sys.stderr)
        return 2
if __name__ == "__main__":
    raise SystemExit(main())
