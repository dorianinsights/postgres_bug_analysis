# pyright: strict
"""mailing_list_sync: the refetch window, the month range, credentials, CSRF."""

from datetime import UTC, datetime
from pathlib import Path

import pytest

import corpus
import mailing_list_sync as mls

# The dates below are fixed INPUTS to a pure function — chosen to cover a normal
# month and the January year-rollover. They pin refetch_months' arithmetic and
# stay valid no matter how the corpus timeline moves.


def test_refetch_months_is_current_and_previous() -> None:
    assert mls.refetch_months(datetime(2026, 9, 1, tzinfo=UTC)) == {(2026, 8), (2026, 9)}


def test_refetch_months_rolls_the_year_back_in_january() -> None:
    assert mls.refetch_months(datetime(2026, 1, 15, tzinfo=UTC)) == {(2025, 12), (2026, 1)}


def test_refetch_months_independent_of_day_of_month() -> None:
    first = mls.refetch_months(datetime(2026, 3, 1, tzinfo=UTC))
    mid = mls.refetch_months(datetime(2026, 3, 31, tzinfo=UTC))
    assert first == mid == {(2026, 2), (2026, 3)}


def test_refetch_months_always_two_and_includes_current() -> None:
    now = datetime(2026, 7, 4, tzinfo=UTC)
    window = mls.refetch_months(now)
    assert len(window) == 2
    assert (now.year, now.month) in window


def test_month_range_starts_at_the_history_floor() -> None:
    # Derived from the corpus floor (the branch point read from the clone), not
    # hardcoded, so it holds if the timeline is extended further back (a lower
    # FIRST_MAJOR).
    floor = corpus.history_floor()
    assert mls.month_range()[0] == (floor.year, floor.month)


def test_month_range_ends_at_the_current_utc_month() -> None:
    now = datetime.now(UTC)
    assert mls.month_range()[-1] == (now.year, now.month)


def test_month_range_is_contiguous_and_increasing() -> None:
    months = mls.month_range()
    for (year, month), (next_year, next_month) in zip(months, months[1:], strict=False):
        expected = (year + 1, 1) if month == 12 else (year, month + 1)
        assert (next_year, next_month) == expected


def test_credentials_missing_raises_systemexit(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(mls, "ENV_FILE", tmp_path / "absent.env")
    monkeypatch.delenv("POSTGRES_COMM_USERNAME", raising=False)
    monkeypatch.delenv("POSTGRES_COMM_PASSWORD", raising=False)
    with pytest.raises(SystemExit):
        mls.credentials()


def test_credentials_reads_from_environment(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(mls, "ENV_FILE", tmp_path / "absent.env")  # ignore the real .env
    monkeypatch.setenv("POSTGRES_COMM_USERNAME", "someuser")
    monkeypatch.setenv("POSTGRES_COMM_PASSWORD", "somepass")
    assert mls.credentials() == ("someuser", "somepass")


def test_csrf_regex_extracts_the_token() -> None:
    html = 'x <input name="csrfmiddlewaretoken" value="tok_ABC123"> y'
    match = mls.CSRF_RE.search(html)
    assert match is not None
    assert match.group(1) == "tok_ABC123"


def test_csrf_regex_absent_returns_none() -> None:
    assert mls.CSRF_RE.search("<form>no token here</form>") is None
