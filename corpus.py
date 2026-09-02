#!/usr/bin/env python3
"""The analysis corpus: which PostgreSQL majors this project studies.

FIRST_MAJOR anchors the FLOOR (we don't want to trawl all of PostgreSQL's history
back to the 1990s). The UPPER bound is NOT pinned -- it is discovered from the git
repo at build time (sources.git.released_majors: every major >= FIRST_MAJOR with a
shipped REL_M_0 GA tag), so a newly released major flows into every dataset and
dashboard automatically, with no yearly edit. The in-progress major (branched and
in beta, no GA yet) is picked up separately by the major-development models.

To extend the corpus back in time, lower FIRST_MAJOR (>= 10: PG 9.x and earlier
used two-part majors like "9.6", which the scrapers' version handling doesn't
support -- and the GIT_HISTORY_SINCE derivation below also assumes the
one-major-per-year era that began with PG 10). That IS a reviewed, dated commit.
"""

FIRST_MAJOR = 14

# Commit-history floor for the git scrape. PostgreSQL has shipped one major per
# year since PG 10: major N was released in year 2007 + N. The floor is Oct 1 of
# the year BEFORE FIRST_MAJOR's release -- comfortably ahead of its ~June branch
# point, so the master series covers the whole corpus window. Exact for every
# allowed FIRST_MAJOR, since past release years are immutable.
GIT_HISTORY_SINCE = f"{2006 + FIRST_MAJOR}-10-01"
