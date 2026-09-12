SELECT
  dcm.dim_commit_key,
  dcm.commit_dt,
  dcm.commit_ts,
  icf.file_path,
  icf.subsystem,
  icf.file_class,
  icf.lines_added,
  icf.lines_deleted
FROM {{ ref('int_commit_files') }} AS icf
INNER JOIN {{ ref('dim_commit') }} AS dcm ON icf.commit_hash = dcm.commit_hash
