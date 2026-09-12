{#
  Range-bucket join condition: value falls in [min_col, max_col], where a NULL
  max_col means open-ended.
#}
{% macro in_range(value, min_col, max_col) -%}
{{ value }} >= {{ min_col }} AND {{ value }} <= COALESCE({{ max_col }}, {{ value }})
{%- endmacro %}
