-- tag ancestry maps every commit on an in-progress major's branch to its .0,
-- so only released majors' branches carry unmapped commits: the ones
-- int_commit_versions calls pending for the open release, or none past the
-- major's end of support. A row here means that rule broke: an unmapped
-- non-master commit on a branch with no GA tag.
SELECT
  icv.branch,
  COUNT(*) AS unmapped_commit_cnt
FROM {{ ref('int_commit_versions') }} AS icv
LEFT OUTER JOIN {{ ref('int_versions') }} AS gav
  ON gav.is_major_release AND icv.branch = gav.stable_branch
WHERE icv.version IS null AND icv.branch != 'master' AND gav.major IS null
GROUP BY icv.branch
