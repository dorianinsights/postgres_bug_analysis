SELECT
  fbl.item_ord,
  dbg.dim_bug_key
FROM {{ ref('int_fix_bug_links') }} AS fbl
INNER JOIN {{ ref('dim_bug') }} AS dbg ON fbl.bug_number = dbg.bug_number
