#!/usr/bin/env python3
"""The analysis corpus: which PostgreSQL majors this project studies.

FIRST_MAJOR anchors the FLOOR (we don't want to trawl all of PostgreSQL's history
back to the 1990s). The UPPER bound is NOT pinned -- it is discovered from the git
repo at build time (sources.git.released_majors: every major >= FIRST_MAJOR with a
shipped REL_M_0 GA tag), so a newly released major flows into every dataset and
dashboard automatically, with no yearly edit. The in-progress major (branched and
in beta, no GA yet) is picked up separately by the major-development models.

The history floor is NOT a date. FIRST_MAJOR's development began where the
previous major branched off master, and git already knows that point exactly:
HISTORY_FLOOR_TAG (the previous major's GA tag) bounds master by tag ancestry --
`REL_(FIRST_MAJOR-1)_0..master` is precisely the master history since that branch
point -- the same rule the stable branches (REL_M_0..) and the per-major
development counts already use. The mailing-list archive is addressed by calendar
month, so the one consumer that needs a day (mailing_list_sync.py) derives it from
the clone with history_floor() rather than from a second, hand-maintained date.

To extend the corpus back in time, lower FIRST_MAJOR (>= 11: the floor tag is the
PREVIOUS major's GA, and PG 9.x tags are named REL9_6_0, not REL_9_6_0; the
scrapers' version handling also assumes the one-major-per-year era that began
with PG 10). That IS a reviewed, dated commit.
"""

import subprocess
from datetime import UTC, date, datetime

from pg_analysis import paths

FIRST_MAJOR = 14

# Lowest FIRST_MAJOR the tag-naming assumption below supports (see the docstring).
MIN_FIRST_MAJOR = 11

if FIRST_MAJOR < MIN_FIRST_MAJOR:
    msg = f"FIRST_MAJOR must be >= {MIN_FIRST_MAJOR} (got {FIRST_MAJOR}); PG 9.x tags are not REL_M_N-shaped"
    raise ValueError(msg)

# The tag-ancestry lower bound of the git history: the previous major's GA tag.
# master's corpus range is `HISTORY_FLOOR_TAG..master`; the previous major's
# stable branch marks the branch point that history_floor() dates.
HISTORY_FLOOR_TAG = f"REL_{FIRST_MAJOR - 1}_0"
HISTORY_FLOOR_BRANCH = f"REL_{FIRST_MAJOR - 1}_STABLE"

CLONE = paths.CLONE  # re-exported: the clone this module reads its floor from


def history_floor() -> date:
    """The corpus history floor as a UTC calendar day: the day master and the
    previous major's stable branch diverged (their merge-base), i.e. the day
    FIRST_MAJOR's development began. Read from the clone (run postgres_clone.py
    first), so it moves with FIRST_MAJOR and can never disagree with the git
    ranges. Only the mailing-list sync needs a day -- the mbox archive is fetched
    by calendar month, so it starts at this day's month."""
    if not CLONE.is_dir():
        msg = f"postgres clone not found at {CLONE} -- run pg-clone first"
        raise RuntimeError(msg)
    branch_point = subprocess.run(
        ["git", "-C", str(CLONE), "merge-base", "master", HISTORY_FLOOR_BRANCH],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    committed = subprocess.run(
        ["git", "-C", str(CLONE), "log", "-1", "--format=%cI", branch_point],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    return datetime.fromisoformat(committed).astimezone(UTC).date()
