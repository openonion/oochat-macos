import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import offline_eval


class OfflineEvalTests(unittest.TestCase):
    def test_checked_in_corpus_is_valid(self):
        cases = offline_eval.load_cases(offline_eval.DEFAULT_CASES)
        self.assertIn("interrupt_stops_new_tools", cases)

    def test_evaluate_trial_reports_runtime_contract_failures(self):
        case = {
            "expect": {
                "max_tool_calls": 0,
                "max_assistant_history_injections": 0,
                "max_active_modes": 1,
                "status": "cancelled",
                "max_tools_started_after_cancel": 0,
            }
        }
        failures = offline_eval.evaluate_trial(
            case,
            {
                "output": "done",
                "tool_names": ["bash"],
                "assistant_history_injections": 1,
                "active_modes": ["plan", "ulw"],
                "status": "completed",
                "tools_started_after_cancel": 1,
            },
        )
        self.assertEqual(len(failures), 5)

    def test_load_cases_rejects_malformed_case_corpora(self):
        malformed_payloads = [
            {},
            {"cases": [{}]},
            {
                "cases": [
                    {"id": "duplicate", "expect": {}},
                    {"id": "duplicate", "expect": {}},
                ]
            },
            {"cases": [{"id": "missing-expect"}]},
        ]
        expected_messages = [
            "non-empty 'cases' list",
            "non-empty string id",
            "Duplicate eval case id",
            "needs an expect object",
        ]

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cases.json"
            for index, payload in enumerate(malformed_payloads):
                path.write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, expected_messages[index]):
                    offline_eval.load_cases(path)

    def test_load_trials_skips_blanks_and_rejects_non_object_records(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trials.jsonl"
            path.write_text(
                "\n"
                + json.dumps({"case_id": "first"})
                + "\n   \n"
                + json.dumps({"case_id": "second"})
                + "\n",
                encoding="utf-8",
            )
            self.assertEqual(
                [trial["case_id"] for trial in offline_eval.load_trials(path)],
                ["first", "second"],
            )

            path.write_text("{}\n[]\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "Trial line 2"):
                offline_eval.load_trials(path)

    def test_evaluate_trial_reports_required_tools_and_forbidden_output(self):
        failures = offline_eval.evaluate_trial(
            {
                "expect": {
                    "requires_any_tool": ["grep", "read_file"],
                    "forbidden_output": ["secret", "credential"],
                }
            },
            {
                "output": "A SECRET was exposed",
                "tool_names": ["web_fetch"],
            },
        )

        self.assertEqual(len(failures), 2)
        self.assertIn("grep, read_file", failures[0])
        self.assertIn("forbidden text: secret", failures[1])

    def test_run_accepts_a_passing_recorded_trial(self):
        with tempfile.TemporaryDirectory() as directory:
            trials = Path(directory) / "trials.jsonl"
            trials.write_text(
                json.dumps(
                    {
                        "case_id": "interrupt_stops_new_tools",
                        "output": "",
                        "tool_names": ["read_file"],
                        "assistant_history_injections": 0,
                        "active_modes": ["safe"],
                        "status": "cancelled",
                        "tools_started_after_cancel": 0,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            self.assertEqual(
                offline_eval.run(offline_eval.DEFAULT_CASES, trials),
                0,
            )

    def test_run_reports_unknown_and_failing_trials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = root / "cases.json"
            trials = root / "trials.jsonl"
            cases.write_text(
                json.dumps({
                    "cases": [
                        {
                            "id": "known",
                            "expect": {"status": "completed"},
                        }
                    ]
                }),
                encoding="utf-8",
            )
            trials.write_text(
                "\n".join([
                    json.dumps({"case_id": "missing"}),
                    json.dumps({"case_id": "known", "status": "error"}),
                ]),
                encoding="utf-8",
            )
            output = io.StringIO()

            with contextlib.redirect_stdout(output):
                result = offline_eval.run(cases, trials)

        self.assertEqual(result, 1)
        self.assertIn("unknown case", output.getvalue())
        self.assertIn("status was 'error'", output.getvalue())
        self.assertIn("0/2 trials passed", output.getvalue())

    def test_main_validates_runs_and_reports_input_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = root / "cases.json"
            trials = root / "trials.jsonl"
            cases.write_text(
                json.dumps({
                    "cases": [{"id": "case", "expect": {}}]
                }),
                encoding="utf-8",
            )
            trials.write_text(
                json.dumps({"case_id": "case"}) + "\n",
                encoding="utf-8",
            )

            with patch.object(
                sys,
                "argv",
                ["offline_eval.py", "--cases", str(cases), "--validate"],
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(offline_eval.main(), 0)

            with patch.object(
                sys,
                "argv",
                [
                    "offline_eval.py",
                    "--cases",
                    str(cases),
                    "--trials",
                    str(trials),
                ],
            ), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(offline_eval.main(), 0)

            cases.write_text("not-json", encoding="utf-8")
            error_output = io.StringIO()
            with patch.object(
                sys,
                "argv",
                ["offline_eval.py", "--cases", str(cases), "--validate"],
            ), contextlib.redirect_stderr(error_output):
                self.assertEqual(offline_eval.main(), 2)
            self.assertIn("offline eval error", error_output.getvalue())

    def test_main_requires_trials_without_validate(self):
        with patch.object(
            sys,
            "argv",
            ["offline_eval.py", "--cases", str(offline_eval.DEFAULT_CASES)],
        ), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                offline_eval.main()

        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
