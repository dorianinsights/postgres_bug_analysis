{#
  The final AI-involvement labels for one population: the local model's answer
  (model_name) overridden by the human review seed (ai_involvement_reviews,
  rows of this population). key_columns are the grain columns shared by the
  model table and the seed. has_ai_involvement = a vendor AND a work role.
#}
{% macro ai_labels(model_name, population, key_columns) %}
SELECT
  {%- for col in key_columns %}
  mdl.{{ col }},
  {%- endfor %}
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
    WHEN rev.{{ key_columns[0] }} IS NOT null THEN 'review'
    WHEN mdl.is_classified THEN 'model'
    ELSE 'unclassified'
  END AS ai_label_source,
  mdl.rationale AS ai_rationale
FROM {{ ref(model_name) }} AS mdl
LEFT JOIN {{ ref('ai_involvement_reviews') }} AS rev
  ON
    rev.population = '{{ population }}'
    {%- for col in key_columns %}
    AND mdl.{{ col }} = rev.{{ col }}
    {%- endfor %}
{% endmacro %}
