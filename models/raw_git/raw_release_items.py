"""Release-notes changelog items, parsed from the SGML in the postgres.git clone
at build time (doc/src/sgml/release-NN.sgml per stable branch) -- no CSV landing
layer. Typing and filtering happen in stg_release_items.
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.sgml import release_item_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in release_item_records()])
