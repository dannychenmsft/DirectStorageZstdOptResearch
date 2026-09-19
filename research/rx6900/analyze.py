"""Fail-closed exact-CI rung extraction and session-level paired ABBA inference."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import statistics

RUNGS = (64, 128, 192, 256, 384, 512, 768, 1024)


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def parse_run(path):
    path = Path(path)
    result = load(path / "result.json")
    invocation = load(path / "invocation.json")
    assert result["exitCode"] == 0, f"Failed run: {path}"
    assert result["action"] == "Run" and result["kind"] == "Perf", "Not acceptance data"
    assert result["tests"]["tests"] == 1 and result["tests"]["failures"] == 0
    assert invocation["arm"] == result["arm"] and invocation["commit"] == result["commit"]
    assert invocation["startedUtc"] == result["startedUtc"], "Invocation does not match result"
    selected = list((path / "batch_lists").glob("*perf_throughput*.txt"))
    assert len(selected) == 1, "Missing/ambiguous throughput corpus list"
    selected_bytes = selected[0].read_bytes()
    raw = (path / "stdout.txt").read_bytes()
    assert hashlib.sha256(raw).hexdigest().upper() == result["stdoutSha256"].upper(), "Output changed"
    text = raw.decode("utf-8-sig", errors="strict")
    assert not re.search(r"error: |TIMED OUT|DEVICE_REMOVED|887A", text), "Failure signature"
    assert "[THROUGHPUT] rungs=8 frame-batch-counts=64,128,192,256,384,512,768,1024 run-cnt=5" in text
    rows = []
    current = None
    files = None
    for line in text.splitlines():
        match = re.search(r"\[PERF-CFG\] scenario=throughput files=(\d+) frame-batch-count=(\d+) run-cnt=(\d+)", line)
        if match:
            assert current is None, "Missing preceding rung total"
            count, current, runs = map(int, match.groups())
            assert count > 0 and runs == 5
            assert files in (None, count), "Corpus count changed between rungs"
            files = count
        if "[PERF-CFG]" in line and "--zst" in line:
            assert "--ext-mem" not in line and "--prf-lvl 0" in line and "--seq-cnt" in line
        if "[PERF] total " in line:
            assert current is not None, "Duplicate or unassociated rung total"
            values = dict(re.findall(r"(\w+)=([0-9.]+)", line))
            score = float(values["bandwidth_gbps"])
            assert math.isfinite(score) and score > 0
            assert int(values["runs"]) == 5
            rows.append({"rung": current, "gbps": score, "p50_us": float(values["p50_latency_us"]),
                         "frames": int(values["frames"]), "pooled_batches": int(values["pooled_batches"])})
            current = None
    assert tuple(row["rung"] for row in rows) == RUNGS, f"Missing/duplicate/out-of-order rung: {path}"
    return {"runId": result["runId"], "arm": result["arm"], "commit": result["commit"],
            "corpusLockSha256": invocation["corpusLockSha256"],
            "armManifestSha256": invocation["armManifestSha256"],
            "selectedListSha256": hashlib.sha256(selected_bytes).hexdigest(),
            "files": files, "rungs": rows,
            "geomean": math.exp(statistics.mean(math.log(row["gbps"]) for row in rows))}


def summarize(root, schedule, baseline, candidate, minimum_margin=0.003):
    records = []
    sessions = {}
    for entry in schedule:
        run = parse_run(Path(root) / entry["runId"])
        assert run["arm"] == entry["arm"]
        run.update(session=entry["session"], position=entry["position"])
        records.append(run)
        sessions.setdefault(entry["session"], []).append(run)
    ratios = []
    for session in sessions.values():
        session.sort(key=lambda row: row["position"])
        assert [row["position"] for row in session] == [1, 2, 3, 4], "Incomplete ABBA session"
        assert [row["arm"] for row in session] == [baseline, candidate, candidate, baseline]
        logs = [math.log(row["geomean"]) for row in session]
        ratios.append((logs[1] + logs[2] - logs[0] - logs[3]) / 2)
    assert len(ratios) >= 2, "At least two independent ABBA sessions required"
    assert len({row["corpusLockSha256"] for row in records}) == 1, "Corpus lock changed"
    assert len({row["selectedListSha256"] for row in records}) == 1, "Selected throughput corpus changed"
    mean = statistics.mean(ratios)
    stderr = statistics.stdev(ratios) / math.sqrt(len(ratios))
    separation = mean / stderr if stderr else (1e300 if mean > 0 else 0)
    arms = {}
    for arm in (baseline, candidate):
        selected = [row for row in records if row["arm"] == arm]
        values = [row["geomean"] for row in selected]
        assert len({row["commit"] for row in selected}) == 1, "Arm source changed"
        assert len({row["armManifestSha256"] for row in selected}) == 1, "Arm binary/configuration changed"
        arms[arm] = {
            "commit": selected[0]["commit"], "n": len(values),
            "geomean": math.exp(statistics.mean(map(math.log, values))),
            "arithmetic_mean": statistics.mean(values), "stdev": statistics.stdev(values),
            "spread_percent": 100 * (max(values) / min(values) - 1),
            "rungs": {str(rung): math.exp(statistics.mean(math.log(row["rungs"][i]["gbps"])
                                                        for row in selected))
                      for i, rung in enumerate(RUNGS)}}
    healthy = all(arm["spread_percent"] <= 5 for arm in arms.values())
    accepted = (len(ratios) >= 3 and healthy and mean >= math.log1p(minimum_margin) and separation >= 3)
    return {"baseline": baseline, "candidate": candidate, "arms": arms, "sessions": len(ratios),
            "session_log_ratios": ratios, "mean_log_ratio": mean, "stderr_log_ratio": stderr,
            "delta_percent": 100 * math.expm1(mean), "z": separation,
            "three_sigma_delta_interval_percent": [100 * math.expm1(mean - 3 * stderr),
                                                   100 * math.expm1(mean + 3 * stderr)],
            "healthy_spread": healthy, "minimum_margin_percent": minimum_margin * 100,
            "accepted": accepted, "verdict": "accept" if accepted else "repeat_or_reject",
            "inference_unit": "one complete ABBA session (not rungs or GPU submissions)", "runs": records}


def summarize_screen(root, schedule, baseline):
    records = []
    for entry in schedule:
        run = parse_run(Path(root) / entry["runId"])
        assert run["arm"] == entry["arm"]
        run["position"] = entry["position"]
        records.append(run)
    assert [row["position"] for row in records] == list(range(len(records)))
    assert len(records) >= 3 and records[0]["arm"] == baseline and records[-1]["arm"] == baseline
    assert records[0]["commit"] == records[-1]["commit"]
    assert records[0]["armManifestSha256"] == records[-1]["armManifestSha256"]
    assert len({row["corpusLockSha256"] for row in records}) == 1
    assert len({row["selectedListSha256"] for row in records}) == 1
    candidates = records[1:-1]
    assert all(row["arm"] != baseline for row in candidates)
    assert len({row["arm"] for row in candidates}) == len(candidates)
    control = math.sqrt(records[0]["geomean"] * records[-1]["geomean"])
    drift = 100 * (records[-1]["geomean"] / records[0]["geomean"] - 1)
    return {
        "policyVersion": 2, "mode": "screen-only", "accepted": False,
        "verdict": "provisional ranking only; confirmation required for any acceptance",
        "baseline": baseline, "baseline_bracket_geomean": control,
        "control_drift_percent": drift, "control_drift_warning": abs(drift) > .5,
        "candidates": [{"arm": row["arm"], "commit": row["commit"], "geomean": row["geomean"],
                        "delta_percent": 100 * (row["geomean"] / control - 1),
                        "n": 1, "stderr_log_ratio": None, "z": None, "accepted": False}
                       for row in candidates],
        "runs": records}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--schedule")
    parser.add_argument("--baseline")
    parser.add_argument("--candidate")
    parser.add_argument("--output")
    parser.add_argument("--screen", action="store_true")
    args = parser.parse_args()
    if args.screen:
        value = summarize_screen(args.root, load(args.schedule), args.baseline)
    else:
        value = summarize(args.root, load(args.schedule), args.baseline, args.candidate) if args.schedule else parse_run(args.root)
    rendered = json.dumps(value, indent=2, allow_nan=False)
    if args.output:
        output = Path(args.output)
        assert not output.exists(), "Summary output is immutable"
        output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
