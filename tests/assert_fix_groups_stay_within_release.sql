-- Dedup groups are per-release by construction (edges only join items of the
-- same release); a group spanning releases would mean the walk leaked.
SELECT
  grp.group_ord,
  COUNT(DISTINCT itm.release_dt) AS release_cnt
FROM {{ ref('int_fix_groups') }} AS grp
INNER JOIN {{ ref('int_fix_items') }} AS itm ON grp.item_ord = itm.item_ord
GROUP BY grp.group_ord
HAVING COUNT(DISTINCT itm.release_dt) > 1
