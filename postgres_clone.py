#!/usr/bin/env python3
"""Sync the local postgres.git clone (full bare clone under .cache/, ~800MB).

This is the raw store for the entire git side of the pipeline — there is no
CSV landing layer for git data. The transform's models/raw_git/ Python
models (via transform/gitsource.py) and scrape_release_notes_sgml.py both
read this clone directly, so a `dbt build` after one sync sees a single
consistent snapshot.

First run clones (a treeless clone left by earlier pipeline versions is
replaced automatically); later runs fetch.
"""

import shutil
import subprocess
import sys
from pathlib import Path

REPO_URL = "https://github.com/postgres/postgres.git"
CACHE = Path(__file__).parent / ".cache" / "postgres.git"


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(CACHE), *args], capture_output=True, text=True, check=True).stdout


def partial_clone_filter() -> str:
    proc = subprocess.run(
        ["git", "-C", str(CACHE), "config", "remote.origin.partialclonefilter"],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.stdout.strip()


def ensure_clone() -> None:
    if CACHE.exists() and partial_clone_filter():
        # A treeless clone can't serve --numstat without lazy-fetching
        # per diff; replace it with a full clone.
        print("replacing partial clone with a full clone...")
        shutil.rmtree(CACHE)
    if CACHE.exists():
        print("fetching latest commits...")
        subprocess.run(["git", "-C", str(CACHE), "fetch", "origin", "--quiet"], check=True)
    else:
        print(f"cloning {REPO_URL} (full bare clone, one-time ~800MB)...")
        CACHE.parent.mkdir(exist_ok=True)
        subprocess.run(["git", "clone", "--bare", REPO_URL, str(CACHE)], check=True)


def main() -> None:
    ensure_clone()
    print(f"clone ready at {CACHE}")


if __name__ == "__main__":
    sys.exit(main())
