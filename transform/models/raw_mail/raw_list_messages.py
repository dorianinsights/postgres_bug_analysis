"""Raw mailing-list messages, decoded straight from the monthly mbox cache
at build time (no CSV landing layer for the mail side — the mbox files
synced by pg-mail-sync are the raw store).
"""

from typing import Any

import pyarrow as pa

from pg_analysis.sources.mail import list_message_records


def model(dbt: Any, session: Any) -> pa.Table:
    return pa.Table.from_pylist([record._asdict() for record in list_message_records()])
