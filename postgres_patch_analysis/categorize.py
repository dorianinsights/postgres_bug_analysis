#!/usr/bin/env python3
"""Fix-category taxonomy and classifier for changelog items.

This module IS the categorization methodology: keyword-rule buckets applied
per item, first match wins, in this precedence —

1. Any CVE id on the item      -> "Security (CVE)"
2. Any HARDENING pattern       -> "Security hardening (no CVE)"
3. First RULES bucket to match -> that bucket
4. Nothing matched             -> "Other functionality"

RULES is an ordered list because the order is semantic (an item mentioning
both a crash and the planner is a crash fix). Patterns are matched
case-insensitively against the item's FULL text, not just its summary.
Boundary items land in one bucket by rule, not judgment — change with care,
and rerun build_datasets.py afterwards.
"""

import re

# Uncredited security hardening (checked only when the item carries no CVE).
HARDENING = [
    r"memory[- ]safety",
    r"buffer (overflow|overrun|over-?read)",
    r"out-of-bounds",
    r"\binjection\b",
    r"\buntrusted\b",
    r"prevent access to other sessions",
    r"privilege escalation",
    r"unauthorized",
    r"defend against",
]

# (bucket, keyword regexes) — first match wins; CVE / hardening checked first.
RULES: list[tuple[str, list[str]]] = [
    (
        "Crash & corruption",
        [
            r"\bcrash",
            r"assertion",
            r"corrupt",
            r"data loss",
            r"\bhang\b|\bhangs\b|\bhung\b",
            r"deadlock",
            r"segfault|segmentation",
            r"infinite loop|endless loop",
            r"memory leak|leak of|leaks\b",
            r"stack overflow",
            r"double free|use-after-free",
            r"race condition",
            r"\bPANIC\b",
            r"failure to detect|lost\b.*\b(rows|data|tuples)",
        ],
    ),
    (
        "Wrong results & planner",
        [
            r"incorrect (result|output|answer|value|count|calculation|rounding|comparison|matching|evaluation)",
            r"wrong (result|output|answer|value|count|plan|order|rows|data)",
            r"miscalculat|misestimat|mis-estimat",
            r"produce[sd]? (the )?wrong",
            r"give[sn]? (the )?wrong",
            r"return[sed]* (the )?(wrong|incorrect)",
            r"join removal",
            r"partition pruning",
            r"\bplanner\b",
            r"\boptimizer\b",
            r"equivalence",
            r"selectivity",
        ],
    ),
    (
        "Replication & recovery",
        [
            r"replicat",
            r"\bWAL\b|write-ahead",
            r"standby",
            r"logical decoding",
            r"recovery",
            r"checkpoint",
            r"archiv",
            r"walsender|walreceiver",
            r"subscriber|subscription|publisher|publication",
            r"two-phase|prepared transaction",
            r"\bslot\b|replication slot",
            r"hot standby|point-in-time",
            r"pg_rewind|pg_basebackup|pg_waldump|pg_receivewal|pg_verifybackup",
        ],
    ),
    (
        "Client tools",
        [
            r"\bpsql\b",
            r"pg_dump|pg_restore|pg_dumpall",
            r"pg_upgrade",
            r"pgbench",
            r"libpq",
            r"\becpg\b|\bECPG\b",
            r"pg_ctl|initdb|pg_checksums|pg_resetwal|pg_controldata|pg_amcheck|pg_isready",
            r"vacuumdb|reindexdb|clusterdb|createdb|dropdb|createuser|dropuser",
        ],
    ),
    (
        "Extensions & contrib",
        [
            r"postgres_fdw|file_fdw|dblink",
            r"pgcrypto|pg_stat_statements|pg_trgm|pg_prewarm|pg_visibility|pg_walinspect",
            r"\bcontrib\b",
            r"btree_gist|btree_gin|ltree|hstore|citext|intarray|isn\b|seg\b|cube\b",
            r"amcheck|pageinspect|pgstattuple|pg_freespacemap|pg_buffercache",
            r"sepgsql|passwordcheck|auto_explain|pg_surgery|adminpack|earthdistance|tablefunc",
            r"\bPL/Perl\b|plperl|\bPL/Python\b|plpython|\bPL/Tcl\b|pltcl",
        ],
    ),
    (
        "Performance",
        [
            r"performance",
            r"\bslow\b|slowness|slowdown",
            r"speed up|speedup",
            r"inefficien",
            r"excessive (time|memory|cpu)",
            r"O\(N",
        ],
    ),
    (
        "Build & platform",
        [
            r"\bbuild\b|\bbuilding\b|compil|\bmeson\b|configure script|makefile|pgxs",
            r"MSVC|MinGW|mingw|Visual Studio",
            r"OpenSSL",
            r"\bWindows\b|\bmacOS\b|\bSolaris\b|\bAIX\b|\bCygwin\b|illumos|NetBSD|OpenBSD|FreeBSD",
            r"\bARM\b|\bLLVM\b|\bgcc\b|\bclang\b",
            r"\bICU\b|locale|collation version",
            r"\bJIT\b",
        ],
    ),
]

CATEGORY_ORDER = [
    "Security (CVE)",
    "Security hardening (no CVE)",
    *[bucket for bucket, _ in RULES],
    "Other functionality",
]


def categorize(full_text: str, cves: str) -> str:
    if cves:
        return "Security (CVE)"
    for pattern in HARDENING:
        if re.search(pattern, full_text, re.IGNORECASE):
            return "Security hardening (no CVE)"
    for bucket, patterns in RULES:
        for pattern in patterns:
            if re.search(pattern, full_text, re.IGNORECASE):
                return bucket
    return "Other functionality"
