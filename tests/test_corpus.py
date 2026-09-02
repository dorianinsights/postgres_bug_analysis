# pyright: strict
"""Corpus invariants — the DERIVATIONS, not the current pin.

FIRST_MAJOR anchors the floor; the upper bound is discovered from the repo
(sources.git.released_majors), so there is no LAST_MAJOR / MAJORS / STABLE_BRANCHES
to assert here. These check only what must hold for ANY FIRST_MAJOR: the >= 10
floor and the history-floor derivation. Deliberately NO hardcoded (14..18) /
"2020-10-01" snapshot — that would break on a legitimate, reviewed FIRST_MAJOR
change.
"""

from datetime import UTC, datetime

import corpus


def test_first_major_is_a_modern_single_part_release() -> None:
    # PG 10+ only — 9.x used two-part majors the scrapers don't support, and
    # corpus.py documents 10 as the floor for FIRST_MAJOR.
    assert corpus.FIRST_MAJOR >= 10


def test_git_history_since_is_october_before_first_major_release() -> None:
    # Major N ships in year 2007 + N; the floor is Oct 1 of the year BEFORE
    # FIRST_MAJOR's release year. Derived from FIRST_MAJOR so it tracks any pin.
    since = corpus.GIT_HISTORY_SINCE
    assert since == f"{2006 + corpus.FIRST_MAJOR}-10-01"


def test_git_history_since_is_a_valid_first_of_month_date() -> None:
    floor = datetime.strptime(corpus.GIT_HISTORY_SINCE, "%Y-%m-%d").replace(tzinfo=UTC)
    assert floor.day == 1
