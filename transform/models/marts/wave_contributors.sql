{{ config(materialized='external', location='../data/derived/wave_contributors.csv', format='csv') }}

-- Contributor credits parsed from each representative item's trailing
-- "(Name, Name)" list. A candidate list is rejected wholesale when any part
-- looks like prose rather than a name (over 40 chars, or contains a digit).
-- is_first_wave marks a contributor's debut, except in the corpus's first
-- wave (everyone is trivially "new" there).
WITH extracted AS (
  SELECT
    wave_dt,
    REGEXP_EXTRACT(summary, '\(([^()]{2,200})\)\s*(?:§+\s*)*$', 1) AS credit_blob
  FROM {{ ref('int_fix_reps') }}
),

name_lists AS (
  SELECT
    wave_dt,
    LIST_TRANSFORM(STRING_SPLIT(credit_blob, ','), part -> TRIM(part)) AS name_list
  FROM extracted
  WHERE credit_blob != ''
),

valid_lists AS (
  SELECT
    wave_dt,
    name_list
  FROM name_lists
  WHERE LEN(LIST_FILTER(name_list, part -> LENGTH(part) > 40 OR REGEXP_MATCHES(part, '\d'))) = 0
),

unnested AS (
  SELECT
    wave_dt,
    UNNEST(name_list) AS contributor
  FROM valid_lists
),

credits AS (
  SELECT
    wave_dt,
    contributor,
    COUNT(*) AS credits  -- noqa: RF04 (column name is the CSV contract)
  FROM unnested
  WHERE contributor != ''
  GROUP BY wave_dt, contributor
),

first_seen AS (
  SELECT
    contributor,
    MIN(wave_dt) AS first_seen_wave_dt
  FROM credits
  GROUP BY contributor
)

SELECT
  crd.wave_dt,
  crd.contributor,
  crd.credits,
  fst.first_seen_wave_dt,
  (
    fst.first_seen_wave_dt = crd.wave_dt
    AND crd.wave_dt != (SELECT MIN(wvs.wave_dt) FROM {{ ref('int_waves') }} AS wvs)
  )::INTEGER AS is_first_wave,
  waves.out_of_band::INTEGER AS out_of_band
FROM credits AS crd
INNER JOIN first_seen AS fst ON crd.contributor = fst.contributor
INNER JOIN {{ ref('int_waves') }} AS waves ON crd.wave_dt = waves.wave_dt
ORDER BY crd.wave_dt, crd.contributor
