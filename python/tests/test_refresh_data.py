# pyright: strict
"""Step selection, CLI parsing, and the in-process step runner for the
refresh_data orchestrator."""

import argparse

import pytest

from pg_analysis import mailing_list_sync, postgres_clone, scrape_cve_severity
from pg_analysis import refresh_data as rd


def _args(only: str | None = None, skip: str | None = None) -> argparse.Namespace:
    return argparse.Namespace(only=only, skip=skip)


def _step(run: rd.Callable[[], None]) -> rd.Step:
    return rd.Step("fake", "fake.main()", run, "a fake step")


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


def test_steps_are_the_fetch_modules_entry_points() -> None:
    # The orchestrator calls the scripts' own main() functions directly, so a
    # script run on its own and a step run here do exactly the same thing.
    by_key = {s.key: s.run for s in rd.STEPS}
    assert by_key == {
        "git": postgres_clone.main,
        "mail": mailing_list_sync.main,
        "cve": scrape_cve_severity.main,
    }


def test_call_step_returns_zero_when_the_function_returns() -> None:
    calls: list[str] = []
    assert rd.call_step(_step(lambda: calls.append("ran")), dry_run=False) == 0
    assert calls == ["ran"]


def test_call_step_dry_run_does_not_call_the_function() -> None:
    calls: list[str] = []
    assert rd.call_step(_step(lambda: calls.append("ran")), dry_run=True) == 0
    assert calls == []


def test_call_step_maps_system_exit_to_its_code() -> None:
    def exits() -> None:
        raise SystemExit(3)

    assert rd.call_step(_step(exits), dry_run=False) == 3


def test_call_step_treats_a_message_exit_as_failure(capsys: pytest.CaptureFixture[str]) -> None:
    def exits_with_message() -> None:
        raise SystemExit("no credentials")

    assert rd.call_step(_step(exits_with_message), dry_run=False) == 1
    assert "no credentials" in capsys.readouterr().err


def test_call_step_reports_an_exception_as_failure(capsys: pytest.CaptureFixture[str]) -> None:
    def explodes() -> None:
        msg = "boom"
        raise RuntimeError(msg)

    assert rd.call_step(_step(explodes), dry_run=False) == 1
    assert "RuntimeError: boom" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("code", "status"),
    [(None, 0), (0, 0), (2, 2), ("message", 1)],
)
def test_exit_status_mirrors_the_interpreter(code: object, status: int) -> None:
    assert rd.exit_status(code) == status
