-- The bridge from a distinct fix (dedup group) to the git commits that
-- implement it: the fix's whole group -> its annotated 9-char hashes (from
-- item_commits) -> the matching full corpus commits. Extracted here because
-- int_fix_changes, int_fix_origins and int_fix_bug_links all rebuilt this same
-- abbrev->full hash match. commit_hash is NULL for annotation hashes that match
-- no corpus commit (pre-corpus REL9_x branches), so consumers can still count
-- annotation coverage. Grain = (group_ord, abbrev_hash, commit_hash).
WITH fix_hashes AS (
  SELECT DISTINCT
    grp.group_ord,
    itc.commit_hash AS abbrev_hash
  FROM {{ ref('int_fix_groups') }} AS grp
  INNER JOIN {{ ref('int_fix_items') }} AS itm ON grp.item_ord = itm.item_ord
  INNER JOIN {{ ref('stg_item_commits') }} AS itc
    ON itm.version = itc.version AND itm.item_index = itc.item_index
),

corpus_commits AS (
  SELECT DISTINCT
    commit_hash,
    branch,
    commit_ts
  FROM {{ ref('stg_git_commits') }}
)

SELECT
  fhs.group_ord,
  fhs.abbrev_hash,
  cmt.commit_hash,
  cmt.branch,
  cmt.commit_ts
FROM fix_hashes AS fhs
LEFT JOIN corpus_commits AS cmt ON LEFT(cmt.commit_hash, 9) = fhs.abbrev_hash
