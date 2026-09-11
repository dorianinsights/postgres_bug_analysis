#!/usr/bin/env python3
"""Sync the local postgres.git clone (full bare clone under .cache/, ~800MB).

This is the raw store for the entire git side of the pipeline — there is no
CSV landing layer for git data. The transform's models/raw_git/ Python models
read this clone directly at build time -- commits/tags via pg_analysis.sources.git
and the release-notes SGML via pg_analysis.sources.sgml -- so a `dbt build` after
one sync sees a single consistent snapshot.

First run clones; later runs fetch. The fetch passes explicit heads+tags
refspecs on purpose: the pipeline reads both branch heads (refs/heads/master +
REL_1x_STABLE — sources.git commits) AND tags (refs/tags/REL_1x_* — sources.git
release/prerelease records), and a plain `git fetch origin` on a bare clone
(which configures no fetch refspec of its own) writes only FETCH_HEAD, leaving
every ref the pipeline reads frozen at clone time. Heads and tags only —
deliberately NOT `refs/*` (that would also pull GitHub's ~hundreds of
refs/pull/* PR refs, which nothing here reads).
"""

import subprocess
import sys

from pg_analysis.paths import CLONE

REPO_URL = "https://github.com/postgres/postgres.git"
REFSPECS = ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]


def ensure_clone() -> None:
    if CLONE.exists():
        print("fetching latest commits and tags...")
        subprocess.run(
            ["git", "-C", str(CLONE), "fetch", "--prune", "origin", *REFSPECS],
            check=True,
        )
    else:
        print(f"cloning {REPO_URL} (full bare clone, one-time ~800MB)...")
        CLONE.parent.mkdir(exist_ok=True)
        subprocess.run(["git", "clone", "--bare", REPO_URL, str(CLONE)], check=True)


def main() -> None:
    ensure_clone()
    print(f"clone ready at {CLONE}")


if __name__ == "__main__":
    sys.exit(main())
