-- Atomic churn fact: one row per file touched by one commit -- the lowest grain
-- of the git change stream. Every churn metric (by area, file type, branch scope,
-- author, at any interval) rolls up from here dynamically, so no metric needs a
-- pre-aggregated table; a MetricFlow semantic model (fct_commit_files_semantic)
-- exposes the measures, joined to dim_commit on the commit entity for commit-level
-- slicing. Conforms to dim_commit (dim_commit_key -- the commit's attributes,
-- keys and branch_scope live there) and to dim_date on commit_dt (the
-- fact carries its own event day). subsystem and file_class ride along as
-- file-grain degenerate dimensions. Line counts are NULL for binary files (git
-- numstat '-'), so SUMs naturally exclude binary churn.
-- Grain = (dim_commit_key, file_path).
SELECT
  dcm.dim_commit_key,
  dcm.commit_dt,
  icf.file_path,
  icf.subsystem,
  icf.file_class,
  icf.lines_added,
  icf.lines_deleted
FROM {{ ref('int_commit_files') }} AS icf
INNER JOIN {{ ref('dim_commit') }} AS dcm ON icf.commit_hash = dcm.commit_hash
