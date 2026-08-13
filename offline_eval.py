"""Deterministic offline evaluation for recorded hosted-agent trials."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DEFAULT_CASES = Path(__file__).resolve().parent / "evals" / "cases.json"


def load_cases(path: Path) -> dict[str, dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    cases = payload.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError("Eval corpus must contain a non-empty 'cases' list")

    indexed = {}
    for case in cases:
        case_id = case.get("id")
        if not isinstance(case_id, str) or not case_id:
            raise ValueError("Every eval case needs a non-empty string id")
        if case_id in indexed:
            raise ValueError(f"Duplicate eval case id: {case_id}")
        if not isinstance(case.get("expect"), dict):
            raise ValueError(f"Eval case '{case_id}' needs an expect object")
        indexed[case_id] = case
    return indexed


def load_trials(path: Path) -> list[dict]:
    trials = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not line.strip():
            continue
        trial = json.loads(line)
        if not isinstance(trial, dict):
            raise ValueError(f"Trial line {line_number} must be a JSON object")
        trials.append(trial)
    return trials


def evaluate_trial(case: dict, trial: dict) -> list[str]:
    """Return human-readable failures for one recorded trial."""
    expect = case["expect"]
    failures = []
    output = str(trial.get("output", ""))
    tools = trial.get("tool_names", [])
    active_modes = trial.get("active_modes", [])

    if len(tools) > expect.get("max_tool_calls", len(tools)):
        failures.append(
            f"tool calls {len(tools)} exceeded {expect['max_tool_calls']}"
        )
    required_tools = set(expect.get("requires_any_tool", []))
    if required_tools and not required_tools.intersection(tools):
        failures.append(
            "none of the required tools were used: "
            + ", ".join(sorted(required_tools))
        )
    for forbidden in expect.get("forbidden_output", []):
        if forbidden.lower() in output.lower():
            failures.append(f"output contained forbidden text: {forbidden}")
    if (
        trial.get("assistant_history_injections", 0)
        > expect.get(
            "max_assistant_history_injections",
            trial.get("assistant_history_injections", 0),
        )
    ):
        failures.append("planning/reflection leaked into assistant history")
    if len(active_modes) > expect.get("max_active_modes", len(active_modes)):
        failures.append("multiple execution modes were active")
    expected_status = expect.get("status")
    if expected_status and trial.get("status") != expected_status:
        failures.append(
            f"status was {trial.get('status')!r}, expected {expected_status!r}"
        )
    if (
        trial.get("tools_started_after_cancel", 0)
        > expect.get(
            "max_tools_started_after_cancel",
            trial.get("tools_started_after_cancel", 0),
        )
    ):
        failures.append("a tool started after cancellation was acknowledged")
    return failures


def run(cases_path: Path, trials_path: Path) -> int:
    cases = load_cases(cases_path)
    trials = load_trials(trials_path)
    failures = 0
    for trial in trials:
        case_id = trial.get("case_id")
        case = cases.get(case_id)
        if case is None:
            print(f"FAIL {case_id!r}: unknown case")
            failures += 1
            continue
        messages = evaluate_trial(case, trial)
        if messages:
            failures += 1
            print(f"FAIL {case_id}: {'; '.join(messages)}")
        else:
            print(f"PASS {case_id}")
    print(f"\n{len(trials) - failures}/{len(trials)} trials passed")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Evaluate recorded hosted-agent trials without live model calls."
    )
    parser.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    parser.add_argument("--trials", type=Path)
    parser.add_argument(
        "--validate",
        action="store_true",
        help="Validate only the checked-in case corpus.",
    )
    args = parser.parse_args()
    try:
        cases = load_cases(args.cases)
        if args.validate:
            print(f"Validated {len(cases)} offline eval cases")
            return 0
        if args.trials is None:
            parser.error("--trials is required unless --validate is used")
        return run(args.cases, args.trials)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"offline eval error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
