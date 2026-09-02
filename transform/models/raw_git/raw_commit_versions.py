# pyright: basic
"""Raw commit -> shipped-minor mapping by EXACT git tag ancestry, read from the
postgres.git clone at build time (git rev-list between consecutive release tags
per stable branch -- see sources.git.commit_version_records). No date windows.
One row per (branch, commit) that shipped in a tagged minor; open-cycle commits
(after the latest tag) and master are absent. Cheap (~one rev-list per tag), so a
full table each build -- no incrementality needed.
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
