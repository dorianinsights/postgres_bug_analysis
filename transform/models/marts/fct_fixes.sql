-- Fix-grain fact: one row per distinct fix (replaces the Round A fix_impact).
-- Change size (int_fix_changes), worst CVE severity denormalized from
-- int_fix_severity, and the bug linkage from int_fix_bug_links, with a
-- dim_release_key FK into dim_release and a dim_version_key FK into dim_version
-- (both resolved by joining the dimension on its natural key, so the surrogate
-- is defined only in the dim). The many-to-many CVE and bug detail lives
-- in bridge_fix_cve / bridge_fix_bug; here we keep the worst severity and the
-- primary (fastest-resolved) bug for convenient single-row analysis.
-- Grain = item_ord. -> ../data/derived/fct_fixes.csv
WITH group_sizes AS (
  SELECT
    group_ord,
    COUNT(*) AS branch_item_cnt
  FROM {{ ref('int_fix_groups') }}
  GROUP BY ALL
),

bug_agg AS (
  SELECT
    fbl.item_ord,
    COUNT(*)::BIGINT AS bug_link_cnt,
    MIN(ibo.days_to_commit) AS days_to_fix_min
  FROM {{ ref('int_fix_bug_links') }} AS fbl
  LEFT JOIN {{ ref('int_bug_outcomes') }} AS ibo ON fbl.bug_number = ibo.bug_number
  GROUP BY ALL
),

primary_bug AS (
  SELECT
    fbl.item_ord,
    fbl.bug_number AS primary_bug_number
  FROM {{ ref('int_fix_bug_links') }} AS fbl
  LEFT JOIN {{ ref('int_bug_outcomes') }} AS ibo ON fbl.bug_number = ibo.bug_number
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY fbl.item_ord ORDER BY ibo.days_to_commit ASC NULLS LAST, fbl.bug_number ASC
  ) = 1
)

SELECT
  chg.item_ord,
  COALESCE(drl.dim_release_key, {{ unknown_key() }}) AS dim_release_key,
  chg.wave_dt,
  COALESCE(dvr.dim_version_key, {{ unknown_key() }}) AS dim_version_key,
  chg.item_index,
  reps.summary,
  reps.full_text,
  reps.cves,
  chg.category,
  cats.category_order,
  chg.dominant_subsystem,
  fio.origin,
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
  COALESCE(bag.bug_link_cnt, 0) AS bug_link_cnt,
  COALESCE(dbg.dim_bug_key, {{ not_applicable_key() }}) AS primary_dim_bug_key,
  bag.days_to_fix_min
FROM {{ ref('int_fix_changes') }} AS chg
INNER JOIN group_sizes AS grp ON chg.item_ord = grp.group_ord
INNER JOIN {{ ref('int_fix_reps') }} AS reps ON chg.item_ord = reps.item_ord
INNER JOIN {{ ref('categories') }} AS cats ON chg.category = cats.category
INNER JOIN {{ ref('int_waves') }} AS waves ON chg.wave_dt = waves.wave_dt
LEFT JOIN {{ ref('int_fix_severity') }} AS sev ON chg.item_ord = sev.item_ord
LEFT JOIN {{ ref('int_fix_origins') }} AS fio ON chg.item_ord = fio.group_ord
LEFT JOIN bug_agg AS bag ON chg.item_ord = bag.item_ord
LEFT JOIN primary_bug AS pbg ON chg.item_ord = pbg.item_ord
-- resolve the surrogate keys from the dimensions (defined once, there) rather
-- than recomputing the hashes here
LEFT JOIN {{ ref('dim_release') }} AS drl ON chg.wave_dt = drl.release_dt
LEFT JOIN {{ ref('dim_version') }} AS dvr ON chg.version = dvr.version
LEFT JOIN {{ ref('dim_bug') }} AS dbg ON pbg.primary_bug_number = dbg.bug_number
