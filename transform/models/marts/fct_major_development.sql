-- Per-major feature-development activity: everything developed FOR each major,
-- by exact git tag ancestry (commits in REL_(M-1)_0..REL_M_0, or ..the branch
-- HEAD for the in-progress major). Carries dev_status (released / beta), the
-- latest milestone (GA / BETA3 / RC1 / ...), the development commit count, and the
-- first/last development commit (day, instant, hash). Covers every major at/above
-- the corpus floor with a stable branch -- INCLUDING the in-progress one (e.g.
-- PG19 in beta) -- discovered from the repo, so a new major appears with no
-- LAST_MAJOR to bump. Distinct from fct_commit_files (post-GA backpatch minors on
-- the stable branches): this is the pre-GA feature development on master + the
-- stabilizing branch. major is a degenerate key (the in-progress major is not in
-- dim_major, which is released majors + master); the dev-commit days conform to
-- dim_date. Grain = major. -> ../data/derived/fct_major_development.csv
SELECT
  dmj.dim_major_key,
  smd.major,
  smd.dev_status,
  smd.latest_milestone,
  smd.dev_commit_cnt,
  smd.first_dev_commit_dt,
  smd.first_dev_commit_ts,
  smd.first_dev_commit_hash,
  smd.last_dev_commit_dt,
  smd.last_dev_commit_ts,
  smd.last_dev_commit_hash
FROM {{ ref('int_major_development') }} AS smd
INNER JOIN {{ ref('dim_major') }} AS dmj ON smd.major = dmj.major
