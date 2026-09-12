WITH thread_messages AS (
  SELECT
    list_name,
    root_id,
    message_id,
    sent_dt
  FROM {{ ref('int_message_threads') }}
),

rollup AS (
  SELECT
    list_name,
    root_id,
    COUNT(*)::BIGINT AS message_cnt,
    MAX(sent_dt) AS last_message_dt
  FROM thread_messages
  GROUP BY ALL
),

-- every commit citing any message of the thread, with the commit's scope
citations AS (
  SELECT
    tms.list_name,
    tms.root_id,
    dcm.branch_scope,
    dcm.commit_dt
  FROM thread_messages AS tms
  INNER JOIN {{ ref('int_commit_discussions') }} AS dsc ON tms.message_id = dsc.message_id
  INNER JOIN {{ ref('dim_commit') }} AS dcm ON dsc.commit_hash = dcm.commit_hash
),

cite_rollup AS (
  SELECT
    list_name,
    root_id,
    BOOL_OR(branch_scope = 'trunk') AS is_cited_by_trunk,
    BOOL_OR(branch_scope = 'stable') AS is_cited_by_stable,
    BOOL_OR(branch_scope = 'beta') AS is_cited_by_beta,
    MIN(commit_dt) AS first_cite_dt
  FROM citations
  GROUP BY ALL
),

-- the thread's first action: cited, or (a form report) linked by a commit's
-- Bug: # trailer -- whichever came first
threads AS (
  SELECT
    fmg.list_name,
    fmg.message_id,
    fmg.sender_dim_person_key,
    fmg.dim_bug_key,
    fmg.sent_dt,
    fmg.sent_ts,
    fmg.is_thread_start,
    fmg.subject,
    rlp.message_cnt,
    rlp.last_message_dt,
    cte.root_id IS NOT null AS is_cited,
    COALESCE(cte.is_cited_by_trunk, false) AS is_cited_by_trunk,
    COALESCE(cte.is_cited_by_stable, false) AS is_cited_by_stable,
    COALESCE(cte.is_cited_by_beta, false) AS is_cited_by_beta,
    cte.first_cite_dt,
    LEAST(cte.first_cite_dt, CASE WHEN dbg.is_acted_upon THEN dbg.first_commit_dt END) AS first_action_dt
  FROM {{ ref('fct_messages') }} AS fmg
  INNER JOIN rollup AS rlp ON fmg.list_name = rlp.list_name AND fmg.message_id = rlp.root_id
  LEFT JOIN cite_rollup AS cte ON fmg.list_name = cte.list_name AND fmg.message_id = cte.root_id
  LEFT JOIN {{ ref('dim_bug') }} AS dbg ON fmg.dim_bug_key = dbg.dim_bug_key
  WHERE fmg.is_thread_root
)

SELECT
  thr.list_name,
  thr.message_id AS root_message_id,
  thr.sender_dim_person_key AS starter_dim_person_key,
  thr.dim_bug_key,
  thr.sent_dt AS started_dt,
  COALESCE(thr.first_cite_dt, {{ future_eternity_dt() }}) AS first_cite_dt,
  COALESCE(thr.first_action_dt, {{ future_eternity_dt() }}) AS first_action_dt,
  thr.sent_ts AS started_ts,
  thr.is_thread_start AS is_new_thread,
  thr.dim_bug_key != {{ not_applicable_key() }} AS is_form_report,
  thr.message_cnt,
  thr.last_message_dt,
  thr.is_cited,
  thr.is_cited_by_trunk,
  thr.is_cited_by_stable,
  thr.is_cited_by_beta,
  -- a multiply-cited thread counts once, by its most fix-like citation
  CASE
    WHEN thr.is_cited_by_stable THEN 'backpatched fix'
    WHEN thr.is_cited_by_beta THEN 'beta stabilization'
    WHEN thr.is_cited_by_trunk THEN 'trunk work'
    ELSE 'not cited'
  END AS outcome,
  thr.first_cite_dt - thr.sent_dt AS days_to_first_cite,
  thr.first_action_dt IS NOT null AS is_acted_upon,
  CASE
    WHEN thr.first_action_dt IS NOT null THEN 'linked to a fix commit'
    ELSE 'no linked commit'
  END AS action_outcome,
  thr.first_action_dt - thr.sent_dt AS days_to_action,
  ltw.label AS days_to_action_window,
  tsw.label AS thread_size_window,
  COALESCE(ail.has_ai_involvement, false) AS has_ai_involvement,
  COALESCE(ail.ai_found, false) AS ai_found,
  COALESCE(ail.ai_analyzed, false) AS ai_analyzed,
  COALESCE(ail.ai_authored, false) AS ai_authored,
  COALESCE(ail.ai_tooling, false) AS ai_tooling,
  COALESCE(ail.ai_mentioned_only, false) AS ai_mentioned_only,
  COALESCE(ail.ai_vendor, 'none') AS ai_vendor,
  COALESCE(ail.ai_disclosure_form, 'none') AS ai_disclosure_form,
  COALESCE(ail.ai_label_source, 'unclassified') AS ai_label_source,
  thr.subject
FROM threads AS thr
LEFT JOIN {{ ref('int_thread_ai_labels') }} AS ail
  ON thr.list_name = ail.list_name AND thr.message_id = ail.root_message_id
LEFT JOIN {{ ref('latency_windows') }} AS ltw
  ON {{ in_range('thr.first_action_dt - thr.sent_dt', 'ltw.min_days', 'ltw.max_days') }}
LEFT JOIN {{ ref('thread_size_windows') }} AS tsw
  ON {{ in_range('thr.message_cnt', 'tsw.min_messages', 'tsw.max_messages') }}
