-- One row per (fix, contributor) credited in the fix's release-notes item: the
-- trailing "(Name, Name)" list on the representative item, parsed here (formerly
-- inline in fct_release_contributors_agg) so the release rollup and the fix<->contributor
-- bridge share one parse. A candidate list is rejected wholesale when any part
-- looks like prose rather than a name (over 40 chars, or contains a digit).
-- Grain = (item_ord, contributor).
WITH extracted AS (
  SELECT
    item_ord,
    REGEXP_EXTRACT(summary, '\(([^()]{2,200})\)\s*(?:§+\s*)*$', 1) AS credit_blob
  FROM {{ ref('int_fix_reps') }}
),

name_lists AS (
  SELECT
    item_ord,
    LIST_TRANSFORM(STRING_SPLIT(credit_blob, ','), part -> TRIM(part)) AS name_list
  FROM extracted
  WHERE credit_blob != ''
),

valid_lists AS (
  SELECT
    item_ord,
    name_list
  FROM name_lists
  WHERE LEN(LIST_FILTER(name_list, part -> LENGTH(part) > 40 OR REGEXP_MATCHES(part, '\d'))) = 0
),

unnested AS (
  SELECT
    item_ord,
    UNNEST(name_list) AS contributor
  FROM valid_lists
)

SELECT DISTINCT
  item_ord,
  contributor
FROM unnested
WHERE contributor != ''
