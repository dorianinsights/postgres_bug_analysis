# pyright: basic
"""Raw commit -> version mapping by EXACT git tag ancestry, read from the
postgres.git clone at build time (see sources.git.commit_version_records): a
shipped minor M.N for a stable branch's backpatch stream, or M.0 for a major's
development -- master between consecutive fork points plus the branch's pre-GA
stabilization. No date windows. Pending commits (after a branch's latest tag)
and master after the newest fork are absent. Cheap (~one rev-list per tag), so
a full table each build -- no incrementality needed.
"""

import sys
from pathlib import Path
from typing import Any

import pyarrow as pa

sys.path.insert(0, str(Path.cwd()))
from sources.git import commit_version_records

_SCHEMA = pa.schema(
    [
        ("branch", pa.string()),
        ("commit_hash", pa.string()),
        ("version", pa.string()),
    ]
)


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in commit_version_records()], schema=_SCHEMA)
