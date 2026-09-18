{{ config(severity='warn') }}

-- A fix's "Backpatch-through:" trailer names the oldest major it was applied
-- to (the in-development major on a master-only commit). Where that major is
-- inside the corpus, the fix's commits should reach it: a fix whose oldest
-- landed major is NEWER than its stated floor is either one fix split by a
-- reworded subject (fix_key is the normalized subject, so the halves count as
-- two fixes) or a backpatch still pending. Warn, not fail: the few genuinely
-- stale trailers are for a person to read.
WITH corpus_floor AS (
  SELECT MIN(major) AS major
  FROM {{ ref('dim_major') }}
  WHERE NOT is_synthetic_row
),

stated AS (
  SELECT
    fix_key,
    MAX(backpatch_through_major) AS stated_floor,
    MIN(commit_dt) AS first_commit_dt
  FROM {{ ref('dim_commit') }}
  WHERE NOT is_housekeeping AND backpatch_through_major IS NOT null
  GROUP BY fix_key
),

-- every scope: a master commit sits on the in-development major, which is
-- exactly the floor a master-only fix states
landed AS (
  SELECT
    cmt.fix_key,
    MIN(mjr.major) AS landed_floor
  FROM {{ ref('dim_commit') }} AS cmt
  INNER JOIN {{ ref('dim_major') }} AS mjr ON cmt.dim_major_key = mjr.dim_major_key
  WHERE NOT mjr.is_synthetic_row
  GROUP BY cmt.fix_key
)

SELECT
  stt.fix_key,
  stt.first_commit_dt,
  stt.stated_floor,
  lnd.landed_floor
FROM stated AS stt
LEFT OUTER JOIN landed AS lnd ON stt.fix_key = lnd.fix_key
WHERE
  stt.stated_floor >= (SELECT flr.major FROM corpus_floor AS flr)
  AND (lnd.landed_floor IS null OR lnd.landed_floor > stt.stated_floor)
