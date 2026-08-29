#!/usr/bin/env python3
"""Derive analysis datasets from the raw scraped CSVs.

Reads data/releases.csv, data/release_items.csv, data/git_commits.csv,
data/git_tags.csv (produced by the two scrape_*.py scripts) and writes:

- data/wave_summary.csv       one row per same-day release wave: distinct fix
                              count (backpatched duplicates collapsed across
                              branches), CVE count, out-of-band flag
- data/wave_categories.csv    tidy (wave, category) fix counts
- data/wave_contributors.csv  tidy (wave, contributor) credit counts with
                              each name's first-seen wave
- data/projections.csv        next-wave scenario values derived from the wave
                              series (reversion / trend / regime / escalation)
- data/git_cycle_pace.csv     distinct stable-branch fixes in the first N days
                              after each recent wrap, N = days elapsed in the
                              current (open) cycle — the like-for-like pace
                              comparison for the open cycle

Conventions carried over from the original analysis:
- ".0" feature releases are not fixes and are excluded.
- "Update time zone data files" items are routine refreshes, excluded.
- A wave is out-of-band (emergency re-release) when its largest release has
  fewer than 20 items.
- Cross-branch dedup: two items are the same fix when either their
  normalized summary text or their full item_commits.csv annotation block
  (the exact set of branch-commit hashes, not mere overlap) matches — see
  dedup_wave_items for the cases behind each half of that rule. When
  item_commits.csv is absent (HTML-scraped data), text alone decides.
- The first wave of the oldest major is a partial accumulation window
  (e.g. 15.1 shipped 28 days after 15.0) — flagged partial_window so
  trendlines can exclude it.
"""

import csv
import re
import statistics
from collections import Counter, defaultdict
from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import TypedDict

from categorize import CATEGORY_ORDER, categorize

DATA_DIR = Path(__file__).parent / "data"

# A raw row as csv.DictReader yields it — every value a string.
CsvRow = dict[str, str]


class WaveSummaryRow(TypedDict):
    "One same-day release wave."

    wave_date: str
    versions: str
    n_releases: int
    distinct_fixes: int
    distinct_cves: int
    security_fixes: int
    out_of_band: int
    partial_window: int


class CategoryRow(TypedDict):
    "One (wave, category) fix count."

    wave_date: str
    category: str
    category_order: int
    fixes: int
    out_of_band: int


class ContributorRow(TypedDict):
    "One (wave, contributor) credit count."

    wave_date: str
    contributor: str
    credits: int
    first_seen_wave: str
    is_first_wave: int
    out_of_band: int


class ProjectionRow(TypedDict):
    "One next-wave scenario."

    scenario: str
    scenario_order: int
    projected_date: str
    distinct_fixes: int
    low: int | str
    high: int | str
    assumption: str


class CyclePaceRow(TypedDict):
    "One release cycle's early-window pace vs full total."

    cycle_start: str
    cycle_end: str
    is_open_cycle: int
    window_days: int
    distinct_fixes_early: int
    distinct_fixes_full: int | str


TZDATA = re.compile(r"Update time zone data files", re.IGNORECASE)

# Credits: the release notes end each item's summary with "(Name, Name)".
CREDIT_RE = re.compile(r"\(([^()]{2,200})\)\s*(?:§+\s*)*$")


def read_csv(name: str) -> list[CsvRow]:
    with open(DATA_DIR / name, newline="") as f:
        return list(csv.DictReader(f))


def write_csv(name: str, rows: Sequence[Mapping[str, object]], fieldnames: list[str]) -> None:
    with open(DATA_DIR / name, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {name}: {len(rows)} rows")


def norm_key(summary: str) -> str:
    return re.sub(r"\s+", " ", summary.replace("§", " ")).strip().lower()


def parse_credits(summary: str) -> list[str]:
    """Contributor names from the trailing parenthesized credit list."""
    m = CREDIT_RE.search(summary)
    if not m:
        return []
    names = [n.strip() for n in m.group(1).split(",")]
    # A credit list is names, not prose: every part short-ish, mostly letters.
    if not names or any(len(n) > 40 or re.search(r"\d", n) for n in names):
        return []
    return [n for n in names if n]


def ols(ys: list[float]) -> tuple[float, float]:
    """Least-squares (intercept, slope) over y indexed 0..n-1."""
    n = len(ys)
    xs = range(n)
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys, strict=True))
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    return (sy - slope * sx) / n, slope


def load_commit_sets() -> dict[tuple[str, str], set[str]]:
    """(version, item_index) -> that item's commit hashes, from item_commits.csv.

    Empty when the file is absent (i.e. the data came from the HTML scraper,
    which has no commit annotations) — dedup then falls back to summary text.
    """
    if not (DATA_DIR / "item_commits.csv").exists():
        print("item_commits.csv not found — wave dedup falling back to summary text")
        return {}
    commit_sets: dict[tuple[str, str], set[str]] = defaultdict(set)
    for c in read_csv("item_commits.csv"):
        commit_sets[(c["version"], c["item_index"])].add(c["commit_hash"])
    return commit_sets


