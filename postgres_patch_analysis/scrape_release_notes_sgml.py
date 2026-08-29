#!/usr/bin/env python3
"""Extract PostgreSQL release notes from their SGML sources in postgres.git.

The docs pages scraped by scrape_release_notes.py are *generated* from
doc/src/sgml/release-NN.sgml on each stable branch, and the SGML carries
per-item metadata the HTML drops: a comment block naming the author and every
branch each fix landed on, with commit hash and timestamp. This scraper reads
those files straight out of the local metadata clone (no HTTP at all) and
persists:

- data/releases.csv       same schema as scrape_release_notes.py
- data/release_items.csv  same schema as scrape_release_notes.py
- data/item_commits.csv   one row per (item, branch-commit): the ground-truth
                          mapping from changelog items to git commits

This is the primary release-notes source; the HTML scraper is retained as an
independent cross-check.

Parsing: the files are DocBook XML fragments wearing an .sgml extension —
multiple top-level <sect1> roots and externally-declared entities — which no
strict XML parser accepts standalone, so they're parsed leniently with
BeautifulSoup's html.parser (which also happens to resolve &sect;/&mdash;,
valid HTML entities too). An item is a NON-NESTED <listitem> under the
section's "Changes" title; a nested sub-list (e.g. a fix's remediation
steps) folds into its parent item's text by construction.
"""

import csv
import re
from typing import NamedTuple, TypedDict

from bs4 import BeautifulSoup, Comment, Tag

from corpus import MAJORS
from scrape_git_commits import ensure_clone, git
from scrape_release_notes import DATA_DIR, ItemRow, ReleaseRow


class ItemCommitRow(TypedDict):
    "One row of item_commits.csv."

    version: str
    item_index: int
    author: str
    branch: str
    commit_hash: str
    commit_date: str


class CommitAnnotation(NamedTuple):
    "One 'Branch:' line of an item's SGML comment block."

    author: str
    branch: str
    commit_hash: str
    commit_date: str


class ParsedItem(TypedDict):
    "One changelog item with its commit annotations."

    summary: str
    full: str
    cves: list[str]
    commits: list[CommitAnnotation]


class ParsedRelease(NamedTuple):
    "One release section of a major's SGML file."

    major: int
    minor: int
    date: str | None
    items: list[ParsedItem]


AUTHOR_RE = re.compile(r"^Author: (.+?)\s*$", re.MULTILINE)
BRANCH_RE = re.compile(r"^Branch: (\S+) \[([0-9a-f]+)\] (.+?)\s*$", re.MULTILINE)
DATE_TEXT_RE = re.compile(r"\d{4}-\d{2}-\d{2}")


def normalize(text: str) -> str:
    """Collapse whitespace (entity resolution already done by the parser)."""
    return re.sub(r"\s+", " ", text).strip()


def is_comment(text: str | None) -> bool:
    return isinstance(text, Comment)


def parse_commit_lines(comment: str) -> list[CommitAnnotation]:
    """One CommitAnnotation per Branch line; each Author line applies to the
    Branch lines that follow it (an item can fold several commits)."""
    commits: list[CommitAnnotation] = []
    author = ""
    for line in comment.splitlines():
        if am := AUTHOR_RE.match(line):
            author = am.group(1)
        elif bm := BRANCH_RE.match(line):
            commits.append(
                CommitAnnotation(author=author, branch=bm.group(1), commit_hash=bm.group(2), commit_date=bm.group(3))
            )
    return commits


def parse_item(li: Tag) -> ParsedItem:
    """One <listitem> -> its text, CVEs, and commit annotations.

    Extracts the comment nodes before reading text (bs4 comments are
    NavigableStrings, so get_text() would otherwise include them). The
    get_text(" ") separator matches the HTML scraper's text extraction, so
    the two sources produce comparable summaries.
    """
    commits: list[CommitAnnotation] = []
    for comment in li.find_all(string=is_comment):
        commits.extend(parse_commit_lines(str(comment)))
        comment.extract()
    first_para = li.find("para")
    summary = normalize(first_para.get_text(" ")) if first_para else normalize(li.get_text(" "))
    full = normalize(li.get_text(" "))
    cves: list[str] = sorted(set(re.findall(r"CVE-\d{4}-\d+", full)))
    return ParsedItem(summary=summary, full=full, cves=cves, commits=commits)


def parse_section(sect: Tag) -> tuple[str | None, list[ParsedItem]]:
    """(release date, changelog items) of one <sect1> release section."""
    date: str | None = None
    date_title = sect.find("title", string="Release date:")
    if date_title and (date_para := date_title.find_next("para")):
        date_match = DATE_TEXT_RE.search(date_para.get_text())
        date = date_match.group(0) if date_match else None
    items: list[ParsedItem] = []
    changes_title = sect.find("title", string="Changes")
    if changes_title and isinstance(changes_title.parent, Tag):
        items = [
            parse_item(li) for li in changes_title.parent.find_all("listitem") if li.find_parent("listitem") is None
        ]
    return date, items


def parse_major(major: int) -> list[ParsedRelease]:
    """Every release section of one major's SGML file, oldest first."""
    sgml = git("show", f"REL_{major}_STABLE:doc/src/sgml/release-{major}.sgml")
    soup = BeautifulSoup(sgml, "html.parser")
    releases: list[ParsedRelease] = []
    for sect in soup.find_all("sect1"):
        sect_id = sect.get("id")
        if not isinstance(sect_id, str) or not sect_id.startswith("release-"):
            continue
        parts = sect_id.removeprefix("release-").split("-")
        minor = int(parts[1]) if len(parts) > 1 else 0
        date, items = parse_section(sect)
        releases.append(ParsedRelease(major=major, minor=minor, date=date, items=items))
    releases.sort(key=lambda r: (r.major, r.minor))
    return releases


def main() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    ensure_clone()

    releases: list[ReleaseRow] = []
    item_rows: list[ItemRow] = []
    commit_rows: list[ItemCommitRow] = []
    for major in MAJORS:
        for maj, minor, date, items in parse_major(major):
            version = f"{maj}.{minor}"
            releases.append({"version": version, "major": maj, "minor": minor, "date": date, "n_items": len(items)})
            for i, item in enumerate(items):
                item_rows.append(
                    {
                        "version": version,
                        "major": maj,
                        "date": date,
                        "item_index": i,
                        "summary": item["summary"],
                        "full": item["full"],
                        "cves": ";".join(item["cves"]),
                    }
                )
                commit_rows.extend(
                    ItemCommitRow(
                        version=version,
                        item_index=i,
                        author=c.author,
                        branch=c.branch,
                        commit_hash=c.commit_hash,
                        commit_date=c.commit_date,
                    )
                    for c in item["commits"]
                )
            print(f"{version:>6}  {date}  items={len(items)}")

    with open(DATA_DIR / "releases.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["version", "major", "minor", "date", "n_items"])
        writer.writeheader()
        writer.writerows(releases)
    with open(DATA_DIR / "release_items.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["version", "major", "date", "item_index", "summary", "full", "cves"])
        writer.writeheader()
        writer.writerows(item_rows)
    with open(DATA_DIR / "item_commits.csv", "w", newline="") as f:
        writer = csv.DictWriter(
            f, fieldnames=["version", "item_index", "author", "branch", "commit_hash", "commit_date"]
        )
        writer.writeheader()
        writer.writerows(commit_rows)
    print(f"\nWrote {len(releases)} releases, {len(item_rows)} items, {len(commit_rows)} commit links -> {DATA_DIR}/")


if __name__ == "__main__":
    main()
