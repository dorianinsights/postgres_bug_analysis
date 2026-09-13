-- every shipped and open release carries all four origins, zero-filled
WITH spine AS (
  SELECT
    rel.release_dt,
    rel.status,
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

documented AS (
  SELECT
    release_dt,
    origin,
    COUNT(*) AS documented_cnt,
    COUNT(*) FILTER (WHERE is_security) AS documented_security_cnt
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
  spn.status,
  spn.origin,
  -- the open release has no items yet
  CASE WHEN spn.status = 'shipped' THEN COALESCE(doc.documented_cnt, 0) END AS fix_cnt,
  CASE WHEN spn.status = 'shipped' THEN COALESCE(doc.documented_security_cnt, 0) END AS security_fix_cnt,
  COALESCE(cmt.committed_cnt, 0) AS committed_fix_cnt
FROM spine AS spn
LEFT OUTER JOIN documented AS doc ON spn.release_dt = doc.release_dt AND spn.origin = doc.origin
LEFT OUTER JOIN committed AS cmt ON spn.release_dt = cmt.release_dt AND spn.origin = cmt.origin
