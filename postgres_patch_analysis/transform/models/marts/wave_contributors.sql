{{ config(materialized='external', location='../data/derived/wave_contributors.csv', format='csv') }}

-- Contributor credits parsed from each representative item's trailing
-- "(Name, Name)" list. A candidate list is rejected wholesale when any part
-- looks like prose rather than a name (over 40 chars, or contains a digit).
-- is_first_wave marks a contributor's debut, except in the corpus's first
-- wave (everyone is trivially "new" there).
WITH extracted AS (
  SELECT
    wave_date,
    REGEXP_EXTRACT(summary, '\(([^()]{2,200})\)\s*(?:§+\s*)*$', 1) AS credit_blob
  FROM {{ ref('int_fix_reps') }}
),

name_lists AS (
  SELECT
    wave_date,
    LIST_TRANSFORM(STRING_SPLIT(credit_blob, ','), part -> TRIM(part)) AS names
  FROM extracted
  WHERE credit_blob != ''
),

valid_lists AS (
  SELECT
    wave_date,
    names
  FROM name_lists
  WHERE LEN(LIST_FILTER(names, part -> LENGTH(part) > 40 OR REGEXP_MATCHES(part, '\d'))) = 0
),

credits AS (
  SELECT
    wave_date,
    contributor,
    COUNT(*) AS credits
  FROM (
    SELECT
      wave_date,
      UNNEST(names) AS contributor
    FROM valid_lists
  )
  WHERE contributor != ''
  GROUP BY wave_date, contributor
),

first_seen AS (
  SELECT
    contributor,
    MIN(wave_date) AS first_seen_wave
  FROM credits
  GROUP BY contributor
)

SELECT
  crd.wave_date,
  crd.contributor,
  crd.credits,
  fst.first_seen_wave,
  (
    fst.first_seen_wave = crd.wave_date
    AND crd.wave_date != (SELECT MIN(wave_date) FROM {{ ref('int_waves') }})
  )::INTEGER AS is_first_wave,
  waves.out_of_band::INTEGER AS out_of_band
FROM credits AS crd
INNER JOIN first_seen AS fst USING (contributor)
INNER JOIN {{ ref('int_waves') }} AS waves USING (wave_date)
ORDER BY crd.wave_date, crd.contributor
