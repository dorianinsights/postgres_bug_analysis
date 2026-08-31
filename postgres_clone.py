#!/usr/bin/env python3
"""Sync the local postgres.git clone (full bare clone under .cache/, ~800MB).

This is the raw store for the entire git side of the pipeline — there is no
CSV landing layer for git data. The transform's models/raw_git/ Python models
(via transform/gitsource.py) and scrape_release_notes_sgml.py both read this
clone directly, so a `dbt build` after one sync sees a single consistent
snapshot.

First run clones; later runs fetch. The fetch passes explicit heads+tags
refspecs on purpose: the pipeline reads both branch heads (refs/heads/master +
REL_1x_STABLE — gitsource commits) AND tags (refs/tags/REL_1x_* — gitsource
release/prerelease records), and a plain `git fetch origin` on a bare clone
(which configures no fetch refspec of its own) writes only FETCH_HEAD, leaving
every ref the pipeline reads frozen at clone time. Heads and tags only —
deliberately NOT `refs/*` (that would also pull GitHub's ~hundreds of
refs/pull/* PR refs, which nothing here reads).
"""

import subprocess
import sys
from pathlib import Path

REPO_URL = "https://github.com/postgres/postgres.git"
CACHE = Path(__file__).parent / ".cache" / "postgres.git"
REFSPECS = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]


def git(*args: str) -> str:
    """Run git inside the clone and return stdout. Used by the release-notes
    SGML scraper to `git show` release-NN.sgml straight out of the clone."""
    return subprocess.run(["git", "-C", str(CACHE), *args], capture_output=True, text=True, check=True).stdout


def ensure_clone() -> None:
    if CACHE.exists():
        print("fetching latest commits and tags...")
        subprocess.run(
            ["git", "-C", str(CACHE), "fetch", "--prune", "origin", *REFSPECS],
            check=True,
        )
    else:
        print(f"cloning {REPO_URL} (full bare clone, one-time ~800MB)...")
        CACHE.parent.mkdir(exist_ok=True)
        subprocess.run(["git", "clone", "--bare", REPO_URL, str(CACHE)], check=True)


def main() -> None:
    ensure_clone()
    print(f"clone ready at {CACHE}")


if __name__ == "__main__":
    sys.exit(main())
