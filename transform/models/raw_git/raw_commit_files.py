"""Raw per-commit file stats (git log --numstat), read straight from the
postgres.git clone at build time.
"""

import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path.cwd()))
import pyarrow as pa

from sources.git import commit_file_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in commit_file_records()])
