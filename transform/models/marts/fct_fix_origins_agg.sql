-- Fixes per release by origin, in BOTH fix populations on one row: the
-- DOCUMENTED fixes (release-notes items, fix_cnt -- what the release actually
-- reported) and the COMMITTED fixes (distinct non-housekeeping stable-branch
-- subjects that shipped in it, committed_fix_cnt), with the documentation rate
-- between them. Every shipped release AND the open one carry all four origins
-- (zero-filled), so a chart needs no spine of its own and the categorical sort
-- (which sums a per-release key) stays chronological.
--
-- The open release has no items yet, so its fix_cnt is NULL and its
-- committed_fix_cnt is the pending stream so far. projected_fix_cnt puts it in
-- DOCUMENTED units, so it can sit on the same axis as the shipped bars: the
-- committed-so-far count times projection_factor = documented fixes per
-- committed fix that had landed by the open cycle's current age, pooled over the
-- last var(origin_projection_cycles) closed scheduled cycles (per origin -- the
-- notes document nearly every security fix but far fewer hackers-list cleanups).
-- An origin with nothing committed yet has no signal to scale -- embargoed
-- security work reaches public git only on wrap day -- so it is projected at
-- the comparators' average documented count instead (factor NULL).
--
-- Origins: pgsql-bugs / pgsql-hackers / no public trail split into embargoed
-- security vs the genuinely unsourceable (resolve_fix_origin, shared by both
-- populations). Carries is_out_of_band so consumers can exclude the surprise
-- emergency releases (tiny denominators that distort shares). fix_share is each
-- origin's share of its release's documented fixes (the projected ones for the
-- open release); ratios are DECIMAL, not float. Replaces
-- fct_pending_fix_origins_agg. Grain = (release_dt, origin).
-- -> ../data/derived/fct_fix_origins_agg.csv
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

-- the projection's comparators: the most recent closed scheduled cycles, with
-- the open cycle's current age (window_days) every early count is measured at
comparators AS (
  SELECT
    irc.ships_at_dt AS release_dt,
    irc.cycle_start_dt,
    irc.window_days
  FROM {{ ref('int_release_cycles') }} AS irc
  INNER JOIN {{ ref('int_releases') }} AS rel ON irc.ships_at_dt = rel.release_dt
  WHERE rel.status = 'shipped' AND NOT rel.is_out_of_band AND NOT rel.is_partial_window
  QUALIFY ROW_NUMBER() OVER (ORDER BY irc.ships_at_dt DESC) <= {{ var('origin_projection_cycles') }}
),

-- the comparators are CYCLES, so both sides of the factor fold a mid-cycle
-- out-of-band re-release into the scheduled cycle that produced its fixes
-- (int_releases.cycle_ships_at_dt): the documented fixes of every release in
-- the cycle ...
documented_by_cycle AS (
  SELECT
    irl.cycle_ships_at_dt AS release_dt,
    doc.origin,
    SUM(doc.fix_cnt) AS fix_cnt
  FROM documented AS doc
  INNER JOIN {{ ref('int_releases') }} AS irl ON doc.release_dt = irl.release_dt
  GROUP BY ALL
),

-- ... and the committed fixes of every release in the cycle that had landed
-- at the same age the open cycle is at now
early_committed AS (
  SELECT
    cmp.release_dt,
    cfx.origin,
    COUNT(*) AS early_fix_cnt
  FROM comparators AS cmp
  INNER JOIN {{ ref('int_releases') }} AS irl ON cmp.release_dt = irl.cycle_ships_at_dt
  INNER JOIN {{ ref('int_committed_fixes') }} AS cfx
    ON irl.release_dt = cfx.release_dt AND cmp.cycle_start_dt + cmp.window_days >= cfx.first_commit_dt
  GROUP BY ALL
),

factors AS (
  SELECT
    org.origin,
    SUM(COALESCE(doc.fix_cnt, 0)) AS documented_sum,
    SUM(COALESCE(ecm.early_fix_cnt, 0)) AS early_sum,
    AVG(COALESCE(doc.fix_cnt, 0)) AS documented_avg
  FROM comparators AS cmp
  CROSS JOIN origins AS org
  LEFT JOIN documented_by_cycle AS doc ON cmp.release_dt = doc.release_dt AND org.origin = doc.origin
  LEFT JOIN early_committed AS ecm ON cmp.release_dt = ecm.release_dt AND org.origin = ecm.origin
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
    COALESCE(cmt.committed_fix_cnt, 0) AS committed_fix_cnt,
    -- the factor applies only where the open release has a signal to scale:
    -- an origin with nothing committed yet (embargoed security, which reaches
    -- git on wrap day) is projected at the comparators' level instead
    CASE
      WHEN spn.status = 'open' AND COALESCE(cmt.committed_fix_cnt, 0) > 0
        THEN (fac.documented_sum::DECIMAL(15, 6) / NULLIF(fac.early_sum, 0))::DECIMAL(12, 6)
    END AS projection_factor,
    CASE WHEN spn.status = 'open' THEN fac.documented_avg END AS comparator_documented_avg
  FROM spine AS spn
  LEFT JOIN documented AS doc ON spn.release_dt = doc.release_dt AND spn.origin = doc.origin
  LEFT JOIN committed AS cmt ON spn.release_dt = cmt.release_dt AND spn.origin = cmt.origin
  LEFT JOIN factors AS fac ON spn.origin = fac.origin
),

projected AS (
  SELECT
    release_dt,
    dim_release_key,
    status,
    is_out_of_band,
    origin,
    fix_cnt,
    committed_fix_cnt,
    (fix_cnt::DECIMAL(15, 6) / NULLIF(committed_fix_cnt, 0))::DECIMAL(7, 6) AS documentation_rate,
    projection_factor,
    CASE
      WHEN status = 'open' AND projection_factor IS NOT null
        THEN ROUND(committed_fix_cnt * projection_factor)::BIGINT
      WHEN status = 'open'
        THEN ROUND(comparator_documented_avg)::BIGINT
    END AS projected_fix_cnt
  FROM measures
)

SELECT
  release_dt,
  dim_release_key,
  status,
  is_out_of_band,
  origin,
  fix_cnt,
  committed_fix_cnt,
  documentation_rate,
  projection_factor,
  projected_fix_cnt,
  (
    COALESCE(fix_cnt, projected_fix_cnt)::DECIMAL(18, 6)
    / NULLIF(SUM(COALESCE(fix_cnt, projected_fix_cnt)) OVER (PARTITION BY release_dt), 0)
  )::DECIMAL(7, 6) AS fix_share
FROM projected
