# pyright: strict
"""Read postgres.git directly for the raw_git Python models.

The git side of the pipeline has no CSV landing layer: the clone at
../.cache/postgres.git IS the raw store (content-addressed and immutable),
and the models/raw_git/ Python models call these readers at build time, so
every git-derived table shares one consistent snapshot of the clone.

Everything here is pure extraction — verbatim strings, full fidelity —
exactly what scrape_git_commits.py used to write to CSVs. Typing and
filtering stay in the SQL staging models. Every path (the clone, the dbt
seeds) comes from pg_analysis.paths, so nothing here depends on the cwd.
"""

import csv
import multiprocessing as mp
import os
import re
import subprocess
from datetime import UTC, date, datetime, timedelta
from typing import NamedTuple

from pg_analysis.corpus import FIRST_MAJOR, HISTORY_FLOOR_TAG
from pg_analysis.paths import CLONE, SEEDS_DIR

# No date floor anywhere in the git side: every branch's corpus range is bounded
# by tag ancestry (branch_range / commit_range below), master included. A
# --since date was both redundant for the tag-bounded stable branches and wrong
# for master (it started months after FIRST_MAJOR's development began); tag
# ancestry is exact and moves with FIRST_MAJOR.


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
    if not CLONE.is_dir():
        msg = f"postgres clone not found at {CLONE} — run pg-clone first"
        raise RuntimeError(msg)
    return subprocess.run(["git", "-C", str(CLONE), *args], capture_output=True, text=True, check=True).stdout


def fork_point(branch: str) -> str:
    "The commit where a stable branch diverged from master (their merge-base)."
    return git("merge-base", "master", branch).strip()


def commit_range(branch: str) -> str:
    # The rev range whose commits belong to a branch -- ONE rule, tag ancestry:
    # a stable branch (released or in-progress alike) owns everything since it
    # forked off master (fork_point..branch: its pre-GA stabilization AND its
    # post-GA backpatch stream -- commit_version_records tells the two apart by
    # version, M.0 vs M.N); master owns everything since the previous major
    # branched off, i.e. since FIRST_MAJOR's development began
    # (HISTORY_FLOOR_TAG..master -- the previous major's GA tag contains all of
    # master up to that branch point and nothing after it). The shared
    # pre-fork history belongs to master, never to a branch.
    if re.match(r"REL_(\d+)_STABLE$", branch):
        return f"{fork_point(branch)}..{branch}"
    return f"{HISTORY_FLOOR_TAG}..{branch}" if branch == "master" else branch


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


def all_stable_branches() -> list[str]:
    "Released AND in-progress stable branches (the latter carries its beta stabilization)."
    return [f"REL_{major}_STABLE" for major in sorted(released_majors() + in_development_majors())]


def all_branches() -> list[str]:
    "Every stable branch (released + in-progress) plus master."
    return [*all_stable_branches(), "master"]


def tag_globs() -> list[str]:
    """One for-each-ref pattern per major with a stable branch (released AND
    in-progress -- the beta major's BETA/RC milestones live in its tags), so the
    tag readers track the repo."""
    return [f"refs/tags/REL_{major}_*" for major in sorted(released_majors() + in_development_majors())]


