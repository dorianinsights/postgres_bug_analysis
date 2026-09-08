{#
  The build's "today". CURRENT_DATE unless var('as_of_date') is set (a bare
  ISO date), which lets a dbt unit test pin the clock -- e.g. to the Tuesday
  after a wrap Monday, the window in which the release registry once produced
  the same release day as both shipped and open. Every model that reads the
  clock goes through this macro so that one override moves them together.
#}
{% macro as_of_date() -%}
  {%- if var('as_of_date', none) -%}
    DATE '{{ var('as_of_date') }}'
  {%- else -%}
    CURRENT_DATE
  {%- endif -%}
{%- endmacro %}
