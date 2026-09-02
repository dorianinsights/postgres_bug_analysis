-- The COMMITTED-fix population, one row per distinct fix per release: every
-- non-housekeeping commit on a released major's stable branch, collapsed by
-- fix_key (normalized subject -- a fix backpatched to N branches is N commits,
-- one row here) within the release it ships in (int_commit_versions: exact tag
-- ancestry for shipped releases, the open release for not-yet-tagged commits).
--
-- This is the commit-side counterpart of int_fix_reps (the DOCUMENTED fixes,
-- one row per release-notes item). The two populations differ by construction:
-- the notes author folds several commits into one item and documents only
-- ~half of the committed subjects (typo fixes, test additions, dead-code
-- removal and comment cleanups never get an item). is_documented /
-- documented_item_ord link each committed fix to its item through the notes'
-- commit annotations (int_fix_commits), so the documented-per-committed rate
-- is measurable per release and per origin -- that rate is what turns the open
-- release's committed-so-far count into a projection in documented units.
--
-- origin uses the same precedence as the documented fixes (resolve_fix_origin);
-- a committed fix is security work when its item cites a CVE, so the open
-- release (no items yet, and embargoed security lands only on wrap day) never
-- shows security. Replaces int_backpatch_fixes + int_pending_fixes, which
-- windowed the same commits by calendar date. Grain = (release_dt, fix_key).
WITH stable_commits AS (
  SELECT
    igc.branch,
    igc.commit_hash,
    igc.commit_dt,
    igc.fix_key,
    icv.ship_release_dt AS release_dt
  FROM {{ ref('int_git_commits') }} AS igc
  INNER JOIN {{ ref('int_commit_versions') }} AS icv
    ON igc.branch = icv.branch AND igc.commit_hash = icv.commit_hash
  -- release_status is set only for released majors' stable branches
  WHERE icv.release_status IS NOT null AND NOT igc.is_housekeeping
),

commit_facts AS (
  SELECT
    stc.release_dt,
    stc.fix_key,
    stc.branch,
    stc.commit_hash,
    stc.commit_dt,
    org.origin,
    fcm.group_ord AS documented_item_ord,
    reps.cves IS NOT null AS is_security_item
  FROM stable_commits AS stc
  LEFT JOIN {{ ref('int_commit_origins') }} AS org ON stc.commit_hash = org.commit_hash
  LEFT JOIN {{ ref('int_fix_commits') }} AS fcm ON stc.commit_hash = fcm.commit_hash
  LEFT JOIN {{ ref('int_fix_reps') }} AS reps ON fcm.group_ord = reps.item_ord
),

rollup AS (
  SELECT
    release_dt,
    fix_key,
    MIN(commit_dt) AS first_commit_dt,
    MAX(commit_dt) AS last_commit_dt,
    -- DISTINCT: a commit annotated under two items appears twice in commit_facts
    COUNT(DISTINCT commit_hash) AS commit_cnt,
    COUNT(DISTINCT branch) AS branch_cnt,
    BOOL_OR(origin = 'pgsql-bugs') AS from_bugs,
    BOOL_OR(origin = 'pgsql-hackers') AS from_hackers,
    BOOL_OR(documented_item_ord IS NOT null) AS is_documented,
    -- the lowest item when a combined commit is annotated under several
    MIN(documented_item_ord) AS documented_item_ord,
    BOOL_OR(is_security_item) AS is_security
  FROM commit_facts
  GROUP BY ALL
)

SELECT
  release_dt,
  fix_key,
  first_commit_dt,
  last_commit_dt,
  commit_cnt,
  branch_cnt,
  is_documented,
  documented_item_ord,
  is_security,
  {{ resolve_fix_origin('from_bugs', 'from_hackers', 'is_security') }} AS origin
FROM rollup
