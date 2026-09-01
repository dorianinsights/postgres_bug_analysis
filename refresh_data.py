#!/usr/bin/env python3
"""Refresh every external data source the pipeline reads, in one command.

Orchestrates the project's three independent fetch/scrape steps — the same
ones the README lists as re-runnable stages — in sequence, then runs the dbt
build that derives the analysis datasets from them:

    git   postgres_clone.py       .cache/postgres.git  (commits, tags, release-notes SGML)
    mail  mailing_list_sync.py    .cache/mbox/         (pgsql-bugs + pgsql-hackers mboxes; needs .env creds)
    cve   scrape_cve_severity.py  data/raw/cve_severity.csv
    build dbt deps + dbt build    transform.duckdb marts (derived from the three above)

Each step is still runnable on its own (this just runs them in order, times
them, and prints a summary); each fetch is idempotent — past mbox months and
the immutable git history are never re-fetched, only what changed. The fetches
are independent, so by default a failing one doesn't stop the others: every
fetch runs, the summary shows per-step status, and the process exits non-zero
if any failed. Use --fail-fast to stop at the first failure instead.

The dbt build runs by default, but ONLY if every selected fetch succeeded —
so the marts are never rebuilt on half-refreshed data. Pass --no-build to
refresh the sources without rebuilding.

    ./venv/bin/python refresh_data.py                 # all three fetches, then dbt build
    ./venv/bin/python refresh_data.py --no-build      # refresh the sources only
    ./venv/bin/python refresh_data.py --only cve      # re-scrape CVEs, then dbt build
    ./venv/bin/python refresh_data.py --skip mail     # everything but the slow mbox sync
    ./venv/bin/python refresh_data.py --list          # show the steps and exit
    ./venv/bin/python refresh_data.py --dry-run       # show the commands without running

Run it with the repo's venv Python (./venv/bin/python …) so the child steps
inherit that interpreter — the orchestrator launches them with the same
sys.executable it was started with.

Note: the dbt build takes a read-write lock on transform/transform.duckdb, so
quit any interactive DuckDB/Harlequin session first (see CLAUDE.md), or pass
--no-build.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).parent
VENV_BIN = Path(sys.executable).parent  # ./venv/bin when run via the repo venv


@dataclass(frozen=True)
class Step:
    key: str
    script: str
    label: str


STEPS: tuple[Step, ...] = (
    Step("git", "postgres_clone.py", "Sync the postgres.git clone (commits, tags, release-notes SGML)"),
    Step("mail", "mailing_list_sync.py", "Sync pgsql-bugs + pgsql-hackers mbox archives (needs .env creds)"),
    Step("cve", "scrape_cve_severity.py", "Scrape published CVSS severity ratings for PostgreSQL CVEs"),
)
STEP_KEYS = tuple(s.key for s in STEPS)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Refresh all external data sources (git clone, mboxes, CVE severities).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Steps: " + "  ".join(f"{s.key} = {s.script}" for s in STEPS),
    )
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--only",
        metavar="STEPS",
        help=f"comma-separated subset to run (of: {', '.join(STEP_KEYS)})",
    )
    selection.add_argument(
        "--skip",
        metavar="STEPS",
        help="comma-separated steps to exclude (run all the rest)",
    )
    parser.add_argument(
        "--no-build",
        action="store_false",
        dest="build",
        help="skip the dbt build (default: build the marts, but only if every fetch succeeded)",
    )
    parser.add_argument(
        "--fail-fast",
        action="store_true",
        help="stop at the first failing step (default: run every step, report all)",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        dest="list_steps",
        help="print the steps in run order and exit",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the command for each selected step without running it",
    )
    return parser.parse_args()


def select_steps(args: argparse.Namespace) -> list[Step]:
    """Resolve --only / --skip into the ordered list of steps to run."""
    if args.only:
        wanted = _parse_keys(args.only)
        return [s for s in STEPS if s.key in wanted]
    if args.skip:
        excluded = _parse_keys(args.skip)
        return [s for s in STEPS if s.key not in excluded]
    return list(STEPS)


def _parse_keys(raw: str) -> set[str]:
    keys = {k.strip() for k in raw.split(",") if k.strip()}
    unknown = keys - set(STEP_KEYS)
    if unknown:
        sys.exit(f"unknown step(s): {', '.join(sorted(unknown))} (valid: {', '.join(STEP_KEYS)})")
    return keys


def run(cmd: list[str], *, cwd: Path, dry_run: bool) -> int:
    """Run a child command, streaming its output live. Returns its exit code."""
    printable = " ".join(cmd)
    print(f"    $ {printable}", flush=True)
    if dry_run:
        return 0
    # No capture: child stdout/stderr stream straight through so long-running
    # steps (the mbox sync) show progress in real time.
    return subprocess.run(cmd, cwd=cwd).returncode


def banner(text: str) -> None:
    line = "=" * 78
    print(f"\n{line}\n{text}\n{line}", flush=True)


Result = tuple[str, int, float]  # (step key, exit code, elapsed seconds)


def print_step_list(steps: list[Step], *, with_build: bool) -> None:
    print("Steps in run order:")
    for s in steps:
        print(f"  {s.key:5} {s.script:24} {s.label}")
    if with_build:
        print(f"  {'build':5} {'dbt deps + dbt build':24} Derive the marts in transform/")


def run_fetches(steps: list[Step], args: argparse.Namespace) -> tuple[list[Result], bool]:
    """Run each fetch step; return its results and whether --fail-fast aborted."""
    results: list[Result] = []
    for step in steps:
        banner(f"[{step.key}] {step.label}")
        started = time.monotonic()
        code = run([sys.executable, str(ROOT / step.script)], cwd=ROOT, dry_run=args.dry_run)
        results.append((step.key, code, time.monotonic() - started))
        if code != 0 and args.fail_fast:
            print(f"\n[{step.key}] failed (exit {code}); stopping (--fail-fast).", file=sys.stderr)
            return results, True
    return results, False


def run_build(prior: list[Result], *, dry_run: bool) -> Result | None:
    """Run `dbt deps` + `dbt build`, but only if every prior fetch succeeded."""
    fetch_failed = [k for k, code, _ in prior if code != 0]
    if fetch_failed:
        print(f"\nskipping dbt build: fetch step(s) failed ({', '.join(fetch_failed)}).", file=sys.stderr)
        return None
    dbt = str(VENV_BIN / "dbt")
    transform = ROOT / "transform"
    banner("[build] dbt deps + dbt build (transform/)")
    started = time.monotonic()
    code = run([dbt, "deps"], cwd=transform, dry_run=dry_run)
    if code == 0:
        code = run([dbt, "build"], cwd=transform, dry_run=dry_run)
    return ("build", code, time.monotonic() - started)


def print_summary(results: list[Result], *, aborted: bool) -> bool:
    banner("Summary")
    ok = True
    for key, code, elapsed in results:
        status = "ok" if code == 0 else f"FAILED (exit {code})"
        ok = ok and code == 0
        print(f"  {key:6} {status:20} {elapsed:6.1f}s")
    if aborted:
        print("  (remaining steps not run — --fail-fast)")
    return ok


def main() -> int:
    args = parse_args()
    steps = select_steps(args)

    if args.list_steps:
        print_step_list(steps, with_build=args.build)
        return 0

    if not steps and not args.build:
        sys.exit("nothing selected to run")

    results, aborted = run_fetches(steps, args)

    if args.build and not aborted:
        build_result = run_build(results, dry_run=args.dry_run)
        if build_result is not None:
            results.append(build_result)

    ok = print_summary(results, aborted=aborted)
    return 0 if ok and not aborted else 1


if __name__ == "__main__":
    sys.exit(main())
