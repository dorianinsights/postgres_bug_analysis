#!/usr/bin/env python3
"""Scrape PostgreSQL minor-release notes into local CSVs.

Fetches every release-notes page for the configured major versions from
postgresql.org and persists two raw datasets:

- data/releases.csv       one row per release (version, date, item count)
- data/release_items.csv  one row per changelog item (summary, full text, CVEs)

Raw data only — categorization, wave grouping, and dedup live in
build_datasets.py so the scrape never needs re-running to change analysis
rules. Re-running overwrites both files (the source pages are canonical).
Takes no arguments; the majors scraped are defined in corpus.py.
"""

import csv
import re
import sys
import time
from pathlib import Path
from typing import TypedDict

import requests
from bs4 import BeautifulSoup, Tag

from corpus import MAJORS


class Item(TypedDict):
    "One changelog list item."

    summary: str
    full: str
    cves: list[str]


class Page(TypedDict):
    "One parsed release-notes page."

    version: str
    date: str | None
    items: list[Item]


class ReleaseRow(TypedDict):
    "One row of releases.csv."

    version: str
    major: int
    minor: int
    date: str | None
    n_items: int


class ItemRow(TypedDict):
    "One row of release_items.csv."

    version: str
    major: int
    date: str | None
    item_index: int
    summary: str
    full: str
    cves: str


BASE_URL = "https://www.postgresql.org/docs/release/{}/"
INDEX_URL = "https://www.postgresql.org/docs/release/"
DATA_DIR = Path(__file__).parent / "data"


def discover_versions(majors: tuple[int, ...]) -> list[tuple[int, int]]:
    """All (major, minor) versions for the requested majors, from the release index page."""
    idx: str = requests.get(INDEX_URL, timeout=30).text
    pat = "|".join(str(m) for m in majors)
    found: set[tuple[int, int]] = {
        (int(v.partition(".")[0]), int(v.partition(".")[2]))
        for v in re.findall(rf'href="/docs/release/((?:{pat})\.\d+)/"', idx)
    }
    # Probe for gap versions the index might omit (a 404/redirect drops them later)
    for major in majors:
        minors = [minor for m, minor in found if m == major]
        if minors:
            found.update((major, minor) for minor in range(max(minors) + 1))
    return sorted(found)


def parse_page(version: str) -> Page | None:
    """Release date + changelog items for one release page.

    allow_redirects=False drops phantom versions (18.5 redirects to 18.6 —
    it was wrapped but never shipped).
    """
    resp = requests.get(BASE_URL.format(version), timeout=30, allow_redirects=False)
    if resp.status_code != 200:
        return None
    soup = BeautifulSoup(resp.text, "lxml")
    m = re.search(r"Release date:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", soup.get_text())
    date = m.group(1) if m else None

    # PG16+ pages: the changelog list lives in <div id="RELEASE-x-y-CHANGES">.
    # PG15 pages use generated ids, so fall back to the "Changes" heading.
    sections: list[Tag] = soup.find_all("div", id=re.compile(r"^RELEASE-.*-CHANGES$"))
    if not sections:
        for sect in soup.find_all("div", class_="sect2"):
            h = sect.find(["h2", "h3", "h4"])
            title = h.get_text(" ", strip=True).replace("\xa0", " ") if h else ""
            if re.search(r"\bChanges\b", title):
                sections.append(sect)

    items: list[Item] = []
    for sect in sections:
        for li in sect.find_all("li"):
            p = li.find("p")
            summary = re.sub(r"\s+", " ", (p or li).get_text(" ", strip=True))
            full = re.sub(r"\s+", " ", li.get_text(" ", strip=True))
            cves: list[str] = sorted(set(re.findall(r"CVE-\d{4}-\d+", full)))
            items.append(Item(summary=summary, full=full, cves=cves))
    return Page(version=version, date=date, items=items)


def main() -> None:
    DATA_DIR.mkdir(exist_ok=True)

    releases: list[ReleaseRow] = []
    item_rows: list[ItemRow] = []
    for major, minor in discover_versions(MAJORS):
        version = f"{major}.{minor}"
        page = parse_page(version)
        if page is None:
            print(f"{version}: missing/redirect — skipped", file=sys.stderr)
            continue
        releases.append(
            {
                "version": version,
                "major": major,
                "minor": minor,
                "date": page["date"],
                "n_items": len(page["items"]),
            }
        )
        for i, item in enumerate(page["items"]):
            item_rows.append(
                {
                    "version": version,
                    "major": major,
                    "date": page["date"],
                    "item_index": i,
                    "summary": item["summary"],
                    "full": item["full"],
                    "cves": ";".join(item["cves"]),
                }
            )
        print(f"{version:>6}  {page['date']}  items={len(page['items'])}")
        time.sleep(0.3)

    with open(DATA_DIR / "releases.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["version", "major", "minor", "date", "n_items"])
        writer.writeheader()
        writer.writerows(releases)
    with open(DATA_DIR / "release_items.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["version", "major", "date", "item_index", "summary", "full", "cves"])
        writer.writeheader()
        writer.writerows(item_rows)
    print(f"\nWrote {len(releases)} releases, {len(item_rows)} items -> {DATA_DIR}/")


if __name__ == "__main__":
    main()
