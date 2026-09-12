-- int_commit_versions calls an unmapped non-master commit 'open' because the
-- tag-ancestry mapping maps every commit on an in-progress major's branch to
-- its .0, so only released majors' branches carry unmapped commits. A row here
-- means that rule broke: a pending commit on a branch with no GA tag.
SELECT
  icv.branch,
  COUNT(*) AS open_commit_cnt
FROM {{ ref('int_commit_versions') }} AS icv
LEFT OUTER JOIN {{ ref('int_versions') }} AS gav
  ON gav.is_major_release AND icv.branch = gav.stable_branch
WHERE icv.release_status = 'open' AND gav.major IS null
GROUP BY icv.branch
