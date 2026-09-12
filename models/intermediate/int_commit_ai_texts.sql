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
