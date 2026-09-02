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
from corpus import FIRST_MAJOR, GIT_HISTORY_SINCE

CACHE = Path.cwd().parent / ".cache" / "postgres.git"

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
    # Released stable branch: only commits after the major's .0 release (the
    # backpatch stream) — the shared pre-branch history belongs to master. A pure
    # transform (in-progress branches, which have no .0 yet, go through
    # commit_range instead).
    m = re.match(r"REL_(\d+)_STABLE$", branch)
    return f"REL_{m.group(1)}_0..{branch}" if m else branch


def commit_range(branch: str) -> str:
    # The rev range whose commits belong to a branch, git-aware: a released stable
    # branch uses branch_range (REL_M_0..); the in-progress stable branch (no .0
    # tag) uses its post-fork commits (merge-base with master .. HEAD), i.e. its
    # beta stabilization; master is everything.
    m = re.match(r"REL_(\d+)_STABLE$", branch)
    if m and not git("tag", "-l", f"REL_{m.group(1)}_0").strip():
        return f"{git('merge-base', 'master', branch).strip()}..{branch}"
    return branch_range(branch)


def released_majors() -> list[int]:
    """Majors at/above FIRST_MAJOR that have shipped a GA tag (REL_M_0) — the
    released corpus, DISCOVERED from the repo. FIRST_MAJOR anchors the floor (we
    don't want all of PostgreSQL's history); the upper bound follows the repo, so
    a newly released major joins automatically with no LAST_MAJOR to bump.
    """
    majors = [
        int(m.group(1))
        for tag in git("tag", "-l", "REL_*_0").splitlines()
        if (m := re.fullmatch(r"REL_(\d+)_0", tag)) and int(m.group(1)) >= FIRST_MAJOR
    ]
    return sorted(majors)


def in_development_majors() -> list[int]:
    """Majors >= FIRST_MAJOR that have a stable branch but no GA tag yet -- the
    in-progress major (e.g. PG19 in beta). Discovered from the repo alongside the
    released ones, so it needs no configuration."""
    released = set(released_majors())
    majors = [
        int(m.group(1))
        for branch in git("for-each-ref", "--format=%(refname:short)", "refs/heads/REL_*_STABLE").splitlines()
        if (m := re.fullmatch(r"REL_(\d+)_STABLE", branch))
        and int(m.group(1)) >= FIRST_MAJOR
        and int(m.group(1)) not in released
    ]
    return sorted(majors)


def stable_branches() -> list[str]:
    "The released majors' stable branches (the backpatch streams)."
    return [f"REL_{major}_STABLE" for major in released_majors()]


def all_stable_branches() -> list[str]:
    "Released AND in-progress stable branches (the latter carries its beta stabilization)."
    return [f"REL_{major}_STABLE" for major in sorted(released_majors() + in_development_majors())]


def all_branches() -> list[str]:
    "Every stable branch (released + in-progress) plus master."
    return [*all_stable_branches(), "master"]


def tag_globs() -> list[str]:
    "One for-each-ref pattern per released major, so the tag readers track the repo."
    return [f"refs/tags/REL_{major}_*" for major in released_majors()]