def commit_records() -> list[CommitRecord]:
    """One record per commit per branch over the branch's corpus range (commit_range):
    a stable branch since its fork (pre-GA stabilization + backpatches), master
    since the corpus floor."""
    records: list[CommitRecord] = []
    for branch in all_branches():
        log = git(
            "log",
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
    log = git("log", "--format=%x01%H", "--numstat", commit_range(branch))
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
class BranchSizeRecord(NamedTuple):
    """One weekly snapshot of ONE (subsystem, extension) slice of a stable
    branch's tree (a stock, not a flow). Long form: a week has one row per
    (subsystem, extension) present, so the slices sum to the branch's total size
    that week. The raw file extension is carried verbatim; stg_branch_size_weekly
    maps it to a file_class (file_class_rules) so a size chart can filter the
    generated classes (translations, test_fixtures) like the churn charts do.
    subsystem is the only classification kept here -- it needs the whole path,
    which the per-file grep output has and the aggregated record does not."""

    branch: str
    week_start: str  # ISO date of the week's Monday
    commit_hash: str  # branch HEAD as of that week's end
    subsystem: str  # the subsystem_rules bucket (single taxonomy; see _subsystem_of)
    extension: str  # the file's lower-cased extension (raw; classified in SQL)
    code_lines: str  # source lines in this slice's files
    file_cnt: str  # number of files in this slice


def _subsystem_rules() -> list[tuple[str, "re.Pattern[str]"]]:
    """The (subsystem, compiled-pattern) rules from the subsystem_rules seed, in
    match_order precedence. Read from the SAME seed the SQL side uses
    (int_fix_changes), so the path -> subsystem taxonomy has one source of truth.
    Loaded lazily (not at import) so tests that import this module from any cwd
    don't need the seed on disk."""
    path = SEEDS_DIR / "subsystem_rules.csv"
    with path.open(encoding="utf-8") as handle:
        rows = [(int(r["match_order"]), r["subsystem"], re.compile(r["pattern"])) for r in csv.DictReader(handle)]
    rows.sort(key=lambda r: r[0])
    return [(subsystem, pattern) for _, subsystem, pattern in rows]


def _subsystem_of(path: str, rules: list[tuple[str, "re.Pattern[str]"]]) -> str:
    "The first rule (by match_order) whose pattern matches the path; else 'other'."
    for subsystem, pattern in rules:
        if pattern.search(path):
            return subsystem
    return "other"


def _extension_of(path: str) -> str:
    "The path's lower-cased extension (after the last dot in the basename); '' if none."
    name = path.rpartition("/")[2]
    return name.rpartition(".")[2].lower() if "." in name else ""


def _major_eol(major: int) -> date:
    # PostgreSQL majors get ~5 years of support; major M's final minor lands
    # ~November of year 2012 + M. Caps the snapshot span once the corpus reaches
    # a since-retired major -- no point sampling a frozen branch past its EOL.
    return date(major + 2012, 11, 30)


def _tree_size_by_area(
    rev: str, sub_rules: list[tuple[str, "re.Pattern[str]"]]
) -> dict[tuple[str, str], tuple[int, int]]:
    """{(subsystem, extension): (line_cnt, file_cnt)} for the tree at `rev`.
    subsystem is classified here (it needs the whole path); the raw extension is
    carried for stg_branch_size_weekly to map to a file_class in SQL. The whole
    tree is measured -- NO extension filter -- so every file type flows through
    the raw layer and the "what counts as codebase" decision lives downstream. One
    `git grep -I -c '^'` emits `<rev>:<path>:<count>` per matched TEXT file; -I
    keeps binary files out, so no binary size is ever counted.
    """
    out = git("grep", "-I", "-c", "^", rev)
    sizes: dict[tuple[str, str], tuple[int, int]] = {}
    for line in out.splitlines():
        if not line:
            continue
        prefix, _, count = line.rpartition(":")
        path = prefix.partition(":")[2]  # strip the "<rev>:" prefix
        key = (_subsystem_of(path, sub_rules), _extension_of(path))
        code, files = sizes.get(key, (0, 0))
        sizes[key] = (code + int(count), files + 1)
    return sizes


def _branch_size_start(branch: str, major: int) -> date | None:
    """The first day of a stable branch's size curve. Released majors anchor at GA
    (REL_M_0); the in-progress major has no GA tag yet, so it anchors at its fork
    from master (the beta-1 branch point) -- the moment its tree became a distinct
    line. None when neither anchor resolves."""
    if git("tag", "-l", f"REL_{major}_0").strip():
        start_iso = git("log", "-1", "--format=%cI", f"REL_{major}_0").strip()
    else:
        fork = git("merge-base", "master", branch).strip()
        start_iso = git("log", "-1", "--format=%cI", fork).strip()
    return date.fromisoformat(start_iso[:10]) if start_iso else None


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
    sub_rules = _subsystem_rules()
    records: list[BranchSizeRecord] = []
    for branch in all_stable_branches():
        matched = re.match(r"REL_(\d+)_STABLE$", branch)
        if not matched:
            continue
        major = int(matched.group(1))
        start = _branch_size_start(branch, major)
        if start is None:
            continue
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
        sizes = {head: _tree_size_by_area(head, sub_rules) for head in set(week_head.values())}
        for week, head in week_head.items():
            for (subsystem, extension), (code, files) in sizes[head].items():
                records.append(
                    BranchSizeRecord(
                        branch=branch,
                        week_start=week.isoformat(),
                        commit_hash=head,
                        subsystem=subsystem,
                        extension=extension,
                        code_lines=str(code),
                        file_cnt=str(files),
                    )
                )
    return records


class CommitVersionRecord(NamedTuple):
    "One commit mapped to the version it first shipped in (or is developing), by git tag ancestry."

    branch: str
    commit_hash: str
    version: str


def _rev_list(rev_range: str) -> list[str]:
    return [commit_hash for commit_hash in git("rev-list", rev_range).splitlines() if commit_hash]


def commit_version_records() -> list[CommitVersionRecord]:
    """Every corpus commit that belongs to a version, by EXACT git tag ancestry --
    the single commit -> version mapping, trunk included:

    - A stable branch's pre-GA commits (fork_point..REL_M_0, or ..HEAD for the
      in-progress major with no GA tag yet) are M.0: the major's stabilization.
    - Its post-GA commits map to the minor they FIRST shipped in: for consecutive
      release tags REL_M_(N-1), REL_M_N, `git rev-list REL_M_(N-1)..REL_M_N` is
      exactly the commits reachable from REL_M_N but not REL_M_(N-1). No date
      windows, no wrap heuristic; out-of-band re-releases are ordinary tags.
      Commits after the branch's latest tag are unmapped (pending).
    - master's commits between two consecutive majors' fork points were
      developed FOR the later one: fork_point(M-1)..fork_point(M) is M.0 (for
      FIRST_MAJOR, the earlier fork is the corpus floor). Together with the
      branch's pre-GA segment that is precisely REL_(M-1)_0..REL_M_0, the
      per-major development set. master commits after the newest fork (the next,
      not-yet-branched major) are unmapped.

    Grain = (branch, commit_hash).
    """
    records: list[CommitVersionRecord] = []
    for branch in all_stable_branches():
        matched = re.match(r"REL_(\d+)_STABLE$", branch)
        if not matched:
            continue
        major = int(matched.group(1))
        ga_version = f"{major}.0"
        fork = fork_point(branch)
        # the previous major's fork point: where this major's master development began
        prev_fork = fork_point(f"REL_{major - 1}_STABLE")
        records.extend(
            CommitVersionRecord(branch="master", commit_hash=commit_hash, version=ga_version)
            for commit_hash in _rev_list(f"{prev_fork}..{fork}")
        )
        refs = git("for-each-ref", "--format=%(refname:short)", f"refs/tags/REL_{major}_*").splitlines()
        minors: list[tuple[int, str]] = []
        for ref in refs:
            tag_match = re.fullmatch(rf"REL_{major}_(\d+)", ref)
            if tag_match:
                minors.append((int(tag_match.group(1)), ref))
        minors.sort()
        # pre-GA stabilization on the branch: up to the GA tag, or all of it for
        # the in-progress major
        pre_ga_end = minors[0][1] if minors else branch
        records.extend(
            CommitVersionRecord(branch=branch, commit_hash=commit_hash, version=ga_version)
            for commit_hash in _rev_list(f"{fork}..{pre_ga_end}")
        )
        for (_, prev_tag), (minor, tag) in zip(minors, minors[1:], strict=False):
            version = f"{major}.{minor}"
            records.extend(
                CommitVersionRecord(branch=branch, commit_hash=commit_hash, version=version)
                for commit_hash in _rev_list(f"{prev_tag}..{tag}")
            )
    return records
