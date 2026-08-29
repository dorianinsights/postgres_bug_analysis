-- The item-grain fact the wave rollups are built from: one row per distinct
-- fix per wave (the deduped representative item), categorized. version +
-- item_index locate the representative in release_items.csv;
-- branch_item_cnt is how many per-branch changelog items folded into this
-- fix (backpatch breadth within the wave).
WITH group_sizes AS (
  SELECT
    group_ord,
    COUNT(*) AS branch_item_cnt
  FROM {{ ref('int_fix_groups') }}
  GROUP BY ALL
)

SELECT
  reps.wave_dt,
  reps.version,
  reps.item_index,
  reps.summary,
  reps.full_text,
  reps.cves,
  reps.category,
  cats.category_order,
  grp.branch_item_cnt,
  waves.is_out_of_band
FROM {{ ref('int_fix_reps') }} AS reps
INNER JOIN group_sizes AS grp ON reps.item_ord = grp.group_ord
INNER JOIN {{ ref('categories') }} AS cats ON reps.category = cats.category
INNER JOIN {{ ref('int_waves') }} AS waves ON reps.wave_dt = waves.wave_dt
