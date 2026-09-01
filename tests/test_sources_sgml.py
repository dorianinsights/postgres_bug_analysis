# pyright: strict
# pyright: reportPrivateUsage=false
# ^ these tests intentionally exercise the module's private parse helpers.
"""sources.sgml: whitespace normalization, commit-comment parsing, item/section
extraction from a small DocBook fragment (parsed leniently, as the reader does).
"""

from bs4 import BeautifulSoup, Tag

from sources.sgml import _normalize, _parse_commit_lines, _parse_item, _parse_section


def test_normalize_collapses_whitespace() -> None:
    assert _normalize("  a\n\t  b   c  ") == "a b c"


def test_parse_commit_lines_carries_author_across_following_branches() -> None:
    # Author/Branch lines are flush-left inside the SGML comment, as in the
    # real release notes (the regexes anchor at column 0).
    comment = "\n".join(
        [
            "Author: Alice Dev <alice@example.com>",
            "Branch: master [abc123] 2023-02-01 10:00:00 -0500",
            "Branch: REL_15_STABLE [def456] 2023-02-01 10:05:00 -0500",
            "Author: Bob Dev <bob@example.com>",
            "Branch: REL_14_STABLE [0a1b2c] 2023-01-31 09:00:00 -0500",
        ]
    )
    commits = _parse_commit_lines(comment)
    assert [(c.author, c.branch, c.commit_hash) for c in commits] == [
        ("Alice Dev <alice@example.com>", "master", "abc123"),
        ("Alice Dev <alice@example.com>", "REL_15_STABLE", "def456"),
        ("Bob Dev <bob@example.com>", "REL_14_STABLE", "0a1b2c"),
    ]
    assert commits[0].commit_date == "2023-02-01 10:00:00 -0500"


# One release <sect1>: a release date, and a Changes list with two top-level
# items — the first annotated with a commit comment, the second bare.
SECTION_SGML = "\n".join(
    [
        '<sect1 id="release-15-2">',
        "<title>Release 15.2</title>",
        "<formalpara><title>Release date:</title><para>2023-02-09</para></formalpara>",
        "<sect2>",
        "<title>Changes</title>",
        "<itemizedlist>",
        "<listitem>",
        "<!--",
        "Author: Alice Dev <alice@example.com>",
        "Branch: master [abc123] 2023-02-01 10:00:00 -0500",
        "-->",
        "<para>Fix a bug in the query planner</para>",
        "</listitem>",
        "<listitem>",
        "<para>Improve the documentation</para>",
        "</listitem>",
        "</itemizedlist>",
        "</sect2>",
        "</sect1>",
    ]
)


def _section_tag() -> Tag:
    sect = BeautifulSoup(SECTION_SGML, "html.parser").find("sect1")
    assert isinstance(sect, Tag)
    return sect


def test_parse_section_extracts_date_and_top_level_items() -> None:
    date, items = _parse_section(_section_tag())
    assert date == "2023-02-09"
    assert [item.summary for item in items] == [
        "Fix a bug in the query planner",
        "Improve the documentation",
    ]


def test_parse_section_attaches_commit_annotations_to_the_right_item() -> None:
    _date, items = _parse_section(_section_tag())
    assert [c.commit_hash for c in items[0].commits] == ["abc123"]
    assert items[1].commits == []


def test_parse_item_strips_the_comment_from_the_item_text() -> None:
    listitem = _section_tag().find("listitem")
    assert isinstance(listitem, Tag)
    parsed = _parse_item(listitem)
    # The comment's Author/Branch text must not leak into the item's summary.
    assert parsed.summary == "Fix a bug in the query planner"
    assert "Author:" not in parsed.full
