# pyright: strict
# pyright: reportPrivateUsage=false
# ^ test_file_records exercises a module-private worker helper.
"""sources.git: the branch-range rule and the git-output parsers.

The parsers are driven by a fake git() so nothing touches a real clone: each
reader just splits git's delimited output, and that splitting is what we pin.
"""

import re

import pytest

import corpus
import sources.git as gitmod
from sources.git import commit_range

# git log --format uses \x00 between fields and \x01 to terminate each record.
_COMMIT_LOG = (
    "abc123\x002023-02-01T10:00:00-05:00\x00Alice\x00alice@x\x00"
    "Carol\x00carol@x\x00Fix bug in planner\x00Body line one.\x01\n"
    # second commit has an EMPTY body — exercises the field-padding
    "def456\x002023-01-31T09:00:00-05:00\x00Bob\x00bob@x\x00Bob\x00bob@x\x00Doc fix\x00\x01\n"
)

# git for-each-ref, tab-separated, given out of order to check the sort.
_TAG_LOG = "REL_16_0\t2023-09-14T00:00:00+00:00\nREL_15_0\t2022-10-13T00:00:00+00:00\n"

# git log --numstat with the \x01<hash> commit markers; "-" for a binary file.
_NUMSTAT_LOG = "\x01abc123\n10\t2\tsrc/foo.c\n-\t-\tbin/data\n\x01def456\n5\t0\tdoc/bar.sgml\n"


def _patch_git(monkeypatch: pytest.MonkeyPatch, output: str) -> None:
    def fake_git(*_args: str) -> str:
        return output

    monkeypatch.setattr(gitmod, "git", fake_git)


def test_commit_range_scopes_stable_branches_from_their_fork(monkeypatch: pytest.MonkeyPatch) -> None:
    # A stable branch owns everything since it forked off master (merge-base),
    # released or in-progress alike -- works for any major, including ones
    # outside today's window (e.g. an extended timeline).
    _patch_git(monkeypatch, "f0rkp01nt\n")
    assert commit_range("REL_15_STABLE") == "f0rkp01nt..REL_15_STABLE"
    assert commit_range("REL_11_STABLE") == "f0rkp01nt..REL_11_STABLE"


def test_commit_range_bounds_master_by_the_corpus_floor_tag() -> None:
    # master has no fork of its own: its corpus range starts at the previous
    # major's GA tag (corpus.HISTORY_FLOOR_TAG), i.e. FIRST_MAJOR's branch point.
    assert commit_range("master") == f"{corpus.HISTORY_FLOOR_TAG}..master"


def test_commit_range_leaves_non_matches_untouched() -> None:
    assert commit_range("REL_15_STABLEX") == "REL_15_STABLEX"  # anchored, no partial match


def test_commit_records_split_fields_and_pad_empty_body(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_git(monkeypatch, _COMMIT_LOG)
    monkeypatch.setattr(gitmod, "all_branches", lambda: ["master"])
    records = gitmod.commit_records()
    assert [r.hash for r in records] == ["abc123", "def456"]
    first = records[0]
    assert first.branch == "master"
    assert first.commit_ts == "2023-02-01T10:00:00-05:00"
    assert (first.author_name, first.author_email) == ("Alice", "alice@x")
    assert (first.committer_name, first.committer_email) == ("Carol", "carol@x")
    assert first.subject == "Fix bug in planner"
    assert first.body == "Body line one."
    assert records[1].body == ""  # empty body survives the field padding


def test_tag_records_partition_and_sort(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_git(monkeypatch, _TAG_LOG)
    records = gitmod.tag_records()
    assert [r.tag for r in records] == ["REL_15_0", "REL_16_0"]  # sorted
    assert records[0].tag_ts == "2022-10-13T00:00:00+00:00"


def test_file_records_parse_numstat_and_binary_markers(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_git(monkeypatch, _NUMSTAT_LOG)
    records = gitmod._file_records_for_branch("master")
    assert [(r.hash, r.file_path, r.lines_added, r.lines_deleted) for r in records] == [
        ("abc123", "src/foo.c", "10", "2"),
        ("abc123", "bin/data", "-", "-"),
        ("def456", "doc/bar.sgml", "5", "0"),
    ]


# subsystem rules as (subsystem, compiled-pattern) in match_order precedence,
# mirroring a slice of the subsystem_rules seed — enough to pin the precedence
# and the 'other' fallback without reading the seed from disk.
_RULES = [
    ("tests", re.compile(r"^src/test/")),
    ("docs", re.compile(r"^doc/")),
    ("client_tools", re.compile(r"^src/bin/|^src/interfaces/")),
    ("core_server", re.compile(r"^src/backend/|^src/include/")),
]


def test_subsystem_of_first_match_wins_and_falls_back_to_other() -> None:
    # src/test/ beats the later core_server rule even though neither src/backend
    # nor src/include matches here — precedence is by match_order, not specificity.
    assert gitmod._subsystem_of("src/test/regress/foo.sql", _RULES) == "tests"
    assert gitmod._subsystem_of("src/backend/optimizer/plan.c", _RULES) == "core_server"
    assert gitmod._subsystem_of("src/bin/psql/command.c", _RULES) == "client_tools"
    assert gitmod._subsystem_of("doc/src/sgml/ref.sgml", _RULES) == "docs"
    # a source file no rule matches lands in the catch-all bucket
    assert gitmod._subsystem_of("Makefile.shlib", _RULES) == "other"


def test_extension_of_reads_the_last_dot_and_lowercases() -> None:
    assert gitmod._extension_of("src/backend/executor/a.C") == "c"
    assert gitmod._extension_of("src/backend/po/fr.po") == "po"
    assert gitmod._extension_of("src/test/regress/expected/b.out") == "out"
    # a dot in a parent directory does not count; a name with no dot has no extension
    assert gitmod._extension_of("src/tools/x.d/Makefile") == ""
    assert gitmod._extension_of("README") == ""


def test_tree_size_by_area_buckets_by_subsystem_and_raw_extension(monkeypatch: pytest.MonkeyPatch) -> None:
    # git grep -I -c '^' emits "<rev>:<path>:<count>" per file; the paths carry
    # colons only in the rev/path split, which rpartition/partition handle.
    # file_class is NOT decided here -- the raw extension is carried for SQL to map.
    grep_out = (
        "HEAD:src/backend/executor/a.c:100\n"
        "HEAD:src/include/x.h:20\n"
        "HEAD:src/test/regress/b.sql:40\n"
        "HEAD:doc/src/sgml/c.sgml:5\n"
        "HEAD:src/backend/po/fr.po:1000\n"  # a translation catalog — carried by extension
    )
    _patch_git(monkeypatch, grep_out)
    sizes = gitmod._tree_size_by_area("HEAD", _RULES)
    assert sizes[("core_server", "c")] == (100, 1)  # a.c
    assert sizes[("core_server", "h")] == (20, 1)  # x.h -- distinct extension, same subsystem
    assert sizes[("tests", "sql")] == (40, 1)
    assert sizes[("docs", "sgml")] == (5, 1)
    assert sizes[("core_server", "po")] == (1000, 1)  # the .po, kept separate for SQL to classify
    assert sum(code for code, _ in sizes.values()) == 1165  # slices sum to the tree
