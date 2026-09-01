# pyright: strict
"""Step selection and CLI parsing for the refresh_data orchestrator."""

import argparse

import pytest

import refresh_data as rd


def _args(only: str | None = None, skip: str | None = None) -> argparse.Namespace:
    return argparse.Namespace(only=only, skip=skip)


def test_default_selection_is_all_steps_in_order() -> None:
    keys = [step.key for step in rd.select_steps(_args())]
    assert keys == ["git", "mail", "cve"]


def test_only_selects_named_subset_in_steps_order() -> None:
    # Order follows STEPS, not the order the keys were given.
    keys = [step.key for step in rd.select_steps(_args(only="cve,git"))]
    assert keys == ["git", "cve"]


def test_skip_excludes_named_steps() -> None:
    keys = [step.key for step in rd.select_steps(_args(skip="mail"))]
    assert keys == ["git", "cve"]


def test_unknown_step_key_exits() -> None:
    with pytest.raises(SystemExit):
        rd.select_steps(_args(only="bogus"))


def test_parse_args_builds_by_default() -> None:
    assert rd.parse_args([]).build


def test_parse_args_no_build_disables_the_build() -> None:
    assert not rd.parse_args(["--no-build"]).build


def test_parse_args_only_and_skip_are_mutually_exclusive() -> None:
    with pytest.raises(SystemExit):
        rd.parse_args(["--only", "cve", "--skip", "mail"])
