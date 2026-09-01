"""Release-notes changelog items, parsed from the SGML in the postgres.git clone
at build time (doc/src/sgml/release-NN.sgml per stable branch) -- no CSV landing
layer. Typing and filtering happen in stg_release_items.
"""

import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path.cwd()))
import pyarrow as pa

from sources.sgml import release_item_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in release_item_records()])
