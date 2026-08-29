{{ config(materialized='external', location='../data/derived/fix_items.csv', format='csv') }}

-- The item-grain fact the wave rollups are built from: one row per distinct
-- fix per wave (the deduped representative item), categorized. version +
-- item_index locate the representative in release_items.csv;
-- n_branch_items is how many per-branch changelog items folded into this
-- fix (backpatch breadth within the wave).
WITH group_sizes AS (
  SELECT
    group_ord,
    COUNT(*) AS n_branch_items
  FROM {{ ref('int_fix_groups') }}
  GROUP BY group_ord
)

SELECT
  reps.wave_date,
  reps.version,
  reps.item_index,
  reps.summary,
  reps.full_text,
  reps.cves,
  reps.category,
  cats.category_order,
  grp.n_branch_items,
  waves.out_of_band::INTEGER AS out_of_band
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN group_sizes AS grp ON reps.item_ord = grp.group_ord
INNER JOIN {{ ref('categories') }} AS cats USING (category)
INNER JOIN {{ ref('int_waves') }} AS waves USING (wave_date)
ORDER BY reps.wave_date, reps.item_ord
