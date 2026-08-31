# pyright: strict
"""Parse PostgreSQL release notes from the SGML sources in postgres.git, for the
raw_git Python models. A gitsource-style reader: the notes live in the clone
(doc/src/sgml/release-NN.sgml on each stable branch), so they're parsed at build
time from the same immutable snapshot as the commits and tags -- the git side
has no CSV landing layer.

The SGML carries per-item metadata the generated HTML docs drop: a comment block
naming the author and every branch each fix landed on, with commit hash and
timestamp. The files are DocBook XML fragments wearing an .sgml extension --
multiple top-level <sect1> roots and externally-declared entities -- which no
strict XML parser accepts standalone, so they're parsed leniently with
BeautifulSoup's html.parser (which also resolves &sect;/&mdash;). An item is a
NON-NESTED <listitem> under the section's "Changes" title; a nested sub-list
folds into its parent item's text by construction.

Everything here is pure extraction -- verbatim strings; typing and filtering
stay in the SQL staging models (stg_release_items, stg_item_commits).
"""

import re
import sys
from functools import cache
from pathlib import Path
from typing import NamedTuple

from bs4 import BeautifulSoup, Comment, Tag

sys.path.insert(0, str(Path.cwd().parent))
from corpus import MAJORS
from gitsource import git


class ReleaseItemRecord(NamedTuple):
    "One changelog item, verbatim (typing happens in stg_release_items)."

    version: str
    major: str
    date: str | None
    item_index: str
    summary: str
    full: str


class ItemCommitRecord(NamedTuple):
    "One (item, branch-commit) annotation (typing happens in stg_item_commits)."

    version: str
    item_index: str
    author: str
    branch: str
    commit_hash: str
    commit_date: str


class _CommitAnnotation(NamedTuple):
    "One 'Branch:' line of an item's SGML comment block."

    author: str
    branch: str
    commit_hash: str
    commit_date: str


class _ParsedItem(NamedTuple):
    "One changelog item with its commit annotations."

    summary: str
    full: str
    commits: list[_CommitAnnotation]


class _ParsedRelease(NamedTuple):
    "One release section of a major's SGML file."

    major: int
    minor: int
    date: str | None
    items: list[_ParsedItem]


_AUTHOR_RE = re.compile(r"^Author: (.+?)\s*$", re.MULTILINE)
_BRANCH_RE = re.compile(r"^Branch: (\S+) \[([0-9a-f]+)\] (.+?)\s*$", re.MULTILINE)
_DATE_TEXT_RE = re.compile(r"\d{4}-\d{2}-\d{2}")


def _normalize(text: str) -> str:
    """Collapse whitespace (entity resolution already done by the parser)."""
    return re.sub(r"\s+", " ", text).strip()


def _is_comment(text: str | None) -> bool:
    return isinstance(text, Comment)


def _parse_commit_lines(comment: str) -> list[_CommitAnnotation]:
    """One annotation per Branch line; each Author line applies to the Branch
    lines that follow it (an item can fold several commits)."""
    commits: list[_CommitAnnotation] = []
    author = ""
    for line in comment.splitlines():
        if am := _AUTHOR_RE.match(line):
            author = am.group(1)
        elif bm := _BRANCH_RE.match(line):
            commits.append(
                _CommitAnnotation(author=author, branch=bm.group(1), commit_hash=bm.group(2), commit_date=bm.group(3))
            )
    return commits


def _parse_item(li: Tag) -> _ParsedItem:
    """One <listitem> -> its text and commit annotations. Extracts comment nodes
    before reading text (bs4 comments are NavigableStrings, so get_text() would
    otherwise include them); get_text(" ") matches the HTML scraper's separator."""
    commits: list[_CommitAnnotation] = []
    for comment in li.find_all(string=_is_comment):
        commits.extend(_parse_commit_lines(str(comment)))
        comment.extract()
    first_para = li.find("para")
    summary = _normalize(first_para.get_text(" ")) if first_para else _normalize(li.get_text(" "))
    full = _normalize(li.get_text(" "))
    return _ParsedItem(summary=summary, full=full, commits=commits)


def _parse_section(sect: Tag) -> tuple[str | None, list[_ParsedItem]]:
    """(release date, changelog items) of one <sect1> release section."""
    date: str | None = None
    date_title = sect.find("title", string="Release date:")
    if date_title and (date_para := date_title.find_next("para")):
        date_match = _DATE_TEXT_RE.search(date_para.get_text())
        date = date_match.group(0) if date_match else None
    items: list[_ParsedItem] = []
    changes_title = sect.find("title", string="Changes")
    if changes_title and isinstance(changes_title.parent, Tag):
        items = [
            _parse_item(li) for li in changes_title.parent.find_all("listitem") if li.find_parent("listitem") is None
        ]
    return date, items


@cache
def _parse_major(major: int) -> tuple[_ParsedRelease, ...]:
    """Every release section of one major's SGML file, oldest first. Cached so
    the two record readers parse each file once per build."""
    sgml = git("show", f"REL_{major}_STABLE:doc/src/sgml/release-{major}.sgml")
    soup = BeautifulSoup(sgml, "html.parser")
    releases: list[_ParsedRelease] = []
    for sect in soup.find_all("sect1"):
        sect_id = sect.get("id")
        if not isinstance(sect_id, str) or not sect_id.startswith("release-"):
            continue
        parts = sect_id.removeprefix("release-").split("-")
        minor = int(parts[1]) if len(parts) > 1 else 0
        date, items = _parse_section(sect)
        releases.append(_ParsedRelease(major=major, minor=minor, date=date, items=items))
    releases.sort(key=lambda r: (r.major, r.minor))
    return tuple(releases)


def release_item_records() -> list[ReleaseItemRecord]:
    """One record per changelog item across the corpus majors."""
    records: list[ReleaseItemRecord] = []
    for major in MAJORS:
        for rel in _parse_major(major):
            version = f"{rel.major}.{rel.minor}"
            for i, item in enumerate(rel.items):
                records.append(
                    ReleaseItemRecord(
                        version=version,
                        major=str(rel.major),
                        date=rel.date,
                        item_index=str(i),
                        summary=item.summary,
                        full=item.full,
                    )
                )
    return records


def item_commit_records() -> list[ItemCommitRecord]:
    """One record per (item, branch-commit) annotation across the corpus majors."""
    records: list[ItemCommitRecord] = []
    for major in MAJORS:
        for rel in _parse_major(major):
            version = f"{rel.major}.{rel.minor}"
            for i, item in enumerate(rel.items):
                records.extend(
                    ItemCommitRecord(
                        version=version,
                        item_index=str(i),
                        author=c.author,
                        branch=c.branch,
                        commit_hash=c.commit_hash,
                        commit_date=c.commit_date,
                    )
                    for c in item.commits
                )
    return records
