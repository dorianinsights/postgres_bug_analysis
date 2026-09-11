# pyright: strict
"""Corpus invariants — the DERIVATIONS, not the current pin.

FIRST_MAJOR anchors the floor; the upper bound is discovered from the repo
(sources.git.released_majors), so there is no LAST_MAJOR / MAJORS / STABLE_BRANCHES
to assert here. These check only what must hold for ANY FIRST_MAJOR: the
MIN_FIRST_MAJOR floor and the history-floor derivation (a tag, not a date; the
one calendar day is read from the clone). Deliberately NO hardcoded (14..18) /
"REL_13_0" snapshot — that would break on a legitimate, reviewed FIRST_MAJOR
change.
"""

import pytest

from pg_analysis import corpus


def test_first_major_is_at_least_the_supported_floor() -> None:
    # The floor tag is the PREVIOUS major's GA, and PG 9.x tags are named
    # REL9_6_0 rather than REL_9_6_0, so the derivation needs FIRST_MAJOR >= 11.
    assert corpus.MIN_FIRST_MAJOR == 11
    assert corpus.FIRST_MAJOR >= corpus.MIN_FIRST_MAJOR


def test_history_floor_tag_is_previous_major_ga() -> None:
    # master's corpus range is HISTORY_FLOOR_TAG..master: the previous major's GA
    # tag contains all of master up to that major's branch point, so the range
    # is exactly FIRST_MAJOR's development onward. Derived from FIRST_MAJOR.
    assert f"REL_{corpus.FIRST_MAJOR - 1}_0" == corpus.HISTORY_FLOOR_TAG
    assert f"REL_{corpus.FIRST_MAJOR - 1}_STABLE" == corpus.HISTORY_FLOOR_BRANCH


@pytest.mark.skipif(not corpus.CLONE.is_dir(), reason="needs the postgres clone (postgres_clone.py)")
def test_history_floor_is_the_previous_majors_branch_point() -> None:
    # Major N ships in year 2007 + N and branches off master around June of the
    # year before, so the floor day (where master and the previous major's
    # stable branch diverged) falls in mid-year of 2006 + FIRST_MAJOR.
    floor = corpus.history_floor()
    assert floor.year == 2006 + corpus.FIRST_MAJOR
    assert 5 <= floor.month <= 8
