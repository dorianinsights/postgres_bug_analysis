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
independent cross-check. Known approximation: major-release (.0) sections nest
lists, which the flat <listitem> regex mis-splits — their item counts are
approximate, matching the pipeline's stance that .0 releases aren't fixes and
are excluded downstream.
"""

import csv
import html
import re
from typing import NamedTuple, TypedDict

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


SECT1_RE = re.compile(r'<sect1 id="release-([\d-]+)"[^>]*>(.*?)</sect1>', re.DOTALL)
DATE_RE = re.compile(r"<title>Release date:</title>\s*<para>\s*(\d{4}-\d{2}-\d{2})")
LISTITEM_RE = re.compile(r"<listitem>(.*?)</listitem>", re.DOTALL)
COMMENT_RE = re.compile(r"<!--(.*?)-->", re.DOTALL)
PARA_RE = re.compile(r"<para>(.*?)</para>", re.DOTALL)
TAG_RE = re.compile(r"<[^>]+>")
AUTHOR_RE = re.compile(r"^Author: (.+?)\s*$", re.MULTILINE)
BRANCH_RE = re.compile(r"^Branch: (\S+) \[([0-9a-f]+)\] (.+?)\s*$", re.MULTILINE)


def clean_text(sgml: str) -> str:
    """SGML fragment -> plain text: drop tags (attribute entities with them),
    then resolve character entities, then collapse whitespace."""
    return re.sub(r"\s+", " ", html.unescape(TAG_RE.sub(" ", sgml))).strip()


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


def parse_item(raw: str) -> ParsedItem:
    commits: list[CommitAnnotation] = []
    for comment in COMMENT_RE.findall(raw):
        commits.extend(parse_commit_lines(comment))
    body = COMMENT_RE.sub(" ", raw)
    first_para = PARA_RE.search(body)
    summary = clean_text(first_para.group(1)) if first_para else clean_text(body)
    full = clean_text(body)
    cves: list[str] = sorted(set(re.findall(r"CVE-\d{4}-\d+", full)))
    return ParsedItem(summary=summary, full=full, cves=cves, commits=commits)


def parse_major(major: int) -> list[ParsedRelease]:
    """Every release section of one major's SGML file, oldest first."""
    sgml = git("show", f"REL_{major}_STABLE:doc/src/sgml/release-{major}.sgml")
    releases: list[ParsedRelease] = []
    for sect_id, body in SECT1_RE.findall(sgml):
        parts = sect_id.split("-")
        minor = int(parts[1]) if len(parts) > 1 else 0
        date_match = DATE_RE.search(body)
        date = date_match.group(1) if date_match else None
        changes_at = body.find("<title>Changes</title>")
        items = [parse_item(raw) for raw in LISTITEM_RE.findall(body[changes_at:])] if changes_at >= 0 else []
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
