-- every shipped and open release carries all four origins, zero-filled, so a
-- chart needs no spine of its own
WITH spine AS (
  SELECT
    rel.release_dt,
    rel.dim_release_key,
    rel.status,
    rel.is_out_of_band,
    org.origin
  FROM {{ ref('int_releases') }} AS rel,
    UNNEST([
      'pgsql-bugs',
      'pgsql-hackers',
      'unknown_or_internal_security',
      'unknown_or_internal_not_security'
    ]) AS org (origin)
  WHERE rel.status IN ('shipped', 'open')
),

-- named apart from the output columns: a lateral alias is shadowed by a
-- same-named column from a joined table
documented AS (
  SELECT
    release_dt,
    origin,
    COUNT(*) AS documented_cnt
  FROM {{ ref('int_fix_profile') }}
  GROUP BY ALL
),

committed AS (
  SELECT
    release_dt,
    origin,
    COUNT(*) AS committed_cnt
  FROM {{ ref('int_committed_fixes') }}
  GROUP BY ALL
)

SELECT
  spn.release_dt,
  spn.dim_release_key,
  spn.status,
  spn.is_out_of_band,
  spn.origin,
  -- the open release has no items yet
  CASE WHEN spn.status = 'shipped' THEN COALESCE(doc.documented_cnt, 0) END AS fix_cnt,
  COALESCE(cmt.committed_cnt, 0) AS committed_fix_cnt,
  (fix_cnt::DECIMAL(15, 6) / NULLIF(committed_fix_cnt, 0))::DECIMAL(7, 6) AS documentation_rate,
  (fix_cnt::DECIMAL(18, 6) / NULLIF(SUM(fix_cnt) OVER (PARTITION BY spn.release_dt), 0))::DECIMAL(7, 6) AS fix_share
FROM spine AS spn
LEFT OUTER JOIN documented AS doc ON spn.release_dt = doc.release_dt AND spn.origin = doc.origin
LEFT OUTER JOIN committed AS cmt ON spn.release_dt = cmt.release_dt AND spn.origin = cmt.origin
