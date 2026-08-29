-- One row per distinct fix: what its representative commit actually
-- changed (size, tests, docs) and the path-derived dominant subsystem,
-- alongside the keyword category — the raw material for validating the
-- keyword categorizer against ground truth from the tree.
SELECT
  wave_dt,
  version,
  item_index,
  category,
  dominant_subsystem,
  annotated_commit_cnt,
  matched_commit_cnt,
  file_cnt,
  lines_added_sum,
  lines_deleted_sum,
  has_test_changes,
  is_docs_only
FROM {{ ref('int_fix_changes') }}
