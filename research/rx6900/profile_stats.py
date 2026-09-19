"""Exploratory per-dispatch timestamp summaries; never acceptance statistics."""
import argparse
import csv
import json
import math
from pathlib import Path
import re
import statistics


def profile(path, rung):
    path = Path(path)
    result = json.loads((path / "result.json").read_text(encoding="utf-8-sig"))
    assert result["action"] == "Profile" and result["exitCode"] == 0
    text = (path / "stdout.txt").read_text(encoding="utf-8-sig")
    match = re.search(r"\[PERF\] total batches=(\d+) pooled_batches=(\d+) frames=(\d+)", text)
    batches, pooled, frames = map(int, match.groups())
    assert batches == math.ceil(frames / rung)
    rows = list(csv.DictReader((path / "profile.csv").open(encoding="utf-8-sig")))
    assert len(rows) == batches * 5
    rows = [row for row in rows if int(row["RunIdx"]) % batches < pooled]
    columns = {}
    for key in rows[0]:
        if key.endswith("(us)"):
            values = [float(row[key]) for row in rows]
            columns[key] = {"mean_us": statistics.mean(values), "median_us": statistics.median(values)}
    combined = [float(row.get("Stage 2 :: Init Huffman Table (us)", 0)) +
                float(row["Stage 2 :: Decompress Literals (us)"]) for row in rows]
    columns["Huffman table plus literals (us)"] = {
        "mean_us": statistics.mean(combined), "median_us": statistics.median(combined)}
    return {"runId": result["runId"], "rung": rung, "pooled_dispatches": len(rows),
            "frames": frames, "columns": columns}


def dxil(path):
    text = Path(path).read_text()
    return {"header": Path(path).name, "threads": re.search(r"NumThreads=\(([^)]+)\)", text)[1],
            "declared_lds_bytes": 4 * int(re.search(r"addrspace\(3\) global \[(\d+) x i32\]", text)[1]),
            "static_barrier_calls": len(re.findall(r"call void @dx.op.barrier", text)),
            "static_buffer_load_calls": len(re.findall(r"call .* @dx.op.bufferLoad", text)),
            "static_buffer_store_calls": len(re.findall(r"call .* @dx.op.bufferStore", text)),
            "dxil_instruction_lines": len(re.findall(r"(?m)^  (%\d+ = |call |br |ret |switch |store )", text)),
            "limitation": "DXIL static counts, not AMD ISA, register pressure, dynamic frequency, or occupancy"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", required=True)
    parser.add_argument("--baseline-source", required=True)
    parser.add_argument("--reference-source", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    result = {"acceptance_data": False, "profiles": {}, "dxil": {}}
    for arm in ("baseline", "reference"):
        result["profiles"][arm] = {str(rung): profile(Path(args.results) / f"{arm}-profile-{rung}", rung)
                                   for rung in (256, 1024)}
        source = getattr(args, f"{arm}_source")
        result["dxil"][arm] = dxil(Path(source) / "zstd" / "x64" / "Release" / "Shaders" /
                                  "ZstdGpuInitHuffmanTableAndDecompressLiterals.h")
    output = Path(args.output)
    assert not output.exists(), "Profile summary is immutable"
    output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    for rung in ("256", "1024"):
        print(f"Rung {rung}: baseline/reference mean microseconds (full pooled dispatches only)")
        for column in ("Stage 0 (us)", "Stage 1 (us)", "Stage 2 (us)",
                       "Huffman table plus literals (us)", "Stage 2 :: Decode Huffman Weights (us)",
                       "Stage 2 :: Decompress Sequences (us)", "Stage 2 :: ExecuteSequences (us)"):
            a = result["profiles"]["baseline"][rung]["columns"][column]["mean_us"]
            b = result["profiles"]["reference"][rung]["columns"][column]["mean_us"]
            print(f"  {column}: {a:.3f}/{b:.3f}, baseline-reference {a-b:+.3f}")
