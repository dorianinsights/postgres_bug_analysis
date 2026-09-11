{% macro drop_orphaned_relations() %}
  {# on-run-end: DROP any table/view that lives in a dbt-managed schema but is no
     longer in the DAG -- the residue of renamed or deleted models, which dbt
     itself never removes (it creates and replaces, but never drops a departed
     model's relation). Compares the live catalog against every model / seed /
     snapshot relation PLUS every source, and drops the difference, restricted to
     the schemas the project actually manages (so it can never touch main,
     information_schema, or anything outside the project).

     Safe on a partial `--select` run: graph.nodes is ALWAYS the full DAG, so an
     unselected (not-built-this-run) model is still "expected" and kept. A relation
     dropped in error is just recreated on the next build; sources are never
     dropped (dbt does not own them). It does NOT delete the orphan's
     data/derived/<name>.csv twin -- git rm those. Disable with
     var('drop_orphaned_relations', false). #}
  {% if execute and flags.WHICH in ('run', 'build') and var('drop_orphaned_relations', true) %}
    {% set expected = [] %}
    {% set managed_schemas = [] %}
    {% for node in graph.nodes.values() if node.resource_type in ('model', 'seed', 'snapshot') %}
      {% do expected.append((node.schema | lower, (node.alias or node.name) | lower)) %}
      {% if (node.schema | lower) not in managed_schemas %}
        {% do managed_schemas.append(node.schema | lower) %}
      {% endif %}
    {% endfor %}
    {% for src in graph.sources.values() %}
      {% do expected.append((src.schema | lower, src.identifier | lower)) %}
    {% endfor %}

    {% if managed_schemas | length > 0 %}
      {% set schema_in = "'" ~ (managed_schemas | join("','")) ~ "'" %}
      {% set live = run_query(
        "SELECT table_schema, table_name, table_type FROM information_schema.tables"
        ~ " WHERE lower(table_schema) IN (" ~ schema_in ~ ")"
      ) %}
      {% set dropped = [] %}
      {% for row in live.rows %}
        {% set sch = row[0] | lower %}
        {% set tbl = row[1] | lower %}
        {% if (sch, tbl) not in expected %}
          {% set kind = 'VIEW' if 'VIEW' in (row[2] | upper) else 'TABLE' %}
          {% do run_query("DROP " ~ kind ~ " IF EXISTS " ~ sch ~ "." ~ tbl ~ " CASCADE") %}
          {% do dropped.append(sch ~ '.' ~ tbl) %}
        {% endif %}
      {% endfor %}
      {% if dropped | length > 0 %}
        {% do log("drop_orphaned_relations: dropped " ~ (dropped | length)
          ~ " orphan relation(s): " ~ (dropped | join(', ')), info=true) %}
      {% endif %}
    {% endif %}
  {% endif %}
{% endmacro %}
