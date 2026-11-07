WITH per_commit AS (
  SELECT
    commit_hash,
    BOOL_OR(source_list = 'pgsql-bugs') AS has_bugs_thread,
    BOOL_OR(source_list = 'pgsql-hackers') AS has_hackers_thread
  FROM {{ ref('int_commit_discussions') }}
  GROUP BY ALL
),

-- the release-notes item citing the commit: the lowest item when a combined
-- commit is annotated under several, security if any of them cites a CVE
documented AS (
  SELECT
    fcm.commit_hash,
    MIN(fcm.group_ord) AS documented_item_ord,
    BOOL_OR(reps.cves IS NOT null) AS is_documented_security
  FROM {{ ref('int_fix_commits') }} AS fcm
  INNER JOIN {{ ref('int_fix_reps') }} AS reps ON fcm.group_ord = reps.item_ord
  WHERE fcm.commit_hash IS NOT null
  GROUP BY ALL
),

-- the minor-release notes annotate a security fix's stable-branch commits but
-- not always its master commit, so the fix is carried to master by fix_key,
-- for the release each annotated commit shipped in
security_fix_releases AS (
  SELECT DISTINCT
    sgc.fix_key,
    icv.ship_release_dt
  FROM documented AS sdf
  INNER JOIN {{ ref('int_git_commits') }} AS sgc ON sdf.commit_hash = sgc.commit_hash
  INNER JOIN {{ ref('int_commit_versions') }} AS icv ON sdf.commit_hash = icv.commit_hash
  WHERE sdf.is_documented_security AND icv.release_status = 'shipped'
),

-- the release a master commit's backpatches ship in: the first shipped release
-- wrapped on or after it. Matching on it keeps an older master commit out (one
-- backpatched cycles later as groundwork for a security fix was ordinary
-- development when it landed)
master_ship AS (
  SELECT
    mgc.commit_hash,
    mgc.fix_key,
    MIN(rel.release_dt) AS ship_release_dt
  FROM {{ ref('int_git_commits') }} AS mgc
  INNER JOIN {{ ref('int_releases') }} AS rel ON mgc.commit_dt <= rel.wrap_dt
  WHERE mgc.branch = 'master' AND rel.status = 'shipped'
  GROUP BY ALL
),

master_security AS (
  SELECT DISTINCT msh.commit_hash
  FROM master_ship AS msh
  INNER JOIN security_fix_releases AS sfr
    ON msh.fix_key = sfr.fix_key AND msh.ship_release_dt = sfr.ship_release_dt
)

SELECT
  gcm.commit_hash,
  CASE
    WHEN COALESCE(pcm.has_bugs_thread, false) OR gcm.bug_refs IS NOT null THEN 'pgsql-bugs'
    WHEN COALESCE(pcm.has_hackers_thread, false) THEN 'pgsql-hackers'
    ELSE 'unknown_or_internal'
  END AS origin,
  dfx.documented_item_ord,
  COALESCE(dfx.is_documented_security, false) AS is_documented_security,
  COALESCE(dfx.is_documented_security, false) OR mse.commit_hash IS NOT null AS is_security_fix
FROM {{ ref('int_git_commits') }} AS gcm
LEFT OUTER JOIN per_commit AS pcm ON gcm.commit_hash = pcm.commit_hash
LEFT OUTER JOIN documented AS dfx ON gcm.commit_hash = dfx.commit_hash
LEFT OUTER JOIN master_security AS mse ON gcm.commit_hash = mse.commit_hash
