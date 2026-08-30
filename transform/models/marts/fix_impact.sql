-- One row per distinct fix with an impact profile: how big the change was
-- (files, line churn — from int_fix_changes), how severe it was (worst CVSS
-- v3 base score + band for CVE fixes — from int_fix_severity), and the
-- outcomes to correlate against: report->fix latency, backpatch breadth
-- (branch_item_cnt), and whether it shipped in an out-of-band emergency
-- wave. The raw material for "does impact / size affect timeline to fix and
-- inclusion across releases?". Grain = one distinct fix (item_ord).
--
-- Latency links a fix back to its pgsql-bugs report(s) through the fix's
-- annotated commits (abbrev hash -> full hash -> Discussion:/Bug: refs ->
-- bug number) and reuses int_bug_outcomes' report-to-commit days, taking
-- the minimum across linked reports. NULL for fixes with no linked report.
WITH group_sizes AS (
  SELECT
    group_ord,
    COUNT(*) AS branch_item_cnt
  FROM {{ ref('int_fix_groups') }}
  GROUP BY ALL
),

fix_commit_hashes AS (
  SELECT DISTINCT
    grp.group_ord,
    itc.commit_hash AS abbrev_hash
  FROM {{ ref('int_fix_groups') }} AS grp
  INNER JOIN {{ ref('int_fix_items') }} AS itm ON grp.item_ord = itm.item_ord
  INNER JOIN {{ ref('stg_item_commits') }} AS itc
    ON itm.version = itc.version AND itm.item_index = itc.item_index
),

full_hashes AS (
  SELECT DISTINCT
    fch.group_ord,
    gcm.commit_hash AS full_hash
  FROM fix_commit_hashes AS fch
  INNER JOIN {{ ref('stg_git_commits') }} AS gcm
    ON LEFT(gcm.commit_hash, 9) = fch.abbrev_hash
),

bug_links AS (
  SELECT DISTINCT
    fhs.group_ord,
    bmg.bug_number
  FROM full_hashes AS fhs
  INNER JOIN {{ ref('int_commit_discussions') }} AS dsc ON fhs.full_hash = dsc.commit_hash
  INNER JOIN {{ ref('int_bug_messages') }} AS bmg ON dsc.message_id = bmg.message_id
  WHERE bmg.bug_number IS NOT null
  UNION
  SELECT DISTINCT
    fhs.group_ord,
    cbr.bug_number
  FROM full_hashes AS fhs
  INNER JOIN {{ ref('int_commit_bug_refs') }} AS cbr ON fhs.full_hash = cbr.commit_hash
),

latency AS (
  SELECT
    lnk.group_ord,
    MIN(bgo.days_to_commit) AS days_to_fix_min
  FROM bug_links AS lnk
  INNER JOIN {{ ref('int_bug_outcomes') }} AS bgo ON lnk.bug_number = bgo.bug_number
  WHERE bgo.days_to_commit IS NOT null
  GROUP BY ALL
)

SELECT
  chg.item_ord,
  chg.wave_dt,
  chg.version,
  chg.item_index,
  chg.category,
  chg.dominant_subsystem,
  waves.is_out_of_band,
  grp.branch_item_cnt,
  chg.file_cnt,
  chg.lines_added_sum,
  chg.lines_deleted_sum,
  chg.lines_added_sum + chg.lines_deleted_sum AS churn_sum,
  chg.has_test_changes,
  chg.is_docs_only,
  sev.cve_cnt,
  sev.scored_cve_cnt,
  sev.max_cvss_base_score,
  sev.severity_band,
  lat.days_to_fix_min
FROM {{ ref('int_fix_changes') }} AS chg
INNER JOIN group_sizes AS grp ON chg.item_ord = grp.group_ord
INNER JOIN {{ ref('int_waves') }} AS waves ON chg.wave_dt = waves.wave_dt
LEFT JOIN {{ ref('int_fix_severity') }} AS sev ON chg.item_ord = sev.item_ord
LEFT JOIN latency AS lat ON chg.item_ord = lat.group_ord
