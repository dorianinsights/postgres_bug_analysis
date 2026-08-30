-- The fixes already committed toward the NEXT scheduled minor but not yet
-- released — the pending wave. Same supply-side signal the projection
-- models use (fix_projection_cycles' early_fixes): backpatched, non-plumbing
-- stable-branch commits since the last wrap (the content cutoff of the wave
-- that already shipped), deduped to distinct fixes by normalized subject
-- (a fix backpatched to N branches has N near-identical subjects). Each
-- distinct fix is attributed to an origin from its commits via
-- int_commit_origins, with the same precedence as int_fix_origins: any
-- pgsql-bugs commit wins, else pgsql-hackers, else unknown_or_internal.
--
-- Caveat baked into the data: security fixes are embargoed and reach public
-- git only on wrap day, so this pending set is structurally missing all
-- security work until the wrap — its unknown_or_internal bucket is the
-- genuinely unsourced remainder, NOT embargoed security.
WITH last_wrap AS (
  SELECT MAX(wrap_dt) AS wrap_dt
  FROM {{ ref('int_release_calendar') }}
  WHERE wrap_dt <= CURRENT_DATE
),

pending_commits AS (
  SELECT
    bpf.commit_hash,
    bpf.fix_key
  FROM {{ ref('int_backpatch_fixes') }} AS bpf, last_wrap
  WHERE bpf.commit_dt > last_wrap.wrap_dt
),

commit_origins AS (
  SELECT
    pcm.fix_key,
    BOOL_OR(org.origin = 'pgsql-bugs') AS from_bugs,
    BOOL_OR(org.origin = 'pgsql-hackers') AS from_hackers
  FROM pending_commits AS pcm
  LEFT JOIN {{ ref('int_commit_origins') }} AS org
    ON pcm.commit_hash = org.commit_hash
  GROUP BY ALL
)

SELECT
  fix_key,
  CASE
    WHEN from_bugs THEN 'pgsql-bugs'
    WHEN from_hackers THEN 'pgsql-hackers'
    ELSE 'unknown_or_internal'
  END AS origin
FROM commit_origins
