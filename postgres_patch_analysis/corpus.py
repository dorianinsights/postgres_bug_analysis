#!/usr/bin/env python3
"""The analysis corpus: which PostgreSQL majors this project studies.

Single source of truth shared by all three scrapers, so the release-notes
datasets and the git-commit dataset can never be built from different
corpora (the transform/ dbt models join them; a mismatch would corrupt the
derived data silently). Deliberately plain constants, versioned in git: changing the
corpus changes what every dataset and chart MEANS, so it should be a
reviewed, dated commit — not an environment variable or a command-line flag.

To extend the corpus back in time, lower FIRST_MAJOR (>= 10: PG 9.x and
earlier used two-part majors like "9.6", which the scrapers' version
handling doesn't support — and the GIT_HISTORY_SINCE derivation below also
assumes the one-major-per-year era that began with PG 10). LAST_MAJOR is
pinned rather than auto-discovered on purpose — the corpus should not
silently grow when a new major releases.
"""

FIRST_MAJOR = 15
LAST_MAJOR = 18
MAJORS: tuple[int, ...] = tuple(range(FIRST_MAJOR, LAST_MAJOR + 1))

# The stable branches carrying the corpus majors' backpatch streams.
STABLE_BRANCHES: tuple[str, ...] = tuple(f"REL_{m}_STABLE" for m in MAJORS)

# Commit-history floor for scrape_git_commits.py. PostgreSQL has shipped one
# major per year since PG 10: major N was released in year 2007 + N. The
# floor is Oct 1 of the year BEFORE FIRST_MAJOR's release — comfortably
# ahead of its ~June branch point, so the master series covers the whole
# corpus window. Exact for every allowed FIRST_MAJOR, since past release
# years are immutable.
GIT_HISTORY_SINCE = f"{2006 + FIRST_MAJOR}-10-01"
