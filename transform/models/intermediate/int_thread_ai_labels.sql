-- The FINAL AI-involvement labels per mailing-list thread (root message): the
-- local model's answer (int_thread_ai_involvement) overridden by the human
-- review (ai_involvement_reviews, population 'thread'). Same semantics as
-- int_commit_ai_labels: has_ai_involvement = a vendor AND a work role;
-- label_source = review / model / unclassified.
-- Grain = (list_name, root_message_id).
SELECT
  mdl.list_name,
  mdl.root_message_id,
  COALESCE(rev.ai_found, mdl.ai_found, false) AS ai_found,
  COALESCE(rev.ai_analyzed, mdl.ai_analyzed, false) AS ai_analyzed,
  COALESCE(rev.ai_authored, mdl.ai_authored, false) AS ai_authored,
  COALESCE(rev.ai_tooling, mdl.ai_tooling, false) AS ai_tooling,
  COALESCE(rev.mentioned_only, mdl.mentioned_only, false) AS ai_mentioned_only,
  COALESCE(rev.vendor, mdl.vendor, 'none') AS ai_vendor,
  COALESCE(rev.disclosure_form, mdl.disclosure_form, 'none') AS ai_disclosure_form,
  COALESCE(rev.vendor, mdl.vendor, 'none') != 'none'
  AND (
    COALESCE(rev.ai_found, mdl.ai_found, false)
    OR COALESCE(rev.ai_analyzed, mdl.ai_analyzed, false)
    OR COALESCE(rev.ai_authored, mdl.ai_authored, false)
    OR COALESCE(rev.ai_tooling, mdl.ai_tooling, false)
  ) AS has_ai_involvement,
  CASE
    WHEN rev.root_message_id IS NOT null THEN 'review'
    WHEN mdl.is_classified THEN 'model'
    ELSE 'unclassified'
  END AS ai_label_source,
  mdl.rationale AS ai_rationale
FROM {{ ref('int_thread_ai_involvement') }} AS mdl
LEFT JOIN {{ ref('ai_involvement_reviews') }} AS rev
  ON
    rev.population = 'thread'
    AND mdl.list_name = rev.list_name
    AND mdl.root_message_id = rev.root_message_id
