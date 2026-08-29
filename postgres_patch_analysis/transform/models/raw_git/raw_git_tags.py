"""Raw REL_1x_* refs (release tags and prereleases), read straight from the
postgres.git clone at build time.
"""

import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path.cwd()))
import pyarrow as pa
from gitsource import tag_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in tag_records()])
