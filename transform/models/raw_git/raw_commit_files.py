"""Raw per-commit file stats (git log --numstat), read straight from the
postgres.git clone at build time.
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.git import commit_file_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in commit_file_records()])
