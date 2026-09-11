"""Per-item commit annotations (author + every branch each fix landed on, with
commit hash and timestamp), parsed from the release-notes SGML comment blocks in
the postgres.git clone at build time -- no CSV landing layer. Typing and
filtering happen in stg_item_commits.
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.sgml import item_commit_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in item_commit_records()])
