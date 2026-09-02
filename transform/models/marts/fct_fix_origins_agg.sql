-- Distinct fixes per release split by origin — where each release's fixes
-- actually came from: filed bug reports, hackers-list development, or no
-- public trail (split into embargoed security work vs the genuinely
-- unsourceable). Carries is_out_of_band so consumers can exclude the
-- surprise emergency releases (tiny denominators that distort shares).
-- fix_share is each origin's share of its release's fixes (a ratio, so DECIMAL
-- not float) computed here rather than as an inline window in the chart.
-- Feeds the origin-share charts and future projections of how report
-- volume translates into fix volume.
WITH agg AS (
  SELECT
    reps.release_dt,
    releases.is_out_of_band,
    COALESCE(
      org.origin,
      CASE
        WHEN reps.cves IS NOT null
          THEN 'unknown_or_internal_security'
        ELSE 'unknown_or_internal_not_security'
      END
    ) AS origin,
    COUNT(*) AS fix_cnt
  FROM {{ ref('int_fix_reps') }} AS reps
  INNER JOIN {{ ref('int_releases') }} AS releases ON reps.release_dt = releases.release_dt
  LEFT JOIN {{ ref('int_fix_origins') }} AS org ON reps.item_ord = org.group_ord
  GROUP BY ALL
)

SELECT
  release_dt,
  is_out_of_band,
  origin,
  fix_cnt,
  (fix_cnt::DECIMAL(18, 6) / NULLIF(SUM(fix_cnt) OVER (PARTITION BY release_dt), 0))::DECIMAL(7, 6) AS fix_share
FROM agg
