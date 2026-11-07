# pyright: strict
"""Read postgres.git directly for the raw_git Python models.

The git side of the pipeline has no CSV landing layer: the clone at
.cache/postgres.git IS the raw store (content-addressed and immutable),
and the models/raw_git/ Python models call these readers at build time, so
every git-derived table shares one consistent snapshot of the clone.

Everything here is extraction — verbatim strings, full fidelity. The one
derivation is the tree sizes' line counts and subsystem buckets, which need
each file's bytes and whole path, so they can't be done downstream. Typing
and filtering stay in the SQL staging models. Every path (the clone, the dbt
seeds) comes from pg_analysis.paths, so nothing here depends on the cwd.
"""

import csv
import multiprocessing as mp
import os
import re
import stat
import subprocess
from collections.abc import Callable, Iterator
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
    parent_hashes: str  # %P: the parents' hashes, space-separated ("" for a root commit)
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
            # the parents (%P), then author (%an/%ae) and committer (%cn/%ce)
            # identities land before the subject; the multi-line body stays
            # last so it can't be confused with a delimited field.
            "--format=%H%x00%P%x00%cI%x00%an%x00%ae%x00%cn%x00%ce%x00%s%x00%b%x01",
            commit_range(branch),
        )
        for record in log.split("\x01"):
            record = record.strip("\n")
            if not record.strip():
                continue
            fields = (record.split("\x00") + [""] * 9)[:9]
            commit_hash, parent_hashes, date_iso, author_name, author_email = fields[:5]
            committer_name, committer_email, subject, body = fields[5:]
            records.append(
                CommitRecord(
                    branch=branch,
                    hash=commit_hash,
                    parent_hashes=parent_hashes,
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


class TreeSizeRecord(NamedTuple):
    """The size of ONE (subsystem, extension) slice of the tree at one commit (a
    stock, not a flow). Long form: a commit has one row per (subsystem, extension)
    present, so the slices sum to the tree's total size. Which commits to measure
    (each stable branch's head at each week's end) is decided in the transform
    (int_branch_week_heads); this only measures them. The raw file extension is
    carried verbatim; stg_tree_sizes maps it to a file_class (file_class_rules) so
    a size chart can filter the generated classes (translations, test_fixtures)
    like the churn charts do. subsystem is the only classification kept here -- it
    needs each file's whole path, which the tree walk has and the aggregated
    record does not."""

    commit_hash: str
    subsystem: str  # the subsystem_rules bucket (single taxonomy; see _subsystem_of)
    extension: str  # the file's lower-cased extension (raw; classified in SQL)
    code_lines: str  # source lines in this slice's files
    file_cnt: str  # number of files in this slice


class SubsystemRule(NamedTuple):
    "One subsystem_rules seed row: the bucket a path matching `pattern` lands in."

    subsystem: str
    pattern: re.Pattern[str]


class AreaKey(NamedTuple):
    "One slice of a tree: its subsystem_rules bucket and raw file extension."

    subsystem: str
    extension: str


class AreaSize(NamedTuple):
    "One slice's size: its text lines and its files."

    code_lines: int
    file_cnt: int


def _subsystem_rules() -> list[SubsystemRule]:
    """The (subsystem, compiled-pattern) rules from the subsystem_rules seed, in
    match_order precedence. Read from the SAME seed the SQL side uses
    (int_commit_files), so the path -> subsystem taxonomy has one source of truth.
    Loaded lazily (not at import) so tests that import this module from any cwd
    don't need the seed on disk."""
    path = SEEDS_DIR / "subsystem_rules.csv"
    with path.open(encoding="utf-8") as handle:
        rows = [(int(r["match_order"]), r["subsystem"], re.compile(r["pattern"])) for r in csv.DictReader(handle)]
    rows.sort(key=lambda r: r[0])
    return [SubsystemRule(subsystem=subsystem, pattern=pattern) for _, subsystem, pattern in rows]


def _subsystem_of(path: str, rules: list[SubsystemRule]) -> str:
    "The first rule (by match_order) whose pattern matches the path; else 'other'."
    for rule in rules:
        if rule.pattern.search(path):
            return rule.subsystem
    return "other"


def _extension_of(path: str) -> str:
    "The path's lower-cased extension (after the last dot in the basename); '' if none."
    name = path.rpartition("/")[2]
    return name.rpartition(".")[2].lower() if "." in name else ""


# git's own binary test (buffer_is_binary): a NUL in a blob's first 8000 bytes.
_BINARY_PROBE_BYTES = 8000
# A raw tree entry ends in its object's binary SHA-1.
_OBJECT_ID_BYTES = 20


def _text_line_count(data: bytes) -> int:
    """A blob's lines as `git grep -I -c '^'` counts them, byte for byte (the C
    locale): its newlines, plus one for a last line with none. 0 for a binary
    blob (git's test: a NUL in the first 8000 bytes) or an empty one -- grep
    reports neither, so neither counts as a file."""
    if not data or b"\0" in data[:_BINARY_PROBE_BYTES]:
        return 0
    return data.count(b"\n") + (0 if data.endswith(b"\n") else 1)


def _tree_entries(data: bytes) -> Iterator[tuple[int, str, str]]:
    """(mode, name, object id) for each entry of a raw tree object, which is a
    run of `<octal mode> <name>\\0<binary object id>`."""
    pos = 0
    while pos < len(data):
        space = data.index(b" ", pos)
        nul = data.index(b"\0", space)
        mode = int(data[pos:space], 8)
        name = data[space + 1 : nul].decode("utf-8", "surrogateescape")
        object_id = data[nul + 1 : nul + 1 + _OBJECT_ID_BYTES].hex()
        yield mode, name, object_id
        pos = nul + 1 + _OBJECT_ID_BYTES


class _ObjectReader:
    """One long-running `git cat-file --batch`: an object's raw bytes by id."""

    def __init__(self) -> None:
        if not CLONE.is_dir():
            msg = f"postgres clone not found at {CLONE} — run pg-clone first"
            raise RuntimeError(msg)
        self._proc = subprocess.Popen(
            ["git", "-C", str(CLONE), "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE
        )

    def read(self, object_id: str) -> bytes:
        # request "<id>\n"; reply "<id> <type> <size>\n", the bytes, then "\n"
        stdin, stdout = self._proc.stdin, self._proc.stdout
        if stdin is None or stdout is None:
            msg = "git cat-file has no pipes"
            raise RuntimeError(msg)
        stdin.write(object_id.encode() + b"\n")
        stdin.flush()
        header = stdout.readline().split()
        if len(header) != len(("id", "type", "size")):
            msg = f"git cat-file could not read {object_id}: {b' '.join(header)!r}"
            raise RuntimeError(msg)
        data = stdout.read(int(header[2]))
        stdout.read(1)  # the trailing newline
        return data

    def close(self) -> None:
        if self._proc.stdin is not None:
            self._proc.stdin.close()
        self._proc.wait()


class _TreeSizer:
    """Each (subsystem, extension) slice's size (text lines, files) of the tree at
    a commit, read object by object and remembered: a subtree (by its path and
    id) and a blob (by its id) are measured once however many commits share them,
    which consecutive weekly heads mostly do. The whole tree is measured -- NO
    extension filter -- so every file type flows through the raw layer and the
    "what counts as codebase" decision lives downstream. Only regular files count
    (as `git grep` sees a tree): not symlinks, not submodules."""

    def __init__(self, read_object: Callable[[str], bytes], sub_rules: list[SubsystemRule]) -> None:
        self._read = read_object
        self._rules = sub_rules
        self._trees: dict[tuple[str, str], dict[AreaKey, AreaSize]] = {}
        self._blob_lines: dict[str, int] = {}

    def commit_sizes(self, commit_hash: str) -> dict[AreaKey, AreaSize]:
        # a commit object opens with "tree <id>"
        first_line = self._read(commit_hash).split(b"\n", 1)[0]
        return self._tree_sizes("", first_line.removeprefix(b"tree ").decode())

    def _tree_sizes(self, prefix: str, tree_id: str) -> dict[AreaKey, AreaSize]:
        cached = self._trees.get((prefix, tree_id))
        if cached is not None:
            return cached
        sizes: dict[AreaKey, AreaSize] = {}
        for mode, name, object_id in _tree_entries(self._read(tree_id)):
            path = prefix + name
            if stat.S_ISDIR(mode):
                for area, size in self._tree_sizes(path + "/", object_id).items():
                    _add_size(sizes, area, size)
            elif stat.S_ISREG(mode):
                lines = self._lines(object_id)
                if lines:
                    area = AreaKey(subsystem=_subsystem_of(path, self._rules), extension=_extension_of(path))
                    _add_size(sizes, area, AreaSize(code_lines=lines, file_cnt=1))
        self._trees[(prefix, tree_id)] = sizes
        return sizes

    def _lines(self, blob_id: str) -> int:
        lines = self._blob_lines.get(blob_id)
        if lines is None:
            lines = self._blob_lines[blob_id] = _text_line_count(self._read(blob_id))
        return lines


def _add_size(sizes: dict[AreaKey, AreaSize], area: AreaKey, size: AreaSize) -> None:
    prev = sizes.get(area, AreaSize(code_lines=0, file_cnt=0))
    sizes[area] = AreaSize(code_lines=prev.code_lines + size.code_lines, file_cnt=prev.file_cnt + size.file_cnt)


def tree_size_records(commit_hashes: list[str]) -> list[TreeSizeRecord]:
    """The tree size, by (subsystem, extension) slice, at each of `commit_hashes`,
    read through one `git cat-file --batch` with every subtree and blob measured
    once (_TreeSizer). Counts are git grep -I -c '^' byte for byte, with no
    locale in play. Output follows the input order."""
    if not commit_hashes:
        return []
    reader = _ObjectReader()
    try:
        sizer = _TreeSizer(reader.read, _subsystem_rules())
        return [
            TreeSizeRecord(
                commit_hash=commit_hash,
                subsystem=area.subsystem,
                extension=area.extension,
                code_lines=str(size.code_lines),
                file_cnt=str(size.file_cnt),
            )
            for commit_hash in commit_hashes
            for area, size in sizer.commit_sizes(commit_hash).items()
        ]
    finally:
        reader.close()


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
