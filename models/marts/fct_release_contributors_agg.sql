-- (release-release, contributor) credit counts, aggregated from the
-- fix<->contributor bridge joined to the fix-grain star (the "(Name, Name)"
-- parse now lives in int_fix_contributors, not inline here). Conforms to
-- dim_release via dim_release_key. is_first_release marks a contributor's debut,
-- except in the corpus's first release (everyone is trivially "new" there).
-- Grain = (dim_release_key, contributor).
WITH credits AS (
  SELECT
    fix.dim_release_key,
    fix.release_dt,
    fix.is_out_of_band,
    bfc.contributor,
    COUNT(*) AS credit_cnt
  FROM {{ ref('fct_fixes') }} AS fix
  INNER JOIN {{ ref('bridge_fix_contributor') }} AS bfc ON fix.item_ord = bfc.item_ord
  GROUP BY ALL
),

-- a contributor's debut = the earliest release they appear in. credits already
-- has one row per (contributor, release), so a MIN() window over that partition
-- gives it in one pass -- no separate aggregate CTE self-joined back on.
debut AS (
  SELECT
    crd.dim_release_key,
    crd.release_dt,
    crd.contributor,
    crd.credit_cnt,
    crd.is_out_of_band,
    MIN(crd.release_dt) OVER (PARTITION BY crd.contributor) AS first_seen_release_dt
  FROM credits AS crd
),

first_release AS (
  SELECT MIN(release_dt) AS release_dt
  FROM {{ ref('dim_release') }}
  WHERE status = 'shipped'
)

SELECT
  deb.dim_release_key,
  deb.release_dt,
  deb.contributor,
  deb.credit_cnt,
  deb.first_seen_release_dt,
  (
    deb.first_seen_release_dt = deb.release_dt
    AND deb.release_dt != (SELECT fwv.release_dt FROM first_release AS fwv)
  ) AS is_first_release,
  deb.is_out_of_band
FROM debut AS deb
