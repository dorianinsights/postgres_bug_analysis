#!/usr/bin/env python3
"""Scrape PostgreSQL CVE severity ratings into a local CSV.

The project's security fixes carry CVE ids (extracted downstream from the
release notes), but the notes give no severity. PostgreSQL publishes the
authoritative CVSS v3 base score and vector for every one of its CVEs on
its own security page — the primary source, mirroring the release-notes
and mailing-list scrapers.

Writes one raw dataset:

- data/raw/cve_severity.csv   one row per published PostgreSQL CVE
                              (id, component, CVSS v3 base score + vector)

Raw data only — the NONE/LOW/MEDIUM/HIGH/CRITICAL band is DERIVED from the
base score in the transform (stg_cve_severity), not here. The page lists
CVEs only for currently-supported majors, so CVEs from long-EOL majors in
the corpus (e.g. the 2012/2017 ids) legitimately have no row; the
downstream join left-joins and records the gap. Re-running overwrites the
file (the source page is canonical). Takes no arguments.
"""

import csv
import re
import sys
from pathlib import Path
from typing import TypedDict

import requests
from bs4 import BeautifulSoup, Tag

SECURITY_URL = "https://www.postgresql.org/support/security/"
DATA_DIR = Path(__file__).parent / "data" / "raw"

CVE_RE = re.compile(r"CVE-\d{4}-\d+")
# A full CVSS v3 base vector, as it appears both in the cell text and in the
# NVD calculator link's ?vector= parameter.
VECTOR_RE = re.compile(r"AV:[NALP]/AC:[LH]/PR:[NLH]/UI:[NR]/S:[UC]/C:[NLH]/I:[NLH]/A:[NLH]")
# The base score is the only decimal in the Component & CVSS cell.
SCORE_RE = re.compile(r"\b(\d{1,2}\.\d)\b")


class CveRow(TypedDict):
    "One row of cve_severity.csv."

    cve_id: str
    component: str
    cvss_base_score: str
    cvss_vector: str


def _cell_text(cell: Tag) -> str:
    return cell.get_text(" ", strip=True)


def parse_rows(html: str) -> list[CveRow]:
    """Parse the security page's CVE table (verbatim fields, no derivation)."""
    soup = BeautifulSoup(html, "lxml")
    tables = soup.find_all("table")
    if not tables:
        msg = "no tables found on the security page — layout changed?"
        raise RuntimeError(msg)

    rows: list[CveRow] = []
    # The first table is the CVE list; its Reference column links each CVE.
    body_rows = tables[0].find_all("tr")[1:]
    for tr in body_rows:
        cells = tr.find_all(["td", "th"])
        if len(cells) < 4:
            continue
        cve_match = CVE_RE.search(_cell_text(cells[0]))
        if cve_match is None:
            continue

        # Cell 3 is "Component <base score> <vector>", e.g.
        # "core server 8.8 AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H".
        cvss_cell = cells[3]
        text = _cell_text(cvss_cell)
        link = cvss_cell.find("a", href=True)
        raw_href = link["href"] if isinstance(link, Tag) else ""
        href = raw_href if isinstance(raw_href, str) else ""

        score_match = SCORE_RE.search(text)
        vector_match = VECTOR_RE.search(text) or VECTOR_RE.search(href)
        component = text[: score_match.start()].strip() if score_match else text

        rows.append(
            {
                "cve_id": cve_match.group(),
                "component": component,
                "cvss_base_score": score_match.group(1) if score_match else "",
                "cvss_vector": vector_match.group() if vector_match else "",
            }
        )
    return rows


def main() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    html = requests.get(SECURITY_URL, timeout=30).text
    rows = parse_rows(html)
    if not rows:
        print("no CVE rows parsed — aborting without overwriting", file=sys.stderr)
        raise SystemExit(1)

    scored = sum(1 for r in rows if r["cvss_base_score"])
    with open(DATA_DIR / "cve_severity.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["cve_id", "component", "cvss_base_score", "cvss_vector"])
        writer.writeheader()
        writer.writerows(sorted(rows, key=lambda r: r["cve_id"]))
    print(f"Wrote {len(rows)} CVEs ({scored} with a base score) -> {DATA_DIR}/cve_severity.csv")


if __name__ == "__main__":
    main()
