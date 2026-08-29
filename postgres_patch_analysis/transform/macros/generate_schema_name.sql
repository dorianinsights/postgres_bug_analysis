{% macro generate_schema_name(custom_schema_name, node) -%}
  {#- Use the configured +schema name verbatim (staging / intermediate /
      marts / seeds) instead of dbt's default target-prefixed
      "main_staging" style. -#}
  {%- if custom_schema_name is none -%}
    {{ target.schema }}
  {%- else -%}
    {{ custom_schema_name | trim }}
  {%- endif -%}
{%- endmacro %}
