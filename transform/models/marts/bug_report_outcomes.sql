-- One row per numbered pgsql-bugs report: was it acted upon (linked to a
-- commit via Discussion: trailer or bug-number mention), and how fast.
-- The classification columns live here rather than in the faces so every
-- report shares one definition: outcome labels the is_acted_upon flag,
-- and the *_window buckets carry numeric prefixes so a lexical sort is
-- the intended order.
SELECT
  bug_number,
  reported_dt,
  subject,
  thread_message_cnt,
  CASE
    WHEN thread_message_cnt = 1 THEN '1: no replies'
    WHEN thread_message_cnt <= 3 THEN '2: 2-3 messages'
    WHEN thread_message_cnt <= 10 THEN '3: 4-10 messages'
    ELSE '4: 11+ messages'
  END AS thread_size_window,
  is_acted_upon,
  CASE
    WHEN is_acted_upon THEN 'linked to a fix commit'
    ELSE 'no linked commit'
  END AS outcome,
  linked_via,
  first_commit_dt,
  days_to_commit,
  CASE
    WHEN days_to_commit <= 1 THEN '1: same/next day'
    WHEN days_to_commit <= 7 THEN '2: within a week'
    WHEN days_to_commit <= 30 THEN '3: within a month'
    WHEN days_to_commit <= 180 THEN '4: within 6 months'
    WHEN days_to_commit > 180 THEN '5: longer'
  END AS days_to_commit_window
FROM {{ ref('int_bug_outcomes') }}