def commit_records() -> list[CommitRecord]:
    """One record per commit per branch since the corpus history floor."""
    records: list[CommitRecord] = []
    for branch in all_branches():
        log = git(
            "log",
            SINCE_FILTER,
            # author (%an/%ae) and committer (%cn/%ce) identities land before
            # the subject; the multi-line body stays last so it can't be
            # confused with a delimited field.
            "--format=%H%x00%cI%x00%an%x00%ae%x00%cn%x00%ce%x00%s%x00%b%x01",
            commit_range(branch),
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
    log = git("log", SINCE_FILTER, "--format=%x01%H", "--numstat", commit_range(branch))
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
    branches = all_branches()
    workers = min(len(branches), max((os.cpu_count() or 2) - 1, 1))
    with mp.Pool(processes=workers) as pool:
        per_branch: list[list[CommitFileRecord]] = pool.map(_file_records_for_branch, branches)
    return [record for branch_records in per_branch for record in branch_records]


def tag_records() -> list[TagRecord]:
    """One record per REL_1x_* ref (release tags AND BETA/RC prereleases)."""
    out = git("for-each-ref", "--format=%(refname:short)%09%(creatordate:iso-strict)", *tag_globs())
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
    from the branch's .0 release (or, for the in-progress major, its fork from
    master) to min(today, its ~5-year EOL). A STOCK -- the
    state of the tree -- sampled at each week's end. Only DISTINCT resolved
    commits are grepped (quiet weeks share a HEAD), and any (branch, week) in
    `known` is skipped without grepping: the incremental model passes what it
    already has, so a normal build measures only the new weeks. Past weeks are
    immutable, so caching them is safe.
    """
    today = datetime.now(UTC).date()
    records: list[BranchSizeRecord] = []
    for branch in all_stable_branches():
        matched = re.match(r"REL_(\d+)_STABLE$", branch)
        if not matched:
            continue
        major = int(matched.group(1))
        # released majors anchor the size curve at GA (REL_M_0); the in-progress
        # major has no GA tag yet, so anchor at its fork from master (the beta-1
        # branch point) -- the moment its tree became a distinct line.
        if git("tag", "-l", f"REL_{major}_0").strip():
            start_iso = git("log", "-1", "--format=%cI", f"REL_{major}_0").strip()
        else:
            fork = git("merge-base", "master", branch).strip()
            start_iso = git("log", "-1", "--format=%cI", fork).strip()
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


class CommitVersionRecord(NamedTuple):
    "One commit mapped to the minor it shipped in, by git tag ancestry."

    branch: str
    commit_hash: str
    version: str


def commit_version_records() -> list[CommitVersionRecord]:
    """Each stable-branch commit mapped to the minor it FIRST shipped in, by EXACT
    git tag ancestry: for consecutive release tags REL_M_(N-1), REL_M_N on a
    branch, `git rev-list REL_M_(N-1)..REL_M_N` is exactly the commits reachable
    from REL_M_N but not REL_M_(N-1) -- i.e. the ones that shipped in REL_M_N. No
    date windows, no wrap heuristic; out-of-band re-releases are ordinary tags.
    master carries no release tags; open-cycle commits (after the latest tag, not
    yet released) are unmapped. For the in-progress major (a stable branch with no
    minor tags yet), all of its post-fork stabilization commits (commit_range) map
    to the upcoming M.0. Grain = (branch, commit_hash).
    """
    records: list[CommitVersionRecord] = []
    for branch in all_stable_branches():
        matched = re.match(r"REL_(\d+)_STABLE$", branch)
        if not matched:
            continue
        major = int(matched.group(1))
        refs = git("for-each-ref", "--format=%(refname:short)", f"refs/tags/REL_{major}_*").splitlines()
        minors: list[tuple[int, str]] = []
        for ref in refs:
            tag_match = re.fullmatch(rf"REL_{major}_(\d+)", ref)
            if tag_match:
                minors.append((int(tag_match.group(1)), ref))
        minors.sort()
        if not minors:
            # in-progress major (no released minor tags): its beta-stabilization
            # commits all belong to the upcoming M.0.
            records.extend(
                CommitVersionRecord(branch=branch, commit_hash=commit_hash, version=f"{major}.0")
                for commit_hash in git("rev-list", commit_range(branch)).splitlines()
                if commit_hash
            )
            continue
        for (_, prev_tag), (minor, tag) in zip(minors, minors[1:], strict=False):
            version = f"{major}.{minor}"
            records.extend(
                CommitVersionRecord(branch=branch, commit_hash=commit_hash, version=version)
                for commit_hash in git("rev-list", f"{prev_tag}..{tag}").splitlines()
                if commit_hash
            )
    return records


class MajorDevRecord(NamedTuple):
    "One major's feature-development activity, by tag ancestry."

    major: str
    dev_status: str  # 'released' | 'beta'
    latest_milestone: str  # 'GA' | 'BETA3' | 'RC1' | ...
    dev_commit_cnt: str
    first_dev_commit_hash: str
    first_dev_commit_ts: str
    last_dev_commit_hash: str
    last_dev_commit_ts: str


def _latest_prerelease(major: int) -> str:
    """Newest BETA/RC milestone tag for a major (e.g. 'BETA3'), or 'pre-beta'."""
    refs = git(
        "for-each-ref", "--sort=-creatordate", "--format=%(refname:short)", f"refs/tags/REL_{major}_*"
    ).splitlines()
    for ref in refs:
        pre = re.fullmatch(rf"REL_{major}_((?:BETA|RC)\d+)", ref)
        if pre:
            return pre.group(1)
    return "pre-beta"


def major_dev_records() -> list[MajorDevRecord]:
    """Each major's feature development by git tag ancestry: the commits reachable
    from its GA tag REL_M_0 but not the previous major's GA REL_(M-1)_0 -- i.e.
    everything developed FOR major M. For the in-progress major (a REL_M_STABLE
    branch exists but no REL_M_0 yet -- e.g. PG19 in beta) the range runs to the
    branch HEAD, status is 'beta', and latest_milestone is its newest BETA/RC.
    Covers every major with a stable branch at/above the floor. Grain = major.
    """
    tags = set(git("tag", "-l", "REL_*").splitlines())
    branches = set(git("for-each-ref", "--format=%(refname:short)", "refs/heads/*").splitlines())
    # every major with a stable branch at or above the floor -- released AND the
    # in-progress one (REL_M_STABLE but no REL_M_0 yet). Discovered from the repo,
    # so a new major is picked up with no LAST_MAJOR to bump.
    stable_majors = sorted(
        int(bm.group(1))
        for br in branches
        if (bm := re.fullmatch(r"REL_(\d+)_STABLE", br)) and int(bm.group(1)) >= FIRST_MAJOR
    )
    records: list[MajorDevRecord] = []
    for major in stable_majors:
        prev = f"REL_{major - 1}_0"
        if prev not in tags:
            continue
        if f"REL_{major}_0" in tags:
            end, status, milestone = f"REL_{major}_0", "released", "GA"
        elif f"REL_{major}_STABLE" in branches:
            end, status, milestone = f"REL_{major}_STABLE", "beta", _latest_prerelease(major)
        else:
            continue
        commits = [ln for ln in git("log", "--format=%H%x00%cI", f"{prev}..{end}").splitlines() if ln]
        if not commits:
            continue
        last_hash, _, last_ts = commits[0].partition("\x00")
        first_hash, _, first_ts = commits[-1].partition("\x00")
        records.append(
            MajorDevRecord(
                major=str(major),
                dev_status=status,
                latest_milestone=milestone,
                dev_commit_cnt=str(len(commits)),
                first_dev_commit_hash=first_hash,
                first_dev_commit_ts=first_ts,
                last_dev_commit_hash=last_hash,
                last_dev_commit_ts=last_ts,
            )
        )
    return records
