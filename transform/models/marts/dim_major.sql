-- Major-line dimension: one row per PostgreSQL development line -- the five
-- released majors (their stable branches, e.g. PG18) PLUS master, the
-- development trunk (the in-progress next major, not yet released). The single
-- home for line-level attributes previously re-derived as literals across the
-- project: the display label, the branch name, and the ~5-year support window
-- (ga_dt -> eol_dt). is_released separates the released majors from master;
-- is_supported is the released-and-still-in-window subset. Because master is a
-- member, every fct_commits.branch value (incl. 'master') resolves to a real
-- row -- no NULL/Unknown FK. Sourced from the version registry (int_versions)
-- for the majors, with master appended. dim_major_key is a
-- generate_surrogate_key hash of the natural key; conforms to dim_version,
-- fct_commits, and fct_branch_size_weekly. Grain = major line.
-- -> ../data/derived/dim_major.csv
WITH majors AS (
  SELECT
    major,
    MIN(release_dt) AS ga_dt
  FROM {{ ref('int_versions') }}
  GROUP BY major
),

real_members AS (
  SELECT
    {{ dbt_utils.generate_surrogate_key(['mjr.major']) }} AS dim_major_key,
    mjr.major,
    'PG' || mjr.major AS major_label,
    'REL_' || mjr.major || '_STABLE' AS stable_branch,
    mjr.ga_dt,
    -- ~5-year support window: major M's final minor lands ~Nov of 2012 + M. Same
    -- formula int_releases uses to drop EOL majors and git.py uses to cap the
    -- weekly snapshot -- surfaced here as a queryable attribute.
    MAKE_DATE(mjr.major + 2012, 11, 30) AS eol_dt,
    true AS is_released,
    CURRENT_DATE <= MAKE_DATE(mjr.major + 2012, 11, 30) AS is_supported
  FROM majors AS mjr
)

SELECT * FROM real_members
UNION ALL
-- master: the development trunk, the in-progress next major -- a real line with
-- no released major number, GA, or EOL yet (all forward-looking).
SELECT
  {{ dbt_utils.generate_surrogate_key(["'master'"]) }} AS dim_major_key,
  null AS major,
  'master' AS major_label,
  'master' AS stable_branch,
  DATE '{{ var('future_eternity') }}' AS ga_dt,
  DATE '{{ var('future_eternity') }}' AS eol_dt,
  false AS is_released,
  false AS is_supported
UNION ALL
SELECT
  {{ unknown_key() }} AS dim_major_key,
  null AS major,
  '(unknown)' AS major_label,
  '(unknown)' AS stable_branch,
  DATE '{{ var('past_eternity') }}' AS ga_dt,
  DATE '{{ var('future_eternity') }}' AS eol_dt,
  false AS is_released,
  false AS is_supported
UNION ALL
SELECT
  {{ not_applicable_key() }} AS dim_major_key,
  null AS major,
  '(not applicable)' AS major_label,
  '(not applicable)' AS stable_branch,
  DATE '{{ var('past_eternity') }}' AS ga_dt,
  DATE '{{ var('future_eternity') }}' AS eol_dt,
  false AS is_released,
  false AS is_supported
