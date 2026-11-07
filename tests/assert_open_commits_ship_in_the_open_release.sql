-- a commit pending for the open release belongs to a major that release day
-- ships (int_releases.versions lists one minor per supported major); a commit
-- landed on a branch past its end of support counts toward no release. A row
-- here is a pending commit whose major the open release does not carry.
SELECT
  icv.branch,
  rel.versions,
  COUNT(*) AS open_commit_cnt
FROM {{ ref('int_commit_versions') }} AS icv
INNER JOIN {{ ref('int_releases') }} AS rel ON icv.ship_release_dt = rel.release_dt
INNER JOIN {{ ref('int_versions') }} AS gav
  ON gav.is_major_release AND icv.branch = gav.stable_branch
WHERE
  icv.release_status = 'open'
  AND NOT (' / ' || rel.versions) LIKE ('% ' || gav.major || '.%')
GROUP BY icv.branch, rel.versions
