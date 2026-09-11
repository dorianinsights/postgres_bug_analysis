# pyright: basic
"""Raw weekly codebase-size snapshots per stable branch, split by subsystem and
file extension — the source lines in each (subsystem, extension) slice of the
tree at each week's end, read straight from the postgres.git clone at build time
(one `git grep -c` per distinct branch HEAD). subsystem is classified here (it
needs the whole path); the extension is raw, mapped to a file_class in
stg_branch_size_weekly (file_class_rules) so classification stays in SQL.

INCREMENTAL: a past (branch, week) snapshot is immutable, so an incremental run
measures only the weeks it does not already hold — it passes the stored
(branch, week) keys to the reader, which skips them without grepping. A full
build (or --full-refresh) backfills every week from each branch's .0 release,
which is minutes of git grep. One row per (branch, week, subsystem, extension).
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.git import branch_size_weekly_records

_SCHEMA = pa.schema(
    [
        ("branch", pa.string()),
        ("week_start", pa.string()),
        ("commit_hash", pa.string()),
        ("subsystem", pa.string()),
        ("extension", pa.string()),
        ("code_lines", pa.string()),
        ("file_cnt", pa.string()),
    ]
)


def model(dbt: Any, session: Any) -> pa.Table:
    dbt.config(materialized="incremental", unique_key=["branch", "week_start", "subsystem", "extension"])
    known: frozenset[tuple[str, str]] = frozenset()
    if dbt.is_incremental:
        # Skip only COMPLETE past weeks (immutable). The current in-progress week
        # is left out of `known` so it is re-measured every build and the curve's
        # last point stays current as commits land. A whole (branch, week) is
        # grepped or skipped as a unit, so the skip set is DISTINCT (branch, week).
        rows = session.execute(
            f"SELECT DISTINCT branch, week_start FROM {dbt.this} "  # noqa: S608
            "WHERE CAST(week_start AS DATE) < DATE_TRUNC('week', CURRENT_DATE)"
        ).fetchall()
        known = frozenset((str(r[0]), str(r[1])) for r in rows)
    records = branch_size_weekly_records(known)
    return pa.Table.from_pylist([record._asdict() for record in records], schema=_SCHEMA)
