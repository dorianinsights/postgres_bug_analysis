"""Raw REL_1x_* refs (release tags and prereleases), read straight from the
postgres.git clone at build time.
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.git import tag_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in tag_records()])
