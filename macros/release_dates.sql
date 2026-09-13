{#
  The release-day arithmetic, defined once. ISODOW arithmetic yields BIGINT
  and DATE + n needs INTEGER, hence the casts.
#}
{% macro thursday_on_or_after(dt) -%}
({{ dt }} + (((4 - ISODOW({{ dt }})) + 7) % 7)::INTEGER)
{%- endmacro %}

{# a scheduled minor release: the second Thursday of its month #}
{% macro scheduled_release_dt(month_start) -%}
({{ thursday_on_or_after(month_start) }} + 7)
{%- endmacro %}

{#
  A major's end of support: its final minor is the last scheduled release of
  the year var(major_support_years) after its GA day.
#}
{% macro major_eol_dt(ga_dt) -%}
{{ scheduled_release_dt(
  "MAKE_DATE(YEAR(" ~ ga_dt ~ ") + " ~ var('major_support_years') ~ ", LIST_MAX(" ~ var('release_months') ~ "), 1)"
) }}
{%- endmacro %}
