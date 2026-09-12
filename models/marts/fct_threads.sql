-- Thread-grain fact: one row per mailing-list thread (its root = the earliest
-- archived message, int_message_threads.is_thread_root), the grain ABOVE
-- fct_messages. Factless apart from the thread's size: the questions it
-- answers are how many threads start (per list, per month; a pgsql-bugs
-- thread is a bug report whether or not it came through the BUG # form) and
-- what became of them -- whether any message of the thread was cited by a
-- commit's Discussion: trailer, by which kind of commit (dim_commit's
-- branch_scope: trunk feature work, a backpatched stable fix, beta
-- stabilization), and how long that took. is_acted_upon widens "cited" for the
-- BUG # form reports with dim_bug's other exact link, a commit's Bug: #NNNNN
-- trailer (int_bug_reports), so it is the chart-facing "linked to a fix" flag
-- for every bug report, form or free-form; first_action_dt / days_to_action are
-- the earlier of the two links, with action_outcome / days_to_action_window /
-- thread_size_window the chart-facing labels (the same latency_windows and
-- thread_size_windows seeds dim_bug uses, so the two grains bucket alike).
-- Recent threads are right-censored: they have had little time to be cited.
--
-- Conforms to dim_person (the starter), dim_date (started_dt, first_cite_dt --
-- future_eternity when never cited, so the FK is never NULL), and dim_bug (the
-- BUG # form report the root names; Not Applicable for free-form reports and
-- pgsql-hackers). is_new_thread separates threads that genuinely began here
-- (no reply header) from the archive's first sight of a thread that began
-- off-archive. outcome ranks a multiply-cited thread by its most
-- fix-like citation (stable > beta > trunk) so a stacked chart counts each
-- thread once. Too many rows for a derived CSV twin (over
-- var(derived_csv_max_rows)); query it in the warehouse.
-- Grain = (list_name, root_message_id).
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
)

SELECT
  fmg.list_name,
  fmg.message_id AS root_message_id,
  fmg.sender_dim_person_key AS starter_dim_person_key,
  fmg.dim_bug_key,
  fmg.sent_dt AS started_dt,
  COALESCE(cte.first_cite_dt, DATE '{{ var('future_eternity') }}') AS first_cite_dt,
  COALESCE(
    LEAST(cte.first_cite_dt, CASE WHEN dbg.is_acted_upon THEN dbg.first_commit_dt END),
    DATE '{{ var('future_eternity') }}'
  ) AS first_action_dt,
  fmg.sent_ts AS started_ts,
  fmg.is_thread_start AS is_new_thread,
  fmg.dim_bug_key != {{ not_applicable_key() }} AS is_form_report,
  rlp.message_cnt,
  rlp.last_message_dt,
  cte.root_id IS NOT null AS is_cited,
  COALESCE(cte.is_cited_by_trunk, false) AS is_cited_by_trunk,
  COALESCE(cte.is_cited_by_stable, false) AS is_cited_by_stable,
  COALESCE(cte.is_cited_by_beta, false) AS is_cited_by_beta,
  CASE
    WHEN cte.is_cited_by_stable THEN 'backpatched fix'
    WHEN cte.is_cited_by_beta THEN 'beta stabilization'
    WHEN cte.is_cited_by_trunk THEN 'trunk work'
    ELSE 'not cited'
  END AS outcome,
  -- NULL when never cited (first_cite_dt is then the future_eternity sentinel)
  cte.first_cite_dt - fmg.sent_dt AS days_to_first_cite,
  -- cited, or (a form report) linked by a commit's Bug: # trailer
  cte.root_id IS NOT null OR COALESCE(dbg.is_acted_upon, false) AS is_acted_upon,
  CASE
    WHEN cte.root_id IS NOT null OR COALESCE(dbg.is_acted_upon, false) THEN 'linked to a fix commit'
    ELSE 'no linked commit'
  END AS action_outcome,
  LEAST(cte.first_cite_dt, CASE WHEN dbg.is_acted_upon THEN dbg.first_commit_dt END) - fmg.sent_dt
    AS days_to_action,
  ltw.label AS days_to_action_window,
  tsw.label AS thread_size_window,
  -- disclosed AI involvement in the thread's root message: the reviewed
  -- local-LLM labels (int_thread_ai_labels). has_ai_involvement = a vendor AND
  -- a work role; the roles are independent flags
  COALESCE(ail.has_ai_involvement, false) AS has_ai_involvement,
  COALESCE(ail.ai_found, false) AS ai_found,
  COALESCE(ail.ai_analyzed, false) AS ai_analyzed,
  COALESCE(ail.ai_authored, false) AS ai_authored,
  COALESCE(ail.ai_tooling, false) AS ai_tooling,
  COALESCE(ail.ai_mentioned_only, false) AS ai_mentioned_only,
  COALESCE(ail.ai_vendor, 'none') AS ai_vendor,
  COALESCE(ail.ai_disclosure_form, 'none') AS ai_disclosure_form,
  COALESCE(ail.ai_label_source, 'unclassified') AS ai_label_source,
  fmg.subject
FROM {{ ref('fct_messages') }} AS fmg
LEFT JOIN {{ ref('int_thread_ai_labels') }} AS ail
  ON fmg.list_name = ail.list_name AND fmg.message_id = ail.root_message_id
INNER JOIN rollup AS rlp ON fmg.list_name = rlp.list_name AND fmg.message_id = rlp.root_id
LEFT JOIN cite_rollup AS cte ON fmg.list_name = cte.list_name AND fmg.message_id = cte.root_id
-- the form report's own outcome (Discussion OR Bug: # link), for is_acted_upon
LEFT JOIN {{ ref('dim_bug') }} AS dbg ON fmg.dim_bug_key = dbg.dim_bug_key
-- the shared bucket seeds (open-ended top buckets have a NULL max)
LEFT JOIN {{ ref('latency_windows') }} AS ltw
  ON
    LEAST(cte.first_cite_dt, CASE WHEN dbg.is_acted_upon THEN dbg.first_commit_dt END) - fmg.sent_dt
    >= ltw.min_days
    AND LEAST(cte.first_cite_dt, CASE WHEN dbg.is_acted_upon THEN dbg.first_commit_dt END) - fmg.sent_dt
    <= COALESCE(ltw.max_days, LEAST(cte.first_cite_dt, CASE WHEN dbg.is_acted_upon THEN dbg.first_commit_dt END) - fmg.sent_dt)
LEFT JOIN {{ ref('thread_size_windows') }} AS tsw
  ON rlp.message_cnt >= tsw.min_messages AND rlp.message_cnt <= COALESCE(tsw.max_messages, rlp.message_cnt)
WHERE fmg.is_thread_root
