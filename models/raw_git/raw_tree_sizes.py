# pyright: basic
"""Raw tree sizes, split by subsystem and file extension -- the text lines and
files in each (subsystem, extension) slice of the tree at each commit
int_branch_week_heads names (every stable branch's head at each week's end),
read straight from the postgres.git clone at build time with one `git grep -c`
per distinct commit, fanned out across a process pool. subsystem is classified
here (it needs the whole path); the extension is raw, mapped to a file_class in
stg_tree_sizes (file_class_rules) so classification stays in SQL.

The one raw model with an upstream ref: WHICH commits to measure (a branch's
head at a point in time) is a derivation over the commit history, so it lives
in the transform, and this model only measures them. Rebuilt in full every
run (~a minute of git grep), so no snapshot can go stale.
One row per (commit, subsystem, extension).
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.git import tree_size_records

_SCHEMA = pa.schema(
    [
        ("commit_hash", pa.string()),
        ("subsystem", pa.string()),
        ("extension", pa.string()),
        ("code_lines", pa.string()),
        ("file_cnt", pa.string()),
    ]
)


def model(dbt: Any, session: Any) -> pa.Table:
    heads = dbt.ref("int_branch_week_heads").project("commit_hash").distinct().fetchall()
    records = tree_size_records(sorted(str(row[0]) for row in heads))
    return pa.Table.from_pylist([record._asdict() for record in records], schema=_SCHEMA)
