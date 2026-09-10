-- Fixes per release by origin, in BOTH fix populations on one row: the
-- DOCUMENTED fixes (release-notes items, fix_cnt -- what the release actually
-- reported) and the COMMITTED fixes (distinct non-housekeeping stable-branch
-- subjects that shipped in it, committed_fix_cnt), with the documentation rate
-- between them. Every shipped release AND the open one carry all four origins
-- (zero-filled), so a chart needs no spine of its own and the categorical sort
-- (which sums a per-release key) stays chronological.
--
-- The open release has no items yet, so its fix_cnt is NULL and its
-- committed_fix_cnt is the pending stream so far. Observed measures only: the
-- documented-units forecast of the open release that once rode here (a
-- per-origin projected_fix_cnt) is fct_fix_projections' origin_scaled method
-- now, so an estimated measure never sits beside the actuals.
--
-- Origins: pgsql-bugs / pgsql-hackers / no public trail split into embargoed
-- security vs the genuinely unsourceable (resolve_fix_origin, shared by both
-- populations). Carries is_out_of_band so consumers can exclude the surprise
-- emergency releases (tiny denominators that distort shares). fix_share is each
-- origin's share of its release's documented fixes (shipped rows only); ratios
-- are DECIMAL, not float. Replaces fct_pending_fix_origins_agg.
-- Grain = (release_dt, origin). -> ../data/derived/fct_fix_origins_agg.csv
WITH releases AS (
  SELECT
    release_dt,
    dim_release_key,
    status,
    is_out_of_band
  FROM {{ ref('int_releases') }}
  WHERE status IN ('shipped', 'open')
),

origins AS (
  SELECT
    UNNEST([
      'pgsql-bugs',
      'pgsql-hackers',
      'unknown_or_internal_security',
      'unknown_or_internal_not_security'
    ]) AS origin
),

spine AS (
  SELECT
    rel.release_dt,
    rel.dim_release_key,
    rel.status,
    rel.is_out_of_band,
    org.origin
  FROM releases AS rel
  CROSS JOIN origins AS org
),

documented AS (
  SELECT
    reps.release_dt,
    -- a fix none of whose annotated commits matched the corpus has no origin
    -- row: no public trail, split by its CVE mention like the rest
    COALESCE(org.origin, {{ resolve_fix_origin('false', 'false', 'reps.cves IS NOT null') }}) AS origin,
    COUNT(*) AS fix_cnt
  FROM {{ ref('int_fix_reps') }} AS reps
  LEFT JOIN {{ ref('int_fix_origins') }} AS org ON reps.item_ord = org.group_ord
  GROUP BY ALL
),

committed AS (
  SELECT
    release_dt,
    origin,
    COUNT(*) AS committed_fix_cnt
  FROM {{ ref('int_committed_fixes') }}
  GROUP BY ALL
),

measures AS (
  SELECT
    spn.release_dt,
    spn.dim_release_key,
    spn.status,
    spn.is_out_of_band,
    spn.origin,
    CASE WHEN spn.status = 'shipped' THEN COALESCE(doc.fix_cnt, 0) END AS fix_cnt,
    COALESCE(cmt.committed_fix_cnt, 0) AS committed_fix_cnt
  FROM spine AS spn
  LEFT JOIN documented AS doc ON spn.release_dt = doc.release_dt AND spn.origin = doc.origin
  LEFT JOIN committed AS cmt ON spn.release_dt = cmt.release_dt AND spn.origin = cmt.origin
)

SELECT
  release_dt,
  dim_release_key,
  status,
  is_out_of_band,
  origin,
  fix_cnt,
  committed_fix_cnt,
  (fix_cnt::DECIMAL(15, 6) / NULLIF(committed_fix_cnt, 0))::DECIMAL(7, 6) AS documentation_rate,
  (
    fix_cnt::DECIMAL(18, 6)
    / NULLIF(SUM(fix_cnt) OVER (PARTITION BY release_dt), 0)
  )::DECIMAL(7, 6) AS fix_share
FROM measures
