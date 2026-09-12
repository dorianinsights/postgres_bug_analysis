{#
  The final AI-involvement labels for one population: the local model's answer
  (model_name) overridden by the human review seed (ai_involvement_reviews,
  rows of this population). key_columns are the grain columns shared by the
  model table and the seed. has_ai_involvement = a vendor AND a work role.
  Each reviewed-over-model expression is defined once here and reused, since
  a lateral alias would be ambiguous with the joined tables' own columns.
#}
{% macro ai_labels(model_name, population, key_columns) %}
{%- set roles = ['ai_found', 'ai_analyzed', 'ai_authored', 'ai_tooling'] %}
{%- set flag = {} %}
{%- for role in roles %}
  {%- do flag.update({role: 'COALESCE(rev.' ~ role ~ ', mdl.' ~ role ~ ', false)'}) %}
{%- endfor %}
{%- set vendor = "COALESCE(rev.vendor, mdl.vendor, 'none')" %}
SELECT
  {%- for col in key_columns %}
  mdl.{{ col }},
  {%- endfor %}
  {%- for role in roles %}
  {{ flag[role] }} AS {{ role }},
  {%- endfor %}
  COALESCE(rev.mentioned_only, mdl.mentioned_only, false) AS ai_mentioned_only,
  {{ vendor }} AS ai_vendor,
  COALESCE(rev.disclosure_form, mdl.disclosure_form, 'none') AS ai_disclosure_form,
  {{ vendor }} != 'none' AND ({{ flag.values() | join(' OR ') }}) AS has_ai_involvement,
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
