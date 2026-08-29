-- Dedup groups are per-wave by construction (edges only join items of the
-- same wave); a group spanning waves would mean the walk leaked.
SELECT
  grp.group_ord,
  COUNT(DISTINCT itm.wave_date) AS n_waves
FROM {{ ref('int_fix_groups') }} AS grp
INNER JOIN {{ ref('int_fix_items') }} AS itm ON grp.item_ord = itm.item_ord
GROUP BY grp.group_ord
HAVING COUNT(DISTINCT itm.wave_date) > 1
