{#
  An instant's UTC calendar day, pinned so the day boundary can't drift with the
  session timezone.
#}
{% macro utc_date(ts) -%}
({{ ts }} AT TIME ZONE 'utc')::DATE
{%- endmacro %}
