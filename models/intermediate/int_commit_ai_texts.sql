-- The commit text the AI-involvement classifier reads, one per COMMITTED FIX
-- (fix_key): a fix's backpatches share one message, so classifying per commit
-- would re-read the same disclosure N times. The representative text is the
-- longest message among the fix's commits (a backpatch body sometimes adds a
-- "Back-patch to ..." line; the longest carries every credit line), capped at
-- var(ai_involvement_text_cap_chars) -- a disclosure lives in the first screen
-- and prompt length is the per-item cost. Every commit is in scope, housekeeping
-- included: the classifier, not a keyword filter, decides what is a disclosure.
-- Grain = fix_key.
SELECT
  fix_key,
  commit_hash AS text_commit_hash,
  LEFT(subject || CHR(10) || COALESCE(body, ''), {{ var('ai_involvement_text_cap_chars') }}) AS ai_text
FROM {{ ref('int_git_commits') }}
QUALIFY
  ROW_NUMBER() OVER (
    PARTITION BY fix_key
    ORDER BY LENGTH(COALESCE(body, '')) DESC, commit_ts DESC, commit_hash ASC
  ) = 1
