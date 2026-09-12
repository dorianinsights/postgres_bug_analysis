WITH bug_agg AS (
  -- the primary bug is the fastest-resolved linked report
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
  prf.item_ord,
  COALESCE(drl.dim_release_key, {{ unknown_key() }}) AS dim_release_key,
  COALESCE(dvr.dim_version_key, {{ unknown_key() }}) AS dim_version_key,
  COALESCE(dbg.dim_bug_key, {{ not_applicable_key() }}) AS primary_dim_bug_key,
  prf.release_dt,
  prf.item_index,
  reps.summary,
  reps.full_text,
  reps.cves,
  -- 'unclassified' when the build ran cached-only (Ollama absent) and this
  -- fix's text was new; is_classified says which
  COALESCE(cls.category_content, 'unclassified') AS category,
  cats.category_order,
  cls.is_security_hardening,
  cls.is_performance,
  cls.is_classified,
  prf.dominant_subsystem,
  prf.origin,
  releases.is_out_of_band,
  reps.branch_item_cnt,
  prf.file_cnt,
  prf.lines_added_sum,
  prf.lines_deleted_sum,
  prf.lines_added_sum + prf.lines_deleted_sum AS churn_sum,
  prf.has_test_changes,
  prf.is_docs_only,
  sev.cve_cnt,
  sev.scored_cve_cnt,
  sev.max_cvss_base_score,
  sev.severity_band,
  -- ordinal companion to severity_band for chart sorting; NULL for non-CVE fixes
  sev.severity_band_order,
  COALESCE(bag.bug_link_cnt, 0) AS bug_link_cnt,
  bag.days_to_fix_min
FROM {{ ref('int_fix_profile') }} AS prf
INNER JOIN {{ ref('int_fix_reps') }} AS reps ON prf.item_ord = reps.item_ord
INNER JOIN {{ ref('int_fix_content_categories') }} AS cls ON prf.item_ord = cls.item_ord
LEFT JOIN {{ ref('content_categories') }} AS cats ON cls.category_content = cats.category
INNER JOIN {{ ref('int_releases') }} AS releases ON prf.release_dt = releases.release_dt
LEFT JOIN severity AS sev ON prf.item_ord = sev.item_ord
LEFT JOIN bug_agg AS bag ON prf.item_ord = bag.item_ord
-- surrogate keys come from the dimensions, never recomputed here
LEFT JOIN {{ ref('dim_release') }} AS drl ON prf.release_dt = drl.release_dt
LEFT JOIN {{ ref('dim_version') }} AS dvr ON prf.version = dvr.version
LEFT JOIN {{ ref('dim_bug') }} AS dbg ON bag.primary_bug_number = dbg.bug_number
