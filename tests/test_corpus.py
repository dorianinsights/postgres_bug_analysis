# pyright: strict
"""Corpus invariants — the DERIVATIONS, not the current pin.

These assert the relationships that must hold at ANY corpus (MAJORS spans
FIRST..LAST, the stable branches and the history floor follow from them), so
extending the corpus (lowering FIRST_MAJOR, bumping LAST_MAJOR) is a one-line
corpus.py edit that needs no test changes. Deliberately NO hardcoded
(15, 16, 17, 18) / "2021-10-01" snapshot — that would break on a legitimate,
reviewed corpus change.
"""

from datetime import UTC, datetime

import corpus


def test_majors_span_first_through_last() -> None:
    majors = corpus.MAJORS
    assert corpus.FIRST_MAJOR <= corpus.LAST_MAJOR
    assert majors == tuple(range(corpus.FIRST_MAJOR, corpus.LAST_MAJOR + 1))


def test_majors_are_modern_single_part_releases() -> None:
    # PG 10+ only — 9.x used two-part majors the scrapers don't support, and
    # corpus.py documents 10 as the floor for FIRST_MAJOR.
    assert all(major >= 10 for major in corpus.MAJORS)


def test_stable_branches_match_majors() -> None:
    branches = corpus.STABLE_BRANCHES
    assert branches == tuple(f"REL_{major}_STABLE" for major in corpus.MAJORS)


def test_git_history_since_is_october_before_first_major_release() -> None:
    # Major N ships in year 2007 + N; the floor is Oct 1 of the year BEFORE
    # FIRST_MAJOR's release year. Derived from FIRST_MAJOR so it tracks any pin.
    since = corpus.GIT_HISTORY_SINCE
    assert since == f"{2006 + corpus.FIRST_MAJOR}-10-01"


def test_git_history_since_is_a_valid_first_of_month_date() -> None:
    floor = datetime.strptime(corpus.GIT_HISTORY_SINCE, "%Y-%m-%d").replace(tzinfo=UTC)
    assert floor.day == 1
