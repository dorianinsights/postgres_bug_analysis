-- Commit-grain enrichment: the analysis flags formerly computed in the
-- scraper, now derived here from the verbatim subject/body.
--
-- is_plumbing: release mechanics (stamps, translation refreshes, release
-- notes, pgindent runs) — not fixes; excluded by consumers.
-- ai_credit: the first line of the commit message that credits an AI tool
-- (trimmed, capped at 200 chars), NULL when none does. The pattern keeps
-- the LLM signal only — fuzzers are tracked separately in the
-- full-history analysis.
WITH flagged AS (
  SELECT
    branch,
    commit_hash,
    commit_ts,
    subject,
    body,
    REGEXP_MATCHES(
      subject,
      '^(Stamp |Translation updates|Update time zone data|Update plpgsql\.po'
      || '|First-draft release notes|Release notes for|Update release notes'
      || '|Last-minute updates for release notes|Re-pgindent|pgindent )',
      'i'
    ) AS is_plumbing,
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
  subject,
  body,
  is_plumbing,
  LEFT(TRIM(credit_lines[1]), 200) AS ai_credit
FROM flagged
