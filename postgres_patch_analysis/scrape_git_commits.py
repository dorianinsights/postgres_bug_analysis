#!/usr/bin/env python3
"""Extract PostgreSQL stable-branch commit history into local CSVs.

Maintains a metadata-only clone of postgres.git under .cache/ (treeless,
~140MB; first run clones, later runs fetch) and persists:

- data/git_commits.csv  one row per commit per branch (REL_15..18_STABLE +
                        master) since SINCE: hash, date, subject, plumbing
                        flag, and any AI-tool credit line found in the body
- data/git_tags.csv     every REL_1x_y minor-release tag with its date
                        (tag dates are the wrap moments that bound release
                        cycles)

Raw-ish data only — cross-branch dedup and windowing live in
build_datasets.py and in the faces' SQL.
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
    commit_date: str
    subject: str
    is_plumbing: int
    ai_credit: str


class TagRow(TypedDict):
    "One minor-release tag."

    tag: str
    major: int
    minor: int
    date: str


REPO_URL = "https://github.com/postgres/postgres.git"
CACHE = Path(__file__).parent / ".cache" / "postgres.git"
DATA_DIR = Path(__file__).parent / "data"
BRANCHES = [*STABLE_BRANCHES, "master"]
SINCE = GIT_HISTORY_SINCE

# Release plumbing: not fixes, excluded downstream by the is_plumbing flag.
PLUMBING = re.compile(
    r"^(Stamp |Translation updates|Update time zone data|Update plpgsql\.po"
    r"|First-draft release notes|Release notes for|Update release notes"
    r"|Last-minute updates for release notes|Re-pgindent|pgindent )",
    re.IGNORECASE,
)

# Explicit AI-tool credits in commit messages (fuzzers tracked separately in
# the full-history analysis; here we keep the LLM signal only).
AI_PATTERN = re.compile(
    r"\b(Claude( Code)?|Anthropic|ChatGPT|GPT-[45]|OpenAI|Copilot|Big Sleep|large language model|LLM)\b",
    re.IGNORECASE,
)


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


def ai_credit_line(subject: str, body: str) -> str:
    """The first line of the commit message crediting an AI tool, or ''."""
    match = AI_PATTERN.search(subject + "\n" + body)
    if not match:
        return ""
    for line in (subject + "\n" + body).splitlines():
        if AI_PATTERN.search(line):
            return line.strip()[:200]
    return match.group(0)


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
                commit_date=date_iso[:10],
                subject=subject,
                is_plumbing=int(bool(PLUMBING.match(subject))),
                ai_credit=ai_credit_line(subject, body),
            )
        )
    return rows


def tag_rows() -> list[TagRow]:
    out = git("for-each-ref", "--format=%(refname:short)%09%(creatordate:short)", "refs/tags/REL_1[5-9]_*")
    rows: list[TagRow] = []
    for line in out.splitlines():
        tag, _, date = line.partition("\t")
        m = re.match(r"REL_(\d+)_(\d+)$", tag)
        if not m:  # skip BETA/RC tags
            continue
        rows.append(TagRow(tag=tag, major=int(m.group(1)), minor=int(m.group(2)), date=date))
    rows.sort(key=lambda r: (r["major"], r["minor"]))
    return rows


def main() -> None:
    ensure_clone()
    DATA_DIR.mkdir(exist_ok=True)

    commit_rows: list[CommitRow] = []
    for branch in BRANCHES:
        rows = branch_commits(branch)
        commit_rows.extend(rows)
        print(f"{branch:<15} {len(rows)} commits since {SINCE}")

    with open(DATA_DIR / "git_commits.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["branch", "hash", "commit_date", "subject", "is_plumbing", "ai_credit"])
        writer.writeheader()
        writer.writerows(commit_rows)

    tags = tag_rows()
    with open(DATA_DIR / "git_tags.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["tag", "major", "minor", "date"])
        writer.writeheader()
        writer.writerows(tags)
    print(f"\nWrote {len(commit_rows)} commit rows, {len(tags)} tags -> {DATA_DIR}/")


if __name__ == "__main__":
    sys.exit(main())
