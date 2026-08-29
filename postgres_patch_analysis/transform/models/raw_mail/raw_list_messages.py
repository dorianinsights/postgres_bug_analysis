"""Raw mailing-list messages, decoded straight from the monthly mbox cache
at build time (no CSV landing layer for the mail side — the mbox files
synced by ../mailing_list_sync.py are the raw store).
"""

import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path.cwd()))
import pyarrow as pa
from mailsource import list_message_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in list_message_records()])
