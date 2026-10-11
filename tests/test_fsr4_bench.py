import csv
import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "helpers/fsr4_bench_report.py"
spec = importlib.util.spec_from_file_location("fsr4_bench_report", MODULE)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class BenchmarkReportTests(unittest.TestCase):
    def test_valid_frametimes_and_percentiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            csv_file = Path(tmp) / "data.csv"
            with csv_file.open("w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["OS: Bazzite"])
                w.writerow(["fps", "frametime", "gpu_load"])
                for _ in range(99):
                    w.writerow([100, 10, 80])
                w.writerow([20, 50, 80])
            result = report.parse(csv_file)
            self.assertEqual(100, result["frames"])
            self.assertAlmostEqual(100000 / 1040, result["mean_fps"])
            self.assertAlmostEqual(20, result["one_percent_low"])
            self.assertAlmostEqual(10, result["p99_ms"])

    def test_reject_too_short_or_invalid_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            csv_file = Path(tmp) / "bad.csv"
            csv_file.write_text("fps,frametime\n60,nope\n", encoding="utf-8")
            self.assertIsNone(report.parse(csv_file))

    def test_never_invents_missing_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = io.StringIO()
            with redirect_stdout(output):
                report.main(Path(tmp))
            self.assertIn("NO CAPTURES", output.getvalue())
            self.assertIn("No baseline", output.getvalue())
            self.assertNotIn("vs default: +", output.getvalue())


if __name__ == "__main__":
    unittest.main()
