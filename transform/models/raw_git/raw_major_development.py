# pyright: basic
"""Raw per-major feature-development activity by git tag ancestry, read from the
postgres.git clone at build time (commits reachable from REL_M_0 -- or the branch
HEAD for the in-progress major -- but not REL_(M-1)_0; see
sources.git.major_dev_records). One row per major at/above the floor that has a
stable branch: the released majors AND the in-progress one (in beta). Cheap.
"""

import sys
from pathlib import Path
from typing import Any

import pyarrow as pa

sys.path.insert(0, str(Path.cwd()))
from sources.git import major_dev_records

_SCHEMA = pa.schema(
    [
        ("major", pa.string()),
        ("dev_status", pa.string()),
        ("latest_milestone", pa.string()),
        ("dev_commit_cnt", pa.string()),
        ("first_dev_commit_hash", pa.string()),
        ("first_dev_commit_ts", pa.string()),
        ("last_dev_commit_hash", pa.string()),
        ("last_dev_commit_ts", pa.string()),
    ]
)


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in major_dev_records()], schema=_SCHEMA)
