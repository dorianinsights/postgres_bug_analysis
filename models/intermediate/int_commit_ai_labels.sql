-- The FINAL AI-involvement labels per committed fix: the local model's answer
-- (int_commit_ai_involvement) overridden by the human review
-- (ai_involvement_reviews, population 'commit' -- every text the model tied to
-- an AI plus every rejected keyword hit, so a reviewed row is authoritative).
-- has_ai_involvement is the chart-facing flag: a named or unspecified vendor
-- AND at least one WORK role (found / analyzed / authored / tooling) --
-- mentioned_only is an AI reference, not involvement. label_source says where
-- the row's labels came from: review, model, or unclassified (cached-only
-- build; every flag false). Grain = fix_key.
SELECT
  mdl.fix_key,
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
    WHEN rev.fix_key IS NOT null THEN 'review'
    WHEN mdl.is_classified THEN 'model'
    ELSE 'unclassified'
  END AS ai_label_source,
  mdl.rationale AS ai_rationale
FROM {{ ref('int_commit_ai_involvement') }} AS mdl
LEFT JOIN {{ ref('ai_involvement_reviews') }} AS rev
  ON rev.population = 'commit' AND mdl.fix_key = rev.fix_key
