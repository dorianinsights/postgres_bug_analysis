"""Raw codebase size per release tag — total source lines in the tree at each
REL_MAJOR_MINOR release, read straight from the postgres.git clone at build time
(via `git grep -c` over the source file types). One row per release tag.
"""

import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path.cwd()))
import pyarrow as pa

from sources.git import tag_line_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in tag_line_records()])
