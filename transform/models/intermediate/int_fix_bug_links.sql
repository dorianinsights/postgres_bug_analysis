-- The fix -> bug-report links: which numbered pgsql-bugs reports each distinct
-- fix traces back to, through its annotated commits. A fix's whole dedup group
-- -> annotated abbrev hashes -> full commit hashes -> either a Discussion:
-- trailer citing a BUG thread (int_commit_discussions -> int_bug_messages) or a
-- direct "Bug: #NNNNN" ref (int_commit_bug_refs). Restricted to bug numbers
-- that exist in int_bug_reports (the corpus window) so it conforms to dim_bug.
-- Grain = (item_ord, bug_number). Reused by fct_fixes and bridge_fix_bug.
WITH fix_commit_hashes AS (
  SELECT DISTINCT
    grp.group_ord,
    itc.commit_hash AS abbrev_hash
  FROM {{ ref('int_fix_groups') }} AS grp
  INNER JOIN {{ ref('int_fix_items') }} AS itm ON grp.item_ord = itm.item_ord
  INNER JOIN {{ ref('stg_item_commits') }} AS itc
    ON itm.version = itc.version AND itm.item_index = itc.item_index
),

full_hashes AS (
  SELECT DISTINCT
    fch.group_ord,
    gcm.commit_hash AS full_hash
  FROM fix_commit_hashes AS fch
  INNER JOIN {{ ref('stg_git_commits') }} AS gcm
    ON LEFT(gcm.commit_hash, 9) = fch.abbrev_hash
),

linked AS (
  SELECT DISTINCT
    fhs.group_ord AS item_ord,
    bmg.bug_number
  FROM full_hashes AS fhs
  INNER JOIN {{ ref('int_commit_discussions') }} AS dsc ON fhs.full_hash = dsc.commit_hash
  INNER JOIN {{ ref('int_bug_messages') }} AS bmg ON dsc.message_id = bmg.message_id
  WHERE bmg.bug_number IS NOT null
  UNION
  SELECT DISTINCT
    fhs.group_ord AS item_ord,
    cbr.bug_number
  FROM full_hashes AS fhs
  INNER JOIN {{ ref('int_commit_bug_refs') }} AS cbr ON fhs.full_hash = cbr.commit_hash
)

SELECT DISTINCT
  lnk.item_ord,
  lnk.bug_number
FROM linked AS lnk
INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON lnk.bug_number = rpt.bug_number
