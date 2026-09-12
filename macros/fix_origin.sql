{#
  The single definition of a FIX's origin, rolled up from its commits' origins
  (int_commit_origins is commit-grain and 3-valued). Precedence: any commit that
  traces to pgsql-bugs makes the fix bug-sourced; else any that traces to
  pgsql-hackers; else no public trail, split by whether the fix is security work
  (embargoed on the private security@ list, so a missing trail is expected) or
  the genuinely unsourceable remainder. Used by int_fix_profile (documented
  fixes) and int_committed_fixes (committed fixes) so the two fix populations
  are classified identically.
#}
{% macro resolve_fix_origin(from_bugs, from_hackers, is_security) %}
  CASE
    WHEN {{ from_bugs }} THEN 'pgsql-bugs'
    WHEN {{ from_hackers }} THEN 'pgsql-hackers'
    WHEN {{ is_security }} THEN 'unknown_or_internal_security'
    ELSE 'unknown_or_internal_not_security'
  END
{% endmacro %}
