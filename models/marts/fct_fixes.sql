-- Fix-grain fact: one row per distinct fix (replaces the Round A fix_impact).
-- Change size (int_fix_changes), the worst CVE severity (rolled up here from
-- int_fix_cves x stg_cve_severity), and the bug linkage from int_fix_bug_links,
-- with a dim_release_key FK into dim_release and a dim_version_key FK into
-- dim_version (both resolved by joining the dimension on its natural key, so
-- the surrogate is defined only in the dim). The many-to-many CVE and bug
-- detail lives in bridge_fix_cve / bridge_fix_bug; here we keep the worst
-- severity and the primary (fastest-resolved) bug for convenient single-row
-- analysis. Grain = item_ord. -> data/derived/fct_fixes.csv
WITH group_sizes AS (
  SELECT
    group_ord,
    COUNT(*) AS branch_item_cnt
  FROM {{ ref('int_fix_groups') }}
  GROUP BY ALL
),

-- the primary bug is the fastest-resolved linked report
bug_agg AS (
  SELECT
    fbl.item_ord,
    COUNT(*)::BIGINT AS bug_link_cnt,
    MIN(rpt.days_to_commit) AS days_to_fix_min,
    FIRST(fbl.bug_number ORDER BY rpt.days_to_commit ASC NULLS LAST, fbl.bug_number ASC) AS primary_bug_number
  FROM {{ ref('int_fix_bug_links') }} AS fbl
  INNER JOIN {{ ref('int_bug_reports') }} AS rpt ON fbl.bug_number = rpt.bug_number
  GROUP BY ALL
),

-- the worst CVE's score and band (banded per CVE in stg_cve_severity; the band
-- is monotonic in the score, so the max-score CVE carries it)
severity AS (
  SELECT
    fcv.item_ord,
    COUNT(*)::BIGINT AS cve_cnt,
    COUNT(sev.cvss_base_score)::BIGINT AS scored_cve_cnt,
    MAX(sev.cvss_base_score) AS max_cvss_base_score,
    ARG_MAX(sev.severity_band, sev.cvss_base_score) AS severity_band,
    ARG_MAX(sev.severity_band_order, sev.cvss_base_score) AS severity_band_order
  FROM {{ ref('int_fix_cves') }} AS fcv
  LEFT JOIN {{ ref('stg_cve_severity') }} AS sev ON fcv.cve_id = sev.cve_id
  GROUP BY ALL
)

SELECT
  chg.item_ord,
  COALESCE(drl.dim_release_key, {{ unknown_key() }}) AS dim_release_key,
  COALESCE(dvr.dim_version_key, {{ unknown_key() }}) AS dim_version_key,
  COALESCE(dbg.dim_bug_key, {{ not_applicable_key() }}) AS primary_dim_bug_key,
  chg.release_dt,
  chg.item_index,
  reps.summary,
  reps.full_text,
  reps.cves,
  -- 'unclassified' when the build ran in cached-only mode (Ollama absent) and
  -- this fix's text was new: an explicit bucket rather than a dropped row, so
  -- the fact keeps its one-row-per-fix grain; is_classified says which
  COALESCE(cls.category_content, 'unclassified') AS category,
  cats.category_order,
  cls.is_security_hardening,
  cls.is_performance,
  cls.is_classified,
  chg.dominant_subsystem,
  fio.origin,
  releases.is_out_of_band,
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
  -- ordinal companion to severity_band for chart sorting; NULL for non-CVE fixes
  sev.severity_band_order,
  COALESCE(bag.bug_link_cnt, 0) AS bug_link_cnt,
  bag.days_to_fix_min
FROM {{ ref('int_fix_changes') }} AS chg
INNER JOIN group_sizes AS grp ON chg.item_ord = grp.group_ord
INNER JOIN {{ ref('int_fix_reps') }} AS reps ON chg.item_ord = reps.item_ord
INNER JOIN {{ ref('int_fix_content_categories') }} AS cls ON chg.item_ord = cls.item_ord
LEFT JOIN {{ ref('content_categories') }} AS cats ON cls.category_content = cats.category
INNER JOIN {{ ref('int_releases') }} AS releases ON chg.release_dt = releases.release_dt
LEFT JOIN severity AS sev ON chg.item_ord = sev.item_ord
LEFT JOIN {{ ref('int_fix_origins') }} AS fio ON chg.item_ord = fio.group_ord
LEFT JOIN bug_agg AS bag ON chg.item_ord = bag.item_ord
-- resolve the surrogate keys from the dimensions (defined once, there) rather
-- than recomputing the hashes here
LEFT JOIN {{ ref('dim_release') }} AS drl ON chg.release_dt = drl.release_dt
LEFT JOIN {{ ref('dim_version') }} AS dvr ON chg.version = dvr.version
LEFT JOIN {{ ref('dim_bug') }} AS dbg ON bag.primary_bug_number = dbg.bug_number