def dedup_wave_items(
    wave_releases: list[CsvRow],
    items_by_version: dict[str, list[CsvRow]],
    commit_sets: dict[tuple[str, str], set[str]],
) -> dict[str, CsvRow]:
    """One representative item per distinct fix across the wave's branches.

    Two items are the same fix when EITHER their normalized summary text or
    their full annotated commit set matches (transitively). Both signals are
    constants the notes author copies verbatim between branch files, and each
    covers the other's blind spot, all observed in real waves:

    - Same fix, wording drifted between branches -> caught by the hash set.
    - Same fix, one branch's block carries an extra follow-up commit
      (to_date() localized-names, Aug 2026) -> caught by the text.
    - Different fixes sharing a combined backpatch commit (to_char overrun +
      standby reconnect, Aug 2026) -> mere hash OVERLAP would over-merge;
      requiring the identical full set keeps them apart.
    - Branch-scope variants documented as separate items with subset blocks
      (pg_dump sort order, Nov 2025) -> neither signal matches; stay apart.
    """
    key_group: dict[str, str] = {}
    reps: dict[str, CsvRow] = {}
    for r in wave_releases:
        for it in items_by_version[r["version"]]:
            hashes = sorted(commit_sets.get((it["version"], it["item_index"]), set()))
            text_key = f"t:{norm_key(it['summary'])}"
            hash_key = "h:" + ",".join(hashes) if hashes else None
            group = key_group.get(text_key) or (key_group.get(hash_key) if hash_key else None)
            if group is None:
                group = text_key
                reps[group] = it
            key_group[text_key] = group
            if hash_key:
                key_group[hash_key] = group
    return reps


def build_waves() -> None:
    releases = [r for r in read_csv("releases.csv") if int(r["minor"]) > 0]
    items = [r for r in read_csv("release_items.csv") if not r["version"].endswith(".0")]
    items = [r for r in items if not TZDATA.search(r["full"])]

    n_by_version: dict[str, int] = {r["version"]: int(r["n_items"]) for r in releases}
    waves: dict[str, list[CsvRow]] = defaultdict(list)
    for r in releases:
        waves[r["date"]].append(r)
    items_by_version: dict[str, list[CsvRow]] = defaultdict(list)
    for it in items:
        items_by_version[it["version"]].append(it)

    first_wave_date = min(waves)
    commit_sets = load_commit_sets()
    summary_rows: list[WaveSummaryRow] = []
    category_rows: list[CategoryRow] = []
    contrib_credits: Counter[tuple[str, str]] = Counter()
    first_seen: dict[str, str] = {}

    for wave_date in sorted(waves):
        wave_releases = waves[wave_date]
        oob = max(n_by_version[r["version"]] for r in wave_releases) < 20
        dedup = dedup_wave_items(wave_releases, items_by_version, commit_sets)
        cves = {cv for it in dedup.values() for cv in it["cves"].split(";") if cv}
        cats = Counter(categorize(it["full"], it["cves"]) for it in dedup.values())
        for it in dedup.values():
            for name in parse_credits(it["summary"]):
                contrib_credits[(wave_date, name)] += 1
                first_seen.setdefault(name, wave_date)

        summary_rows.append(
            {
                "wave_date": wave_date,
                "versions": " / ".join(r["version"] for r in wave_releases),
                "n_releases": len(wave_releases),
                "distinct_fixes": len(dedup),
                "distinct_cves": len(cves),
                "security_fixes": cats.get("Security (CVE)", 0) + cats.get("Security hardening (no CVE)", 0),
                "out_of_band": int(oob),
                "partial_window": int(wave_date == first_wave_date),
            }
        )
        category_rows.extend(
            {
                "wave_date": wave_date,
                "category": cat,
                "category_order": CATEGORY_ORDER.index(cat),
                "fixes": cats[cat],
                "out_of_band": int(oob),
            }
            for cat in CATEGORY_ORDER
            if cats.get(cat)
        )

    write_csv(
        "wave_summary.csv",
        summary_rows,
        [
            "wave_date",
            "versions",
            "n_releases",
            "distinct_fixes",
            "distinct_cves",
            "security_fixes",
            "out_of_band",
            "partial_window",
        ],
    )
    write_csv("wave_categories.csv", category_rows, ["wave_date", "category", "category_order", "fixes", "out_of_band"])

    oob_by_wave: dict[str, int] = {w["wave_date"]: w["out_of_band"] for w in summary_rows}
    contrib_rows: list[ContributorRow] = [
        {
            "wave_date": wave_date,
            "contributor": name,
            "credits": credit_count,
            "first_seen_wave": first_seen[name],
            "is_first_wave": int(first_seen[name] == wave_date and wave_date != first_wave_date),
            "out_of_band": oob_by_wave[wave_date],
        }
        for (wave_date, name), credit_count in sorted(contrib_credits.items())
    ]
    write_csv(
        "wave_contributors.csv",
        contrib_rows,
        ["wave_date", "contributor", "credits", "first_seen_wave", "is_first_wave", "out_of_band"],
    )

    build_projections(summary_rows)


