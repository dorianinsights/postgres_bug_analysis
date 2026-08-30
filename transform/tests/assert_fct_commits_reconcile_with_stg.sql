-- fct_commits must be exactly the commit grain: one row per stg_git_commits
-- row, none lost or duplicated by the star build (the joins into the person
-- dimension and file stats must not fan out). A row here means the fact grain
-- drifted from staging.
WITH counts AS (
  SELECT
    (SELECT COUNT(*) FROM {{ ref('fct_commits') }}) AS fct_cnt,
    (SELECT COUNT(*) FROM {{ ref('stg_git_commits') }}) AS stg_cnt
)

SELECT *
FROM counts
WHERE fct_cnt != stg_cnt
