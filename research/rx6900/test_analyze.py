import hashlib
import unittest
from unittest.mock import patch

import analyze


def marker_text(scores=None):
    scores = scores or [10.0] * 8
    lines = ["[THROUGHPUT] rungs=8 frame-batch-counts=64,128,192,256,384,512,768,1024 run-cnt=5"]
    for rung, score in zip(analyze.RUNGS, scores):
        lines += [f"[PERF-CFG] scenario=throughput files=25 frame-batch-count={rung} run-cnt=5",
                  "[PERF-CFG] demo --zst @list --prf-lvl 0 --seq-cnt",
                  f"[PERF] total batches=20 pooled_batches=19 frames=2000 decomp_bytes=100000 "
                  f"p50_latency_us=500 bandwidth_gbps={score} runs=5 warmup=0"]
    return "\n".join(lines)


class AnalysisTests(unittest.TestCase):
    def parse(self, text, rc=0):
        raw = text.encode()
        result = {"exitCode": rc, "action": "Run", "kind": "Perf", "runId": "test",
                  "arm": "A", "commit": "sha", "tests": {"tests": 1, "failures": 0},
                  "stdoutSha256": hashlib.sha256(raw).hexdigest(), "startedUtc": "now",
                  "corpusLockSha256": "corpus", "armManifestSha256": "arm"}
        with patch.object(analyze, "load", return_value=result), \
                patch.object(analyze.Path, "read_bytes", return_value=raw), \
                patch.object(analyze.Path, "glob", return_value=[analyze.Path("list")]):
            return analyze.parse_run("synthetic")

    def test_complete(self):
        self.assertAlmostEqual(self.parse(marker_text())["geomean"], 10)

    def test_missing_rung(self):
        with self.assertRaises(AssertionError):
            self.parse(marker_text([10] * 7))

    def test_nonpositive(self):
        with self.assertRaises(AssertionError):
            self.parse(marker_text([10] * 7 + [0]))

    def test_exit_failure(self):
        with self.assertRaises(AssertionError):
            self.parse(marker_text(), 1)

    def test_case_sensitive_reason(self):
        self.parse(marker_text() + "\nError: Corruption detected while decompressing")
        with self.assertRaises(AssertionError):
            self.parse(marker_text() + "\nfile.cpp error: unexpected exit")

    def test_methodology_rejected(self):
        with self.assertRaises(AssertionError):
            self.parse(marker_text().replace("--seq-cnt", "--seq-cnt --ext-mem"))

    def test_duplicate_rung(self):
        with self.assertRaises(AssertionError):
            self.parse(marker_text().replace("frame-batch-count=128", "frame-batch-count=64"))

    def test_wrong_sweep_count(self):
        with self.assertRaises(AssertionError):
            self.parse(marker_text().replace("runs=5", "runs=4"))

    def test_abba_statistical_unit(self):
        schedule = [{"session": session, "position": pos, "arm": arm, "runId": f"{session}-{pos}-{arm}"}
                    for session in range(1, 4) for pos, arm in enumerate("ABBA", 1)]

        def fake_run(path):
            session, pos, arm = path.name.split("-")
            score = (10 if arm == "A" else 10.1) * (1 + int(session) * .0001)
            return {"runId": path.name, "arm": arm, "commit": arm, "geomean": score, "files": 25,
                    "corpusLockSha256": "corpus", "selectedListSha256": "list", "armManifestSha256": arm,
                    "rungs": [{"rung": rung, "gbps": score} for rung in analyze.RUNGS]}

        with patch.object(analyze, "parse_run", side_effect=fake_run):
            summary = analyze.summarize("synthetic", schedule, "A", "B")
        self.assertEqual(summary["sessions"], 3)
        self.assertEqual(summary["arms"]["A"]["n"], 6)
        self.assertAlmostEqual(summary["delta_percent"], 1)
        self.assertTrue(summary["accepted"])

    def test_noisy_sessions_rejected(self):
        schedule = [{"session": session, "position": pos, "arm": arm, "runId": f"{session}-{pos}-{arm}"}
                    for session in range(1, 4) for pos, arm in enumerate("ABBA", 1)]

        def fake_run(path):
            session, pos, arm = path.name.split("-")
            score = 10 * (1 + (-.01, .01, .04)[int(session) - 1]) if arm == "B" else 10
            return {"runId": path.name, "arm": arm, "commit": arm, "geomean": score, "files": 25,
                    "corpusLockSha256": "corpus", "selectedListSha256": "list", "armManifestSha256": arm,
                    "rungs": [{"rung": rung, "gbps": score} for rung in analyze.RUNGS]}

        with patch.object(analyze, "parse_run", side_effect=fake_run):
            summary = analyze.summarize("synthetic", schedule, "A", "B")
        self.assertGreater(summary["delta_percent"], .3)
        self.assertLess(summary["z"], 3)
        self.assertFalse(summary["accepted"])


if __name__ == "__main__":
    unittest.main()
