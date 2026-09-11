# pyright: strict
"""postgres_clone: the fetch refspecs (heads + tags only, never refs/*)."""

from pg_analysis import postgres_clone


def test_refspecs_cover_heads_and_tags() -> None:
    assert "+refs/heads/*:refs/heads/*" in postgres_clone.REFSPECS
    assert "+refs/tags/*:refs/tags/*" in postgres_clone.REFSPECS


def test_refspecs_do_not_pull_all_refs() -> None:
    # A bare refs/*:* would drag in GitHub's refs/pull/* PR refs, which nothing
    # here reads — the refspecs are deliberately scoped to heads and tags.
    assert all("refs/pull" not in spec for spec in postgres_clone.REFSPECS)
    assert not any(spec.startswith("+refs/*") for spec in postgres_clone.REFSPECS)
