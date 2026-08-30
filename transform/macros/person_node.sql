{% macro person_node(email, name) -%}
  {#- The identity NODE key for one (email, name) pair: the normalized email,
      or the normalized name when there is no email. int_person_map groups
      these nodes into people via connected components (nodes sharing an email
      OR a name), so the resolved person_key is a component id, not this. The
      facts compute this node key and JOIN int_person_map to get person_key.
      Plain MD5 (not dbt_utils.generate_surrogate_key) so the sqlfluff jinja
      templater can expand it with no dbt compile. -#}
  MD5(COALESCE(NULLIF(LOWER(TRIM({{ email }})), ''), 'name:' || LOWER(TRIM(COALESCE({{ name }}, '')))))
{%- endmacro %}
