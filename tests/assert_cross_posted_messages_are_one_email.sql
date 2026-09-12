-- A message id archived on more than one list is one email cross-posted, so
-- its copies must agree on subject, send time and sender. The commit side
-- joins Discussion: trailers on the bare id on that assumption.
SELECT
  message_id,
  COUNT(*) AS copy_cnt,
  COUNT(DISTINCT COALESCE(subject, '')) AS subject_cnt,
  COUNT(DISTINCT sent_ts) AS sent_ts_cnt,
  COUNT(DISTINCT COALESCE(author_email, '')) AS author_cnt
FROM {{ ref('int_message_threads') }}
GROUP BY message_id
HAVING
  COUNT(*) > 1
  AND (
    COUNT(DISTINCT COALESCE(subject, '')) > 1
    OR COUNT(DISTINCT sent_ts) > 1
    OR COUNT(DISTINCT COALESCE(author_email, '')) > 1
  )
