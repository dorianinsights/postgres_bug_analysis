{{ config(materialized='external', location='../data/derived/fix_change_profiles.csv', format='csv') }}

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
  n_annotated_commits,
  n_matched_commits,
  n_files,
  lines_added,
  lines_deleted,
  touches_tests::INTEGER AS touches_tests,
  docs_only::INTEGER AS docs_only
FROM {{ ref('int_fix_changes') }}
ORDER BY wave_dt, item_ord
