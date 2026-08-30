{% macro person_key(email, name) -%}
  {#- Surrogate key for the person/entity dimension, derived identically in
      dim_person and in every fact that references it (author, committer,
      sender roles) so the keys can never drift. First-pass identity is the
      normalized email; when a message has no email we fall back to the
      normalized name. Plain MD5 (not dbt_utils.generate_surrogate_key) so
      the sqlfluff jinja templater can expand it with no dbt compile. -#}
  MD5(COALESCE(NULLIF(LOWER(TRIM({{ email }})), ''), 'name:' || LOWER(TRIM(COALESCE({{ name }}, '')))))
{%- endmacro %}