def build_projections(summary_rows: list[WaveSummaryRow]) -> None:
    """Next-wave scenarios from the full-quarter wave series (see README)."""
    fullq = [w for w in summary_rows if not w["out_of_band"] and not w["partial_window"]]
    series = [float(w["distinct_fixes"]) for w in fullq]
    latest = fullq[-1]
    next_date = (date.fromisoformat(latest["wave_date"]) + timedelta(days=91)).isoformat()

    intercept, slope = ols(series)
    trend_next = intercept + slope * len(series)
    baseline = statistics.mean(series[-4:-1])  # recent norm, excluding the latest wave
    sd = statistics.stdev(series[:-1])

    rows: list[ProjectionRow] = [
        {
            "scenario": "reversion",
            "scenario_order": 0,
            "projected_date": next_date,
            "distinct_fixes": round(baseline),
            "low": round(baseline - sd),
            "high": round(baseline + sd),
            "assumption": "latest wave was a one-off; return to the mean of the prior three full-quarter waves",
        },
        {
            "scenario": "trend",
            "scenario_order": 1,
            "projected_date": next_date,
            "distinct_fixes": round(trend_next),
            "low": "",
            "high": "",
            "assumption": "least-squares line through all full-quarter waves, extended one slot",
        },
        {
            "scenario": "regime repeat",
            "scenario_order": 2,
            "projected_date": next_date,
            "distinct_fixes": latest["distinct_fixes"],
            "low": "",
            "high": "",
            "assumption": "whatever produced the latest wave keeps delivering at that level",
        },
        {
            "scenario": "escalation",
            "scenario_order": 3,
            "projected_date": next_date,
            "distinct_fixes": round(float(latest["distinct_fixes"]) + slope),
            "low": "",
            "high": "",
            "assumption": "latest wave is the new base and growth continues at the fitted trend rate",
        },
    ]
    write_csv(
        "projections.csv",
        rows,
        ["scenario", "scenario_order", "projected_date", "distinct_fixes", "low", "high", "assumption"],
    )


def build_git_cycle_pace(n_cycles: int = 3) -> None:
    """Distinct stable-branch fixes in each cycle's first N days, N = the open cycle's age.

    Cycle boundaries are the wrap moments of SCHEDULED waves only (the latest
    tag date within a week before each scheduled release date) — out-of-band
    re-wraps don't reset the pipeline clock.
    """
    commits = [r for r in read_csv("git_commits.csv") if r["branch"] != "master" and not int(r["is_plumbing"])]
    tag_dates = sorted({t["date"] for t in read_csv("git_tags.csv")})
    sched_waves = [w for w in read_csv("wave_summary.csv") if not int(w["out_of_band"])]

    wrap_dates: list[str] = []
    for w in sched_waves[-n_cycles:]:
        release_day = date.fromisoformat(w["wave_date"])
        candidates = [d for d in tag_dates if 0 <= (release_day - date.fromisoformat(d)).days <= 7]
        if candidates:
            wrap_dates.append(max(candidates))
    today = datetime.now(UTC).date().isoformat()
    open_age = (date.fromisoformat(today) - date.fromisoformat(wrap_dates[-1])).days

    def distinct_between(start: str, end: str) -> int:
        keys = {re.sub(r"\s+", " ", c["subject"].strip().lower()) for c in commits if start < c["commit_date"] <= end}
        return len(keys)

    rows: list[CyclePaceRow] = []
    for i, wrap in enumerate(wrap_dates):
        next_wrap = wrap_dates[i + 1] if i + 1 < len(wrap_dates) else today
        early_end = (date.fromisoformat(wrap) + timedelta(days=open_age)).isoformat()
        rows.append(
            {
                "cycle_start": wrap,
                "cycle_end": next_wrap if next_wrap != today else "",
                "is_open_cycle": int(next_wrap == today),
                "window_days": open_age,
                "distinct_fixes_early": distinct_between(wrap, min(early_end, next_wrap)),
                "distinct_fixes_full": distinct_between(wrap, next_wrap) if next_wrap != today else "",
            }
        )
    write_csv(
        "git_cycle_pace.csv",
        rows,
        ["cycle_start", "cycle_end", "is_open_cycle", "window_days", "distinct_fixes_early", "distinct_fixes_full"],
    )


def main() -> None:
    build_waves()
    if (DATA_DIR / "git_commits.csv").exists():
        build_git_cycle_pace()
    else:
        print("git_commits.csv not found — run scrape_git_commits.py first (skipping cycle pace)")


if __name__ == "__main__":
    main()
