# pyright: strict
"""Read postgres.git directly for the raw_git Python models.

The git side of the pipeline has no CSV landing layer: the clone at
../.cache/postgres.git IS the raw store (content-addressed and immutable),
and the models/raw_git/ Python models call these readers at build time, so
every git-derived table shares one consistent snapshot of the clone.

Everything here is pure extraction — verbatim strings, full fidelity —
exactly what scrape_git_commits.py used to write to CSVs. Typing and
filtering stay in the SQL staging models. Paths assume dbt runs from
transform/ (the same convention as the ../data source locations), and
corpus.py is imported from the directory above.
"""

import re
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path.cwd().parent))
from corpus import GIT_HISTORY_SINCE, STABLE_BRANCHES

CACHE = Path.cwd().parent / ".cache" / "postgres.git"
BRANCHES = [*STABLE_BRANCHES, "master"]

# The history floor as an exact instant. Two git date gotchas make the bare
# GIT_HISTORY_SINCE date nondeterministic: approxidate fills a missing
# time-of-day with the CURRENT wall-clock time (so the cutoff moved with
# every build — observed as boundary commits flapping in/out of
# git_commits_enriched.csv), and plain --since is a walk-termination
# heuristic rather than a filter. Pin midnight UTC and use
# --since-as-filter (git >= 2.37), which walks everything and filters by
# date exactly.
SINCE_FILTER = f"--since-as-filter={GIT_HISTORY_SINCE}T00:00:00Z"


class CommitRecord(NamedTuple):
    "One commit on one branch, verbatim (full ISO timestamp, full body)."

    branch: str
    hash: str
    commit_ts: str
    author_name: str
    author_email: str
    committer_name: str
    committer_email: str
    subject: str
    body: str


class CommitFileRecord(NamedTuple):
    "One file touched by one commit (git log --numstat; '-' for binary)."

    hash: str
    file_path: str
    lines_added: str
    lines_deleted: str


class TagRecord(NamedTuple):
    "One REL_1x_* ref (release tag or BETA/RC prerelease), verbatim."

    tag: str
    tag_ts: str


def git(*args: str) -> str:
    if not CACHE.is_dir():
        msg = f"postgres clone not found at {CACHE} — run ../postgres_clone.py first"
        raise RuntimeError(msg)
    return subprocess.run(["git", "-C", str(CACHE), *args], capture_output=True, text=True, check=True).stdout


def branch_range(branch: str) -> str:
    # Stable branches: only commits after the major's .0 release (the
    # backpatch stream) — the shared pre-branch history belongs to master.
    m = re.match(r"REL_(\d+)_STABLE$", branch)
    return f"REL_{m.group(1)}_0..{branch}" if m else branch


def commit_records() -> list[CommitRecord]:
    """One record per commit per branch since the corpus history floor."""
    records: list[CommitRecord] = []
    for branch in BRANCHES:
        log = git(
            "log",
            SINCE_FILTER,
            # author (%an/%ae) and committer (%cn/%ce) identities land before
            # the subject; the multi-line body stays last so it can't be
            # confused with a delimited field.
            "--format=%H%x00%cI%x00%an%x00%ae%x00%cn%x00%ce%x00%s%x00%b%x01",
            branch_range(branch),
        )
        for record in log.split("\x01"):
            record = record.strip("\n")
            if not record.strip():
                continue
            fields = (record.split("\x00") + [""] * 8)[:8]
            commit_hash, date_iso, author_name, author_email = fields[:4]
            committer_name, committer_email, subject, body = fields[4:]
            records.append(
                CommitRecord(
                    branch=branch,
                    hash=commit_hash,
                    commit_ts=date_iso,
                    author_name=author_name,
                    author_email=author_email,
                    committer_name=committer_name,
                    committer_email=committer_email,
                    subject=subject,
                    body=body.strip("\n"),
                )
            )
    return records


def commit_file_records() -> list[CommitFileRecord]:
    """One record per (commit, file) from git log --numstat."""
    records: list[CommitFileRecord] = []
    for branch in BRANCHES:
        log = git("log", SINCE_FILTER, "--format=%x01%H", "--numstat", branch_range(branch))
        commit_hash = ""
        for line in log.splitlines():
            if line.startswith("\x01"):
                commit_hash = line[1:]
            elif line.strip():
                added, _, rest = line.partition("\t")
                deleted, _, path = rest.partition("\t")
                records.append(
                    CommitFileRecord(hash=commit_hash, file_path=path, lines_added=added, lines_deleted=deleted)
                )
    return records


def tag_records() -> list[TagRecord]:
    """One record per REL_1x_* ref (release tags AND BETA/RC prereleases)."""
    out = git("for-each-ref", "--format=%(refname:short)%09%(creatordate:iso-strict)", "refs/tags/REL_1[5-9]_*")
    records: list[TagRecord] = []
    for line in sorted(out.splitlines()):
        tag, _, tag_ts = line.partition("\t")
        records.append(TagRecord(tag=tag, tag_ts=tag_ts))
    return records
