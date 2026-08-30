-- fct_fixes must stay at the distinct-fix grain: exactly one row per distinct
-- fix, same as int_fix_reps (the categorized representative per group). A row
-- here means the star's fact gained or lost fixes relative to that grain (e.g.
-- a bug/CVE join fanned out instead of being aggregated).
WITH counts AS (
  SELECT
    (SELECT COUNT(*) FROM {{ ref('fct_fixes') }}) AS fct_cnt,
    (SELECT COUNT(*) FROM {{ ref('int_fix_reps') }}) AS reps_cnt
)

SELECT *
FROM counts
WHERE fct_cnt != reps_cnt
