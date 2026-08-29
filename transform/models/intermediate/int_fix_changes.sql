-- What each distinct fix actually changed, from git: the annotation hashes
-- (via the fix's whole dedup group) matched to corpus commits, then the
-- REPRESENTATIVE commit's files classified by path into subsystems.
--
-- Representative commit: the annotated commit on master when there is one,
-- else the most recent matched commit — a fix backpatched to N branches has
-- N near-identical commits, so profiling one avoids N-fold inflation.
--
-- The abbrev -> full hash match uses LEFT(hash, 9): every annotation hash
-- is 9 chars (pinned by a test on stg_item_commits — if git ever abbreviates
-- longer, that test fails and this join key must follow). Annotated commits
-- on pre-corpus branches (REL9_x era) legitimately match nothing;
-- matched_commit_cnt < annotated_commit_cnt records the coverage.
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
),

matched AS (
  SELECT DISTINCT
    fhs.group_ord,
    fhs.abbrev_hash,
    cmt.commit_hash,
    cmt.branch,
    cmt.commit_ts
  FROM fix_hashes AS fhs
  INNER JOIN corpus_commits AS cmt ON LEFT(cmt.commit_hash, 9) = fhs.abbrev_hash
),

coverage AS (
  SELECT
    fhs.group_ord,
    COUNT(DISTINCT fhs.abbrev_hash) AS annotated_commit_cnt,
    COUNT(DISTINCT mat.abbrev_hash) AS matched_commit_cnt
  FROM fix_hashes AS fhs
  LEFT JOIN matched AS mat
    ON fhs.group_ord = mat.group_ord AND fhs.abbrev_hash = mat.abbrev_hash
  GROUP BY ALL
),

rep_commit AS (
  SELECT
    group_ord,
    commit_hash
  FROM matched
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY group_ord
    ORDER BY (branch = 'master') DESC, commit_ts DESC, commit_hash ASC
  ) = 1
),

file_rules AS (
  SELECT
    cfl.commit_hash,
    cfl.file_path,
    MIN(rules.match_order) AS match_order
  FROM {{ ref('stg_commit_files') }} AS cfl
  INNER JOIN {{ ref('subsystem_rules') }} AS rules
    ON REGEXP_MATCHES(cfl.file_path, rules.pattern)
  GROUP BY ALL
),

file_subsystems AS (
  SELECT
    cfl.commit_hash,
    cfl.file_path,
    cfl.lines_added,
    cfl.lines_deleted,
    COALESCE(rules.subsystem, 'other') AS subsystem
  FROM {{ ref('stg_commit_files') }} AS cfl
  LEFT JOIN file_rules AS fru
    ON cfl.commit_hash = fru.commit_hash AND cfl.file_path = fru.file_path
  LEFT JOIN {{ ref('subsystem_rules') }} AS rules ON fru.match_order = rules.match_order
),

rep_files AS (
  SELECT
    rpc.group_ord,
    fsy.file_path,
    fsy.lines_added,
    fsy.lines_deleted,
    fsy.subsystem
  FROM rep_commit AS rpc
  INNER JOIN file_subsystems AS fsy ON rpc.commit_hash = fsy.commit_hash
),

profile AS (
  SELECT
    group_ord,
    COUNT(*) AS file_cnt,
    SUM(COALESCE(lines_added, 0))::BIGINT AS lines_added_sum,
    SUM(COALESCE(lines_deleted, 0))::BIGINT AS lines_deleted_sum,
    MAX(subsystem = 'tests') AS has_test_changes,
    MIN(subsystem = 'docs') AS is_docs_only
  FROM rep_files
  GROUP BY ALL
),

-- Fix-level subsystem = weighted vote over the representative commit's
-- files (most files, then most lines); tests/docs only win when nothing
-- else changed.
dominant AS (
  SELECT
    group_ord,
    subsystem AS dominant_subsystem
  FROM (
    SELECT
      group_ord,
      subsystem,
      COUNT(*) AS file_cnt,
      SUM(COALESCE(lines_added, 0) + COALESCE(lines_deleted, 0)) AS line_sum
    FROM rep_files
    GROUP BY ALL
  ) AS votes
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY group_ord
    ORDER BY (subsystem IN ('tests', 'docs')) ASC, file_cnt DESC, line_sum DESC, subsystem ASC
  ) = 1
)

SELECT
  reps.item_ord,
  reps.wave_dt,
  reps.version,
  reps.item_index,
  reps.category,
  cov.annotated_commit_cnt,
  cov.matched_commit_cnt,
  prf.file_cnt,
  prf.lines_added_sum,
  prf.lines_deleted_sum,
  prf.has_test_changes,
  prf.is_docs_only,
  dom.dominant_subsystem
FROM {{ ref('int_fix_reps') }} AS reps
LEFT JOIN coverage AS cov ON reps.item_ord = cov.group_ord
LEFT JOIN profile AS prf ON reps.item_ord = prf.group_ord
LEFT JOIN dominant AS dom ON reps.item_ord = dom.group_ord
