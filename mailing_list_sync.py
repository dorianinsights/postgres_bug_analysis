#!/usr/bin/env python3
"""Sync postgresql.org mailing-list mbox archives into a local cache.

Downloads one mbox file per list per month
(https://www.postgresql.org/list/<list>/mbox/<list>.YYYYMM) for every month
in the corpus window into .cache/mbox/<list>/YYYYMM.mbox. Like the
postgres.git clone, the cache IS the raw store: months older than last are
immutable on the archive side, so an existing file is never re-fetched — but
the current AND the immediately-previous month are always re-fetched, so a
mid-month run's incomplete tail gets backfilled on the next run after the
month ends (otherwise it would freeze at the partial snapshot).

The mbox endpoints sit behind a postgresql.org community-account login
(Django form with a CSRF token scraped from the login page). Credentials
come from POSTGRES_COMM_USERNAME / POSTGRES_COMM_PASSWORD, read from the
environment or from the .env file next to this script (never committed).

Writes are atomic (.tmp then rename) and sanity-checked: a response that
doesn't start with an mbox "From " separator (e.g. an HTML login bounce)
is an error, never cached.
"""

import os
import re
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import requests
from dotenv import dotenv_values

from corpus import GIT_HISTORY_SINCE

LISTS = ("pgsql-bugs", "pgsql-hackers")
LOGIN_URL = "https://www.postgresql.org/account/login/"
ARCHIVES_LOGIN_URL = "https://www.postgresql.org/list/_auth/accounts/login/"
MBOX_URL = "https://www.postgresql.org/list/{list_name}/mbox/{list_name}.{year}{month:02d}"
CACHE = Path(__file__).parent / ".cache" / "mbox"
ENV_FILE = Path(__file__).parent / ".env"
USER_AGENT = "postgres-patch-analysis (personal research)"
CSRF_RE = re.compile(r'name="csrfmiddlewaretoken" value="([^"]+)"')
MBOX_FETCH_WAIT = 0.5  # seconds between back-to-back downloads to avoid server overload, be nice to people!

def credentials() -> tuple[str, str]:
    """(username, password) from the environment, falling back to .env."""
    env: dict[str, str | None] = {**dotenv_values(ENV_FILE), **os.environ}
    username = env.get("POSTGRES_COMM_USERNAME")
    password = env.get("POSTGRES_COMM_PASSWORD")
    if not username or not password:
        msg = f"set POSTGRES_COMM_USERNAME / POSTGRES_COMM_PASSWORD (env or {ENV_FILE})"
        raise SystemExit(msg)
    return username, password


def month_range() -> list[tuple[int, int]]:
    """Every (year, month) from the corpus history floor through this month."""
    start = datetime.strptime(GIT_HISTORY_SINCE, "%Y-%m-%d").replace(tzinfo=UTC)
    now = datetime.now(UTC)
    months: list[tuple[int, int]] = []
    year, month = start.year, start.month
    while (year, month) <= (now.year, now.month):
        months.append((year, month))
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    return months


def login(session: requests.Session) -> None:
    """Authenticate the session against the community-account login form."""
    username, password = credentials()
    page = session.get(LOGIN_URL, timeout=30)
    page.raise_for_status()
    token_match = CSRF_RE.search(page.text)
    if token_match is None:
        raise SystemExit("login page had no csrfmiddlewaretoken — form layout changed?")
    resp = session.post(
        LOGIN_URL,
        data={
            "csrfmiddlewaretoken": token_match.group(1),
            "username": username,
            "password": password,
            "this_is_the_login_form": "1",
            "next": "/",
        },
        headers={"Referer": LOGIN_URL},
        timeout=30,
    )
    resp.raise_for_status()
    if 'name="password"' in resp.text:
        raise SystemExit("login failed — response still shows the login form (bad credentials?)")
    # The archives app mounted under /list/ keeps its OWN session: its login
    # URL bounces through www's federated-auth endpoint and back to
    # /list/_auth/auth_receive/, which sets the archivessession cookie the
    # mbox endpoints check. One authenticated GET completes the handshake.
    # (next must lack a trailing slash — the handshake appends one.)
    resp = session.get(ARCHIVES_LOGIN_URL, params={"next": "/list"}, timeout=30)
    resp.raise_for_status()
    if "archivessession" not in {cookie.name for cookie in session.cookies}:
        raise SystemExit("archives auth handshake did not set archivessession — flow changed?")


def get_with_retry(session: requests.Session, url: str) -> requests.Response:
    """GET with three attempts — the archive server sporadically drops
    connections mid-run (observed after ~55 back-to-back downloads)."""
    for attempt in range(2):
        try:
            resp = session.get(url, timeout=120)
            resp.raise_for_status()
        except (requests.ConnectionError, requests.Timeout):
            time.sleep(10 * (attempt + 1))
        else:
            return resp
    resp = session.get(url, timeout=120)
    resp.raise_for_status()
    return resp


def fetch_month(session: requests.Session, list_name: str, year: int, month: int) -> Path:
    """Download one monthly mbox to the cache, atomically."""
    target = CACHE / list_name / f"{year}{month:02d}.mbox"
    target.parent.mkdir(parents=True, exist_ok=True)
    resp = get_with_retry(session, MBOX_URL.format(list_name=list_name, year=year, month=month))
    if not resp.content.startswith(b"From "):
        msg = f"{list_name} {year}-{month:02d}: response is not mbox (auth bounce?)"
        raise RuntimeError(msg)
    expected = resp.headers.get("Content-Length")
    if expected is not None and int(expected) != len(resp.content):
        msg = f"{list_name} {year}-{month:02d}: truncated ({len(resp.content)} of {expected} bytes)"
        raise RuntimeError(msg)
    tmp = target.with_suffix(".tmp")
    tmp.write_bytes(resp.content)
    tmp.rename(target)
    return target


def main() -> None:
    now = datetime.now(UTC)
    # Always re-fetch the current AND the immediately-previous month: a month's
    # final days only settle after it ends, so a mid-month run captures the
    # current month incompletely. Re-fetching the previous month on the next run
    # backfills that tail — otherwise, once the month rolled over it would be
    # frozen at the partial snapshot and never revisited. Every earlier month is
    # genuinely immutable and is skipped once cached.
    prev = now.replace(day=1) - timedelta(days=1)
    refetch = {(now.year, now.month), (prev.year, prev.month)}
    session = requests.Session()
    session.headers["User-Agent"] = USER_AGENT
    login(session)

    fetched = skipped = 0
    for list_name in LISTS:
        for year, month in month_range():
            target = CACHE / list_name / f"{year}{month:02d}.mbox"
            if target.is_file() and (year, month) not in refetch:
                skipped += 1
                continue
            path = fetch_month(session, list_name, year, month)
            fetched += 1
            print(f"{list_name} {year}-{month:02d}: {path.stat().st_size:,} bytes")
            time.sleep(MBOX_FETCH_WAIT)

    print(f"\n{fetched} months fetched, {skipped} already cached -> {CACHE}")


if __name__ == "__main__":
    main()
