"""Raw commit metadata, read straight from the postgres.git clone at build
time (no CSV landing layer for the git side — the clone is the raw store).
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.git import commit_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in commit_records()])
