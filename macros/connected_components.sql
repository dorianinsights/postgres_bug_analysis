{#
  Connected components over a node-key CTE: two nodes are in the same component
  when they share any join_key, transitively. Emits the edges / reachable CTEs
  and the final SELECT, so the calling model opens with
  `WITH RECURSIVE <node_keys> AS (SELECT <node_col>, join_key ...),` and ends
  with this macro. The component id is the component's lowest node.
#}
{% macro connected_components(node_keys, node_col, component_col) %}
edges AS (
  SELECT DISTINCT
    lhs.{{ node_col }} AS src_node,
    rhs.{{ node_col }} AS dst_node
  FROM {{ node_keys }} AS lhs
  INNER JOIN {{ node_keys }} AS rhs ON lhs.join_key = rhs.join_key
  WHERE lhs.{{ node_col }} != rhs.{{ node_col }}
),

-- UNION (not UNION ALL) dedups rows, so the walk terminates on a cycle
reachable ({{ node_col }}, peer_node) AS (
  SELECT DISTINCT
    {{ node_col }},
    {{ node_col }} AS peer_node
  FROM {{ node_keys }}
  UNION
  SELECT
    rch.{{ node_col }},
    edg.dst_node AS peer_node
  FROM reachable AS rch
  INNER JOIN edges AS edg ON rch.peer_node = edg.src_node
)

SELECT
  {{ node_col }},
  MIN(peer_node) AS {{ component_col }}
FROM reachable
GROUP BY ALL
{% endmacro %}
