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

import multiprocessing as mp
import os
import re
import subprocess
import sys
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path.cwd().parent))
from corpus import GIT_HISTORY_SINCE, MAJORS, STABLE_BRANCHES

CACHE = Path.cwd().parent / ".cache" / "postgres.git"
BRANCHES = [*STABLE_BRANCHES, "master"]
# One for-each-ref pattern per corpus major, so the tag readers track the corpus
# (a REL_1[5-9]_* glob silently dropped a corpus that reaches below 15 or past 19).
TAG_GLOBS = tuple(f"refs/tags/REL_{major}_*" for major in MAJORS)

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


def _file_records_for_branch(branch: str) -> list[CommitFileRecord]:
    """One record per (commit, file) for one branch. Module-level so a worker
    process can run it."""
    records: list[CommitFileRecord] = []
    log = git("log", SINCE_FILTER, "--format=%x01%H", "--numstat", branch_range(branch))
    commit_hash = ""
    for line in log.splitlines():
        if line.startswith("\x01"):
            commit_hash = line[1:]
        elif line.strip():
            added, _, rest = line.partition("\t")
            deleted, _, path = rest.partition("\t")
            records.append(CommitFileRecord(hash=commit_hash, file_path=path, lines_added=added, lines_deleted=deleted))
    return records


def commit_file_records() -> list[CommitFileRecord]:
    """One record per (commit, file) from git log --numstat, one branch per
    worker: each branch is an independent git-log parse, and this is the
    slowest git-side model. Spawn (the parent is multithreaded via DuckDB, so
    fork is unsafe); `map` preserves branch order, so output is byte-identical.
    Leave one core free for the user.
    """
    workers = min(len(BRANCHES), max((os.cpu_count() or 2) - 1, 1))
    with mp.Pool(processes=workers) as pool:
        per_branch: list[list[CommitFileRecord]] = pool.map(_file_records_for_branch, BRANCHES)
    return [record for branch_records in per_branch for record in branch_records]


def tag_records() -> list[TagRecord]:
    """One record per REL_1x_* ref (release tags AND BETA/RC prereleases)."""
    out = git("for-each-ref", "--format=%(refname:short)%09%(creatordate:iso-strict)", *TAG_GLOBS)
    records: list[TagRecord] = []
    for line in sorted(out.splitlines()):
        tag, _, tag_ts = line.partition("\t")
        records.append(TagRecord(tag=tag, tag_ts=tag_ts))
    return records


# Source file types counted as the codebase (the tree is otherwise mostly docs,
# test data, and build scaffolding). Verbatim line totals; typing in staging.
CODE_GLOBS = ("*.c", "*.h", "*.y", "*.l", "*.pl", "*.pm", "*.py", "*.sql", "*.sgml", "*.pgc")


class BranchSizeRecord(NamedTuple):
    "One weekly snapshot of a stable branch's tree size (a stock, not a flow)."

    branch: str
    week_start: str  # ISO date of the week's Monday
    commit_hash: str  # branch HEAD as of that week's end
    code_lines: str  # total source lines across CODE_GLOBS
    doc_lines: str  # the .sgml documentation subset
    test_lines: str  # the src/test/ subset
    file_cnt: str  # number of source files


def _major_eol(major: int) -> date:
    # PostgreSQL majors get ~5 years of support; major M's final minor lands
    # ~November of year 2012 + M. Caps the snapshot span once the corpus reaches
    # a since-retired major -- no point sampling a frozen branch past its EOL.
    return date(major + 2012, 11, 30)


def _tree_size(rev: str) -> tuple[int, int, int, int]:
    """(code_lines, doc_lines, test_lines, file_cnt) for the tree at `rev`.

    One `git grep -c '^'` emits `<rev>:<path>:<count>` per matched file, so the
    total, the file count, and any path-based split all come from a single grep.
    """
    out = git("grep", "-I", "-c", "^", rev, "--", *CODE_GLOBS)
    code = doc = test = files = 0
    for line in out.splitlines():
        if not line:
            continue
        prefix, _, count = line.rpartition(":")
        lines = int(count)
        path = prefix.partition(":")[2]  # strip the "<rev>:" prefix
        code += lines
        files += 1
        if path.endswith(".sgml"):
            doc += lines
        elif path.startswith("src/test/"):
            test += lines
    return code, doc, test, files


def branch_size_weekly_records(
    known: frozenset[tuple[str, str]] = frozenset(),
) -> list[BranchSizeRecord]:
    """Weekly (branch, week) codebase-size snapshots for every stable branch,
    from the branch's .0 release to min(today, its ~5-year EOL). A STOCK -- the
    state of the tree -- sampled at each week's end. Only DISTINCT resolved
    commits are grepped (quiet weeks share a HEAD), and any (branch, week) in
    `known` is skipped without grepping: the incremental model passes what it
    already has, so a normal build measures only the new weeks. Past weeks are
    immutable, so caching them is safe.
    """
    today = datetime.now(UTC).date()
    records: list[BranchSizeRecord] = []
    for branch in STABLE_BRANCHES:
        matched = re.match(r"REL_(\d+)_STABLE$", branch)
        if not matched:
            continue
        major = int(matched.group(1))
        start_iso = git("log", "-1", "--format=%cI", f"REL_{major}_0").strip()
        if not start_iso:
            continue
        start = date.fromisoformat(start_iso[:10])
        end = min(today, _major_eol(major))
        # weekly Mondays covering [branch .0 release, end]
        monday = start - timedelta(days=start.weekday())
        todo: list[date] = []
        while monday <= end:
            if (branch, monday.isoformat()) not in known:
                todo.append(monday)
            monday += timedelta(days=7)
        # resolve each new week's HEAD (as of the week's end); grep each distinct
        # commit once
        week_head: dict[date, str] = {}
        for week in todo:
            asof = (week + timedelta(days=7)).isoformat()
            head = git("rev-list", "-1", f"--before={asof}T00:00:00Z", branch).strip()
            if head:
                week_head[week] = head
        sizes = {head: _tree_size(head) for head in set(week_head.values())}
        for week, head in week_head.items():
            code, doc, test, files = sizes[head]
            records.append(
                BranchSizeRecord(
                    branch=branch,
                    week_start=week.isoformat(),
                    commit_hash=head,
                    code_lines=str(code),
                    doc_lines=str(doc),
                    test_lines=str(test),
                    file_cnt=str(files),
                )
            )
    return records
