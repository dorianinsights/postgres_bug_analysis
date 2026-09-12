{#
  A major's end of support: PostgreSQL majors get ~5 years, so major M's final
  minor lands in var(major_eol_month)/var(major_eol_day) of year
  M + var(major_eol_year_offset).
#}
{% macro major_eol_dt(major) -%}
MAKE_DATE({{ major }} + {{ var('major_eol_year_offset') }}, {{ var('major_eol_month') }}, {{ var('major_eol_day') }})
{%- endmacro %}
