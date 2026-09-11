#!/usr/bin/env python3
"""Refresh every external data source the pipeline reads, in one command.

Runs the project's three independent fetch steps -- the same modules that are
runnable on their own -- in sequence, IN THIS PROCESS, then runs the dbt build
that derives the analysis datasets from them:

    git   postgres_clone.main()       .cache/postgres.git  (commits, tags, release-notes SGML)
    mail  mailing_list_sync.main()    .cache/mbox/         (pgsql-bugs + pgsql-hackers mboxes; needs .env creds)
    cve   scrape_cve_severity.main()  data/raw/cve_severity.csv
    build dbt deps + dbt build        transform.duckdb marts (derived from the three above)

Each fetch is a direct function call (no child interpreter), timed, with its
output streaming through as it runs. A step FAILS when its main() raises --
any exception (the traceback is printed) or a SystemExit with a non-zero
code, which is how the scripts themselves signal failure -- and the failure
is recorded as that step's status. Each fetch is idempotent -- past mbox
months and the immutable git history are never re-fetched, only what
changed. The fetches are independent, so by default a failing one doesn't
stop the others: every fetch runs, the summary shows per-step status, and the
process exits non-zero if any failed. Use --fail-fast to stop at the first
failure instead.

The dbt build is the one child process (dbt is a CLI; it runs with the venv's
`dbt` next to this interpreter). It runs by default, but ONLY if every
selected fetch succeeded -- so the marts are never rebuilt on half-refreshed
data. Pass --no-build to refresh the sources without rebuilding.

    ./venv/bin/pg-refresh                 # all three fetches, then dbt build
    ./venv/bin/pg-refresh --no-build      # refresh the sources only
    ./venv/bin/pg-refresh --only cve      # re-scrape CVEs, then dbt build
    ./venv/bin/pg-refresh --skip mail     # everything but the slow mbox sync
    ./venv/bin/pg-refresh --list          # show the steps and exit
    ./venv/bin/pg-refresh --dry-run       # show what would run without running it

`pg-refresh` is the console script the editable install puts in ./venv/bin
(pyproject.toml); the dbt build is launched from that same bin directory, next
to the interpreter running this.

Note: the dbt build takes a read-write lock on transform.duckdb (repo root), so
quit any interactive DuckDB/Harlequin session first (see CLAUDE.md), or pass
--no-build.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
import traceback
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from pg_analysis import mailing_list_sync, postgres_clone, scrape_cve_severity
from pg_analysis.paths import DBT_PROJECT_DIR

VENV_BIN = Path(sys.executable).parent  # ./venv/bin when run via the repo venv


@dataclass(frozen=True)
class Step:
    key: str
    name: str  # the function, as printed in listings and --dry-run
    run: Callable[[], None]
    label: str


STEPS: tuple[Step, ...] = (
    Step(
        "git",
        "postgres_clone.main()",
        postgres_clone.main,
        "Sync the postgres.git clone (commits, tags, release-notes SGML)",
    ),
    Step(
        "mail",
        "mailing_list_sync.main()",
        mailing_list_sync.main,
        "Sync pgsql-bugs + pgsql-hackers mbox archives (needs .env creds)",
    ),
    Step(
        "cve",
        "scrape_cve_severity.main()",
        scrape_cve_severity.main,
        "Scrape published CVSS severity ratings for PostgreSQL CVEs",
    ),
)
STEP_KEYS = tuple(s.key for s in STEPS)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Refresh all external data sources (git clone, mboxes, CVE severities).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Steps: " + "  ".join(f"{s.key} = {s.name}" for s in STEPS),
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
        help="print what each selected step would run without running it",
    )
    return parser.parse_args(argv)


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


def exit_status(code: object) -> int:
    """Map a SystemExit's code to a process-style status, the way the
    interpreter would at exit: None -> 0, an int as-is, anything else (a
    message string) -> 1."""
    if code is None:
        return 0
    if isinstance(code, int):
        return code
    print(str(code), file=sys.stderr)
    return 1


def call_step(step: Step, *, dry_run: bool) -> int:
    """Call a fetch step's function in this process. Returns 0 on success, else
    a non-zero status: the SystemExit code when the step exited itself, 1 when
    it raised (the traceback is printed to stderr)."""
    print(f"    -> {step.name}", flush=True)
    if dry_run:
        return 0
    try:
        step.run()
    except SystemExit as exc:  # the scripts' own failure signal (raise SystemExit(1) / sys.exit(msg))
        status = exit_status(exc.code)
    except Exception:  # any other failure: report it and let the remaining steps run
        traceback.print_exc()
        status = 1
    else:
        status = 0
    sys.stdout.flush()
    sys.stderr.flush()
    return status


def run(cmd: list[str], *, cwd: Path, dry_run: bool) -> int:
    """Run a child command, streaming its output live. Returns its exit code."""
    printable = " ".join(cmd)
    print(f"    $ {printable}", flush=True)
    if dry_run:
        return 0
    # No capture: child stdout/stderr stream straight through so the
    # long-running build shows progress in real time.
    return subprocess.run(cmd, cwd=cwd).returncode


def banner(text: str) -> None:
    line = "=" * 78
    print(f"\n{line}\n{text}\n{line}", flush=True)


Result = tuple[str, int, float]  # (step key, status, elapsed seconds)


def print_step_list(steps: list[Step], *, with_build: bool) -> None:
    print("Steps in run order:")
    for s in steps:
        print(f"  {s.key:5} {s.name:28} {s.label}")
    if with_build:
        print(f"  {'build':5} {'dbt deps + dbt build':28} Derive the marts (dbt project = repo root)")


def run_fetches(steps: list[Step], args: argparse.Namespace) -> tuple[list[Result], bool]:
    """Run each fetch step; return its results and whether --fail-fast aborted."""
    results: list[Result] = []
    for step in steps:
        banner(f"[{step.key}] {step.label}")
        started = time.monotonic()
        status = call_step(step, dry_run=args.dry_run)
        results.append((step.key, status, time.monotonic() - started))
        if status != 0 and args.fail_fast:
            print(f"\n[{step.key}] failed (status {status}); stopping (--fail-fast).", file=sys.stderr)
            return results, True
    return results, False


def run_build(prior: list[Result], *, dry_run: bool) -> Result | None:
    """Run `dbt deps` + `dbt build`, but only if every prior fetch succeeded."""
    fetch_failed = [k for k, status, _ in prior if status != 0]
    if fetch_failed:
        print(f"\nskipping dbt build: fetch step(s) failed ({', '.join(fetch_failed)}).", file=sys.stderr)
        return None
    dbt = str(VENV_BIN / "dbt")
    banner("[build] dbt deps + dbt build (the dbt project at the repo root)")
    started = time.monotonic()
    code = run([dbt, "deps"], cwd=DBT_PROJECT_DIR, dry_run=dry_run)
    if code == 0:
        code = run([dbt, "build"], cwd=DBT_PROJECT_DIR, dry_run=dry_run)
    return ("build", code, time.monotonic() - started)


def print_summary(results: list[Result], *, aborted: bool) -> bool:
    banner("Summary")
    ok = True
    for key, status, elapsed in results:
        label = "ok" if status == 0 else f"FAILED (status {status})"
        ok = ok and status == 0
        print(f"  {key:6} {label:22} {elapsed:6.1f}s")
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
