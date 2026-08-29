#!/usr/bin/env python3
"""Extract PostgreSQL stable-branch commit history into local CSVs.

Maintains a metadata-only clone of postgres.git under .cache/ (treeless,
~140MB; first run clones, later runs fetch) and persists:

- data/raw/git_commits.csv  one row per commit per branch (REL_15..18_STABLE +
                        master) since SINCE: hash, full ISO committer
                        timestamp, subject, and full message body
- data/raw/git_tags.csv     every REL_1x_* ref (release tags AND
                        BETA/RC prereleases) with its full ISO creation
                        timestamp

Pure extraction: fields land raw verbatim and at full fidelity. All
derivations live downstream in the transform/ dbt project — plumbing and
AI-credit flags come from the subject/body there, release-tag filtering
and major/minor parsing from the tag name, day-truncation at the point
of use.

Raw-ish data only — cross-branch dedup and windowing live in the
transform/ dbt project and in the faces' SQL.
"""

import csv
import re
import subprocess
import sys
from pathlib import Path
from typing import TypedDict

from corpus import GIT_HISTORY_SINCE, STABLE_BRANCHES


class CommitRow(TypedDict):
    "One commit on one branch."

    branch: str
    hash: str
    commit_ts: str
    subject: str
    body: str


class TagRow(TypedDict):
    "One minor-release tag."

    tag: str
    tag_ts: str


REPO_URL = "https://github.com/postgres/postgres.git"
CACHE = Path(__file__).parent / ".cache" / "postgres.git"
DATA_DIR = Path(__file__).parent / "data" / "raw"
BRANCHES = [*STABLE_BRANCHES, "master"]
SINCE = GIT_HISTORY_SINCE


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(CACHE), *args], capture_output=True, text=True, check=True).stdout


def ensure_clone() -> None:
    if CACHE.exists():
        print("fetching latest commits...")
        subprocess.run(["git", "-C", str(CACHE), "fetch", "origin", "--quiet"], check=True)
    else:
        print(f"cloning {REPO_URL} (metadata only, one-time ~140MB)...")
        CACHE.parent.mkdir(exist_ok=True)
        subprocess.run(
            ["git", "clone", "--bare", "--filter=tree:0", REPO_URL, str(CACHE)],
            check=True,
        )


def branch_commits(branch: str) -> list[CommitRow]:
    # Stable branches: only commits after the major's .0 release (the
    # backpatch stream) — the shared pre-branch history belongs to master.
    m = re.match(r"REL_(\d+)_STABLE$", branch)
    rev_range = f"REL_{m.group(1)}_0..{branch}" if m else branch
    log = git(
        "log",
        f"--since={SINCE}",
        "--format=%H%x00%cI%x00%s%x00%b%x01",
        rev_range,
    )
    rows: list[CommitRow] = []
    for record in log.split("\x01"):
        record = record.strip("\n")
        if not record.strip():
            continue
        commit_hash, date_iso, subject, body = (record.split("\x00") + ["", "", ""])[:4]
        rows.append(
            CommitRow(
                branch=branch,
                hash=commit_hash,
                commit_ts=date_iso,
                subject=subject,
                body=body.strip("\n"),
            )
        )
    return rows


def tag_rows() -> list[TagRow]:
    out = git("for-each-ref", "--format=%(refname:short)%09%(creatordate:iso-strict)", "refs/tags/REL_1[5-9]_*")
    rows: list[TagRow] = []
    for line in out.splitlines():
        tag, _, tag_ts = line.partition("\t")
        rows.append(TagRow(tag=tag, tag_ts=tag_ts))
    rows.sort(key=lambda r: r["tag"])
    return rows


def main() -> None:
    ensure_clone()
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    commit_rows: list[CommitRow] = []
    for branch in BRANCHES:
        rows = branch_commits(branch)
        commit_rows.extend(rows)
        print(f"{branch:<15} {len(rows)} commits since {SINCE}")

    with open(DATA_DIR / "git_commits.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["branch", "hash", "commit_ts", "subject", "body"])
        writer.writeheader()
        writer.writerows(commit_rows)

    tags = tag_rows()
    with open(DATA_DIR / "git_tags.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["tag", "tag_ts"])
        writer.writeheader()
        writer.writerows(tags)
    print(f"\nWrote {len(commit_rows)} commit rows, {len(tags)} tags -> {DATA_DIR}/")


if __name__ == "__main__":
    sys.exit(main())
