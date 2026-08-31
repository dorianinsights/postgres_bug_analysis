-- (release-wave, contributor) credit counts, aggregated from the
-- fix<->contributor bridge joined to the fix-grain star (the "(Name, Name)"
-- parse now lives in int_fix_contributors, not inline here). Conforms to
-- dim_release via release_key. is_first_wave marks a contributor's debut, except
-- in the corpus's first wave (everyone is trivially "new" there).
-- Grain = (release_key, contributor).
WITH credits AS (
  SELECT
    fix.wave_key AS release_key,
    fix.wave_dt AS release_dt,
    fix.is_out_of_band,
    bfc.contributor,
    COUNT(*) AS credit_cnt
  FROM {{ ref('fct_fixes') }} AS fix
  INNER JOIN {{ ref('bridge_fix_contributor') }} AS bfc ON fix.item_ord = bfc.item_ord
  GROUP BY ALL
),

first_seen AS (
  SELECT
    contributor,
    MIN(release_dt) AS first_seen_release_dt
  FROM credits
  GROUP BY ALL
),

first_wave AS (
  SELECT MIN(release_dt) AS release_dt
  FROM {{ ref('dim_release') }}
  WHERE status = 'shipped'
)

SELECT
  crd.release_key,
  crd.release_dt,
  crd.contributor,
  crd.credit_cnt,
  fst.first_seen_release_dt,
  (
    fst.first_seen_release_dt = crd.release_dt
    AND crd.release_dt != (SELECT fwv.release_dt FROM first_wave AS fwv)
  ) AS is_first_wave,
  crd.is_out_of_band
FROM credits AS crd
INNER JOIN first_seen AS fst ON crd.contributor = fst.contributor
