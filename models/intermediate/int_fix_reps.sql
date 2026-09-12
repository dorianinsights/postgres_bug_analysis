WITH group_sizes AS (
  SELECT
    group_ord,
    COUNT(*) AS branch_item_cnt
  FROM {{ ref('int_fix_groups') }}
  GROUP BY ALL
)

SELECT
  itm.item_ord,
  itm.release_dt,
  itm.version,
  itm.item_index,
  itm.summary,
  itm.full_text,
  itm.cves,
  itm.text_key,
  itm.hash_key,
  grp.branch_item_cnt
FROM {{ ref('int_fix_items') }} AS itm
INNER JOIN group_sizes AS grp ON itm.item_ord = grp.group_ord
