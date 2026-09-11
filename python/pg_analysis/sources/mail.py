# pyright: strict
"""Read the mailing-list mbox cache for the raw_mail Python models.

Like the git side, the mail side has no CSV landing layer: the monthly
mbox files at .cache/mbox/<list>/YYYYMM.mbox (synced by pg-mail-sync,
i.e. pg_analysis.mailing_list_sync; immutable once a month is past) ARE the raw
store, and the models/raw_mail/ Python models call these readers at
build time.

Everything here is pure extraction from transport formats — MIME body
decoding, RFC 2047 header decoding, RFC 2822 date parsing to an ISO
string — with no analysis logic. Typing, trimming, and derivations stay
in the SQL staging models. The cache path comes from pg_analysis.paths.
"""

import email
import email.policy
import email.utils
import multiprocessing as mp
import os
import re
from collections.abc import Iterator
from email.message import EmailMessage
from pathlib import Path
from typing import NamedTuple

from pg_analysis.paths import MBOX_CACHE

# pgarchives writes every message separator as
# "From <list>-owner+archive@lists.postgresql.org <ctime date>" and does
# NOT escape body lines that start with "From " — so stdlib mailbox.mbox
# oversplits (every attached git-format-patch begins "From <sha> Mon Sep
# 17 00:00:00 2001", which created ~1,600 phantom records and truncated
# their parents). Split on the archive's own envelope shape instead.
ENVELOPE_RE = re.compile(
    rb"^From \S+-owner\+archive@lists\.postgresql\.org "
    rb"\w{3} \w{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4}\r?$",
    re.MULTILINE,
)


class ListMessageRecord(NamedTuple):
    """One archived message, decoded from its monthly mbox.

    Header values are verbatim after RFC 2047 decoding (message ids keep
    their angle brackets; sent_ts is the Date header re-serialized as an
    ISO-8601 string with its original UTC offset, or None when
    unparseable). body_text is the first text/plain part, falling back to
    raw text/html when a message has no plain part.
    """

    list_name: str
    message_id: str
    sent_ts: str | None
    from_name: str
    from_email: str
    subject: str
    in_reply_to: str | None
    reference_ids: str | None  # the References header ("references" is a reserved word downstream)
    body_text: str | None


def _messages(mbox_path: Path) -> Iterator[EmailMessage]:
    data = mbox_path.read_bytes()
    starts: list[int] = [match.start() for match in ENVELOPE_RE.finditer(data)]
    for begin, end in zip(starts, [*starts[1:], len(data)], strict=True):
        chunk = data[begin:end]
        body_start = chunk.index(b"\n") + 1  # drop the envelope line
        yield email.message_from_bytes(chunk[body_start:], policy=email.policy.default)


def _body_text(message: EmailMessage) -> str | None:
    body = message.get_body(preferencelist=("plain", "html"))
    if body is None:
        return None
    try:
        content = body.get_content()
    except (LookupError, UnicodeDecodeError, KeyError):
        payload = body.get_payload(decode=True)
        if not isinstance(payload, bytes):
            return None
        content = payload.decode("utf-8", errors="replace")
    return content if isinstance(content, str) else None


def _sent_ts(message: EmailMessage) -> str | None:
    try:
        parsed = email.utils.parsedate_to_datetime(message.get("Date", ""))
    except (ValueError, TypeError):
        return None
    return parsed.isoformat()


def _records_for_mbox(task: tuple[str, str]) -> list[ListMessageRecord]:
    """Decode one monthly mbox into its records. Module-level and self-contained
    (takes list_name + an absolute path) so a worker process can run it."""
    list_name, mbox_path = task
    records: list[ListMessageRecord] = []
    for message in _messages(Path(mbox_path)):
        from_name, from_email = email.utils.parseaddr(str(message.get("From", "")))
        records.append(
            ListMessageRecord(
                list_name=list_name,
                message_id=str(message.get("Message-ID", "")),
                sent_ts=_sent_ts(message),
                from_name=from_name,
                from_email=from_email,
                subject=str(message.get("Subject", "")),
                in_reply_to=str(message["In-Reply-To"]) if "In-Reply-To" in message else None,
                reference_ids=str(message["References"]) if "References" in message else None,
                body_text=_body_text(message),
            )
        )
    return records


def list_message_records() -> list[ListMessageRecord]:
    """One record per message across every cached monthly mbox.

    Each monthly mbox is an independent, CPU-bound parse, so we fan them out
    across a process Pool — this parse is the build's dominant single-threaded
    cost, and dbt/DuckDB can't parallelize within one Python model. `map`
    preserves task order, so the record order matches the serial version.
    """
    if not MBOX_CACHE.is_dir():
        msg = f"mbox cache not found at {MBOX_CACHE} — run pg-mail-sync first"
        raise RuntimeError(msg)
    tasks: list[tuple[str, str]] = [
        (list_dir.name, str(mbox_path))
        for list_dir in sorted(path for path in MBOX_CACHE.iterdir() if path.is_dir())
        for mbox_path in sorted(list_dir.glob("*.mbox"))
    ]
    if not tasks:
        return []
    # default start method (spawn on macOS) — the parent process is multithreaded
    # (DuckDB), which makes fork unsafe; spawn workers inherit sys.path + cwd and
    # only parse files (no DuckDB/pyarrow), so importing this module is enough.
    # Leave one core free for whatever else the user is doing.
    workers = min(len(tasks), max((os.cpu_count() or 2) - 1, 1))
    with mp.Pool(processes=workers) as pool:
        per_file: list[list[ListMessageRecord]] = pool.map(_records_for_mbox, tasks)
    return [record for file_records in per_file for record in file_records]
