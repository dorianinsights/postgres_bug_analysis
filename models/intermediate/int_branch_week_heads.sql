WITH branch_commits AS (
  SELECT
    branch,
    commit_hash,
    commit_ts,
    commit_dt,
    parent_hash
  FROM {{ ref('stg_git_commits') }}
  WHERE branch != 'master'
),

-- every Monday from each branch's first week through the current one. The
-- first week (the first point of its line on the "codebase size over time"
-- chart) is its GA release day's (the .0), or, for the in-progress major with
-- no GA yet, its first own commit's. Either way the first week holds at least
-- one of the branch's commits, so every week has a head
weeks AS (
  SELECT
    bcm.branch,
    UNNEST(
      GENERATE_SERIES(
        DATE_TRUNC('week', COALESCE(MIN(gav.release_dt), MIN(bcm.commit_dt))),
        DATE_TRUNC('week', {{ as_of_date() }}),
        INTERVAL 1 WEEK
      )
    )::DATE AS week_start
  FROM branch_commits AS bcm
  LEFT OUTER JOIN {{ ref('int_versions') }} AS gav
    ON bcm.branch = gav.stable_branch AND gav.is_major_release
  GROUP BY ALL
),

-- on a linear branch each commit is the head from the moment it lands until
-- its child lands (the branch tip: until var('future_eternity'), so the week
-- join below is a plain range join). Following the edges rather than comparing
-- commit times keeps commits pushed together, which share a committer second,
-- in their true order: a commit whose child lands in the same second has an
-- empty span and is never a week's head
head_spans AS (
  SELECT
    bcm.branch,
    bcm.commit_hash,
    bcm.commit_ts AS head_from_ts,
    COALESCE(chd.commit_ts, {{ future_eternity_dt() }}::TIMESTAMP AT TIME ZONE 'utc') AS head_until_ts
  FROM branch_commits AS bcm
  LEFT OUTER JOIN branch_commits AS chd
    ON bcm.branch = chd.branch AND bcm.commit_hash = chd.parent_hash
)

-- the head at each week's end (the next Monday, 00:00 UTC): the commit whose
-- span holds that instant. From the week list, so a week with no head
-- surfaces as a NULL commit_hash (which the not_null test fails) rather than
-- a silently missing week
SELECT
  wks.branch,
  wks.week_start,
  hsp.commit_hash
FROM weeks AS wks
LEFT OUTER JOIN head_spans AS hsp
  ON
    wks.branch = hsp.branch
    AND (wks.week_start + INTERVAL 1 WEEK)::TIMESTAMP AT TIME ZONE 'utc' > hsp.head_from_ts
    AND (wks.week_start + INTERVAL 1 WEEK)::TIMESTAMP AT TIME ZONE 'utc' <= hsp.head_until_ts
