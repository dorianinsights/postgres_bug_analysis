-- Fix<->bug bridge: one row per (fix, bug report) since a fix can close several
-- reports and a report can be addressed by several fixes. Resolves the
-- many-to-many between fct_fixes and dim_bug. Grain = (item_ord, dim_bug_key).
-- -> data/derived/bridge_fix_bug.csv
SELECT
  fbl.item_ord,
  dbg.dim_bug_key
FROM {{ ref('int_fix_bug_links') }} AS fbl
INNER JOIN {{ ref('dim_bug') }} AS dbg ON fbl.bug_number = dbg.bug_number
