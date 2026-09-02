-- Commit-grain enrichment: the analysis flags formerly computed in the
-- scraper, now derived here from the verbatim subject/body.
--
-- fix_key: the normalized subject (lowercased, whitespace collapsed) -- the
-- identity of a COMMITTED fix. PostgreSQL backpatches by cherry-picking, so the
-- same fix on N branches is N commits with N hashes but one subject; every
-- distinct-fix count on the commit side is COUNT(DISTINCT fix_key). Defined
-- once here (int_committed_fixes, dim_commit and the faces all read it).
-- is_housekeeping: release mechanics that are commits but not fixes -- version
-- stamps, translation catalog refreshes, release-notes drafting, time-zone data
-- refreshes, copyright bumps, pgindent runs. Excluded from every fix count.
-- ai_credit: the first line of the commit message that credits an AI tool
-- (trimmed, capped at 200 chars), NULL when none does. The pattern keeps
-- the LLM signal only — fuzzers are tracked separately in the
-- full-history analysis.
-- patch_author_*: the REAL patch author. PostgreSQL sets the git author
-- (%an/%ae) to the committer and credits the contributor in the body's
-- "Author: Name <email>" trailer (present on ~42% of commits — the rest are
-- written by the committer). So the patch author is that trailer when present,
-- else the committer (%cn/%ce). committer_* is passed through unchanged.
WITH flagged AS (
  SELECT
    branch,
    commit_hash,
    commit_ts,
    commit_dt,
    subject,
    body,
    committer_name,
    committer_email,
    NULLIF(TRIM(REGEXP_EXTRACT(body, 'Author:\s*([^<\n]+?)\s*<([^>\n]+)>', 1)), '') AS body_author_name,
    NULLIF(TRIM(REGEXP_EXTRACT(body, 'Author:\s*([^<\n]+?)\s*<([^>\n]+)>', 2)), '') AS body_author_email,
    LIST_FILTER(
      STRING_SPLIT(subject || CHR(10) || COALESCE(body, ''), CHR(10)),
      line -> REGEXP_MATCHES(
        line,
        '\b(Claude( Code)?|Anthropic|ChatGPT|GPT-[45]|OpenAI|Copilot|Big Sleep|large language model|LLM)\b',
        'i'
      )
    ) AS credit_lines
  FROM {{ ref('stg_git_commits') }}
)

SELECT
  branch,
  commit_hash,
  commit_ts,
  commit_dt,
  subject,
  body,
  committer_name,
  committer_email,
  COALESCE(body_author_name, committer_name) AS patch_author_name,
  COALESCE(body_author_email, committer_email) AS patch_author_email,
  LOWER(TRIM(REGEXP_REPLACE(subject, '\s+', ' ', 'g'))) AS fix_key,
  REGEXP_MATCHES(
    subject,
    '^(stamp |translation updates|(first-draft |second-draft |last-minute updates for )?release notes'
    || '|docs?: .*release notes|update time zone data|update copyright|re-?pgindent|bump catversion)',
    'i'
  ) AS is_housekeeping,
  LEFT(TRIM(credit_lines[1]), 200) AS ai_credit
FROM flagged
