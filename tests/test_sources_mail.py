# pyright: strict
# pyright: reportPrivateUsage=false
# ^ these tests intentionally exercise the module's private parse helpers.
"""sources.mail: the envelope splitter, and the header/body/date decoding.

The splitter exists precisely because pgarchives does NOT escape body lines that
start with "From " (every attached git-format-patch begins
"From <sha> Mon Sep 17 00:00:00 2001"), so stdlib mailbox.mbox oversplits. The
fixture below reproduces exactly that shape.
"""

import mailbox
from pathlib import Path

from sources.mail import _body_text, _messages, _records_for_mbox, _sent_ts

_OWNER = b"From pgsql-bugs-owner+archive@lists.postgresql.org"

MBOX_BYTES = b"\n".join(
    [
        _OWNER + b" Wed Feb 16 12:34:56 2022",
        b"Message-ID: <msg1@example.com>",
        b"From: Alice Example <alice@example.com>",
        b"Subject: First message",
        b"Date: Wed, 16 Feb 2022 12:34:56 +0000",
        b"Content-Type: text/plain; charset=utf-8",
        b"",
        b"Here is a patch:",
        # An UNESCAPED body "From " line — a git-format-patch header. stdlib
        # mailbox splits here; the envelope regex must not.
        b"From 1234567890abcdef1234567890abcdef12345678 Mon Sep 17 00:00:00 2001",
        b"Subject: [PATCH] fix a thing",
        b"",
        _OWNER + b" Wed Feb 16 13:00:00 2022",
        b"Message-ID: <msg2@example.com>",
        b"From: Bob Tester <bob@example.com>",
        b"Subject: Second message",
        b"Date: Wed, 16 Feb 2022 13:00:00 +0000",
        b"Content-Type: text/plain; charset=utf-8",
        b"",
        b"Second body.",
        b"",
    ]
)


def _write_mbox(tmp_path: Path) -> Path:
    path = tmp_path / "202202.mbox"
    path.write_bytes(MBOX_BYTES)
    return path


def test_envelope_splitter_does_not_oversplit_on_body_from_lines(tmp_path: Path) -> None:
    path = _write_mbox(tmp_path)
    subjects = [str(message.get("Subject", "")) for message in _messages(path)]
    assert subjects == ["First message", "Second message"]


def test_stdlib_mailbox_oversplits_the_same_file(tmp_path: Path) -> None:
    # Documents WHY the custom splitter exists: stdlib sees a phantom third
    # message at the unescaped patch "From " line.
    path = _write_mbox(tmp_path)
    box = mailbox.mbox(str(path))
    try:
        stdlib_count = len(box)
    finally:
        box.close()
    envelope_count = len(list(_messages(path)))
    assert envelope_count == 2
    assert stdlib_count > envelope_count


def test_body_of_first_message_keeps_the_patch_from_line(tmp_path: Path) -> None:
    path = _write_mbox(tmp_path)
    first = next(iter(_messages(path)))
    body = _body_text(first)
    assert body is not None
    assert "From 1234567890abcdef" in body  # the patch line survived, not split away


def test_sent_ts_round_trips_the_offset(tmp_path: Path) -> None:
    path = _write_mbox(tmp_path)
    second = list(_messages(path))[1]
    assert _sent_ts(second) == "2022-02-16T13:00:00+00:00"


def test_records_decode_addresses_and_ids(tmp_path: Path) -> None:
    path = _write_mbox(tmp_path)
    records = _records_for_mbox(("pgsql-bugs", str(path)))
    assert [record.message_id for record in records] == ["<msg1@example.com>", "<msg2@example.com>"]
    assert records[0].list_name == "pgsql-bugs"
    assert records[0].from_name == "Alice Example"
    assert records[0].from_email == "alice@example.com"
