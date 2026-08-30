-- Fix<->bug bridge: one row per (fix, bug report) since a fix can close several
-- reports and a report can be addressed by several fixes. Resolves the
-- many-to-many between fct_fixes and dim_bug. Grain = (item_ord, bug_number).
-- -> ../data/derived/bridge_fix_bug.csv
SELECT
  item_ord,
  bug_number
FROM {{ ref('int_fix_bug_links') }}
