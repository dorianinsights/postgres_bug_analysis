-- Commit dimension: one row per git commit (a backpatch is its own commit, with
-- its own hash) -- the single home for commit-level attributes and the conformed
-- keys resolved once per commit. It replaces the retired commit-grain fact: a
-- commit's MEASURES (churn, file count) are aggregates of its file rows in
-- fct_commit_files, so nothing measured lives here; only descriptors and FKs.
-- Foreign keys into dim_person (author + committer roles), dim_date (commit day),
-- dim_release / dim_version (the release + minor it shipped in) and dim_major (its
-- development line -- master included). branch_scope is the commit's own
-- lifecycle scope for churn views (trunk / beta / stable -- a stable branch holds
-- both its pre-GA beta work and its backpatch stream, told apart by
-- int_commit_versions). origin, the reviewed AI-involvement labels
-- (int_commit_ai_labels, per fix), the dominant subsystem and the subject ride
-- along as attributes. Each person key resolves via
-- the identity node (person_node + int_person_map), matching dim_person.
--
-- The fix-commit spine: fix_key (normalized subject, the identity of a committed
-- fix across its backpatches -- COUNT(DISTINCT fix_key) is "distinct fixes") and
-- is_housekeeping (stamps, translations, notes drafting: commits that are not
-- fixes) come from int_git_commits; is_representative_commit picks one
-- backpatch per fix so per-commit sums (churn) are not multiplied by the
-- number of branches in the corpus; is_documented / documented_item_ord say
-- whether a release-notes item cites this commit (the int_fix_commits bridge,
-- inverted). dim_release_key resolves through int_commit_versions: exact tag
-- ancestry for shipped commits, and the OPEN release for a released major's
-- stable-branch commits after its latest tag (the pending fix stream) -- so
-- "committed toward the next release" is a plain filter on this key.
--
-- NO Kimball special members (the deliberate exception, like dim_date): the only
-- fact that references this dimension, fct_commit_files, is BUILT from the commit
-- spine (every file row belongs to a real commit), so its dim_commit_key is
-- mandatory by construction and never resolves to Unknown / Not Applicable.
-- dim_commit_key is a generate_surrogate_key hash of commit_hash, computed ONCE
-- here; fct_commit_files conforms by joining on commit_hash. Grain = commit_hash.
-- the release-notes item citing each commit (the lowest item when a combined
-- commit is annotated under several)
WITH documented AS (
  SELECT
    commit_hash,
    MIN(group_ord) AS documented_item_ord
  FROM {{ ref('int_fix_commits') }}
  WHERE commit_hash IS NOT null
  GROUP BY ALL
)

SELECT
  {{ dbt_utils.generate_surrogate_key(['gcm.commit_hash']) }} AS dim_commit_key,
  COALESCE(pmp_a.person_key, {{ unknown_key() }}) AS author_dim_person_key,
  COALESCE(pmp_c.person_key, {{ unknown_key() }}) AS committer_dim_person_key,
  -- the release this commit shipped in, or is pending for (int_commit_versions
  -- -> int_releases, which mints the key dim_release conforms to). The beta
  -- branch's commits fall through to their version's in_development release
  -- (dim_version's 19.0 row); master misses -> Not Applicable.
  COALESCE(irl.dim_release_key, dvr.dim_release_key, {{ not_applicable_key() }}) AS dim_release_key,
  -- the minor it shipped in (tag ancestry -> dim_version); pending commits have
  -- no tag yet -> Not Applicable
  COALESCE(dvr.dim_version_key, {{ not_applicable_key() }}) AS dim_version_key,
  -- the commit's development line (dim_major includes master, so this always
  -- resolves; the COALESCE only guards an unexpected branch)
  COALESCE(dmj.dim_major_key, {{ not_applicable_key() }}) AS dim_major_key,
  gcm.commit_dt,
  gcm.commit_hash,
  gcm.commit_ts,
  -- the commit's lifecycle scope for churn views, per COMMIT (a stable branch
  -- carries both its pre-GA stabilization and its backpatch stream):
  --   trunk   master
  --   beta    a major's pre-GA work on its stable branch (version M.0), for
  --           every major -- the in-progress one and each released one's
  --           own beta period
  --   stable  the backpatch stream: shipped in, or pending for, a minor
  CASE
    WHEN gcm.branch = 'master' THEN 'trunk'
    WHEN icv.release_status = 'development' THEN 'beta'
    WHEN icv.release_status IN ('shipped', 'open') THEN 'stable'
    ELSE 'other'
  END AS branch_scope,
  org.origin,
  -- disclosed AI involvement, per FIX (a backpatch shares its fix's labels):
  -- the reviewed local-LLM labels from int_commit_ai_labels. has_ai_involvement
  -- = a vendor AND a work role; the roles are independent flags
  ail.has_ai_involvement,
  ail.ai_found,
  ail.ai_analyzed,
  ail.ai_authored,
  ail.ai_tooling,
  ail.ai_mentioned_only,
  ail.ai_vendor,
  ail.ai_disclosure_form,
  ail.ai_label_source,
  ail.ai_rationale,
  -- the area this commit mostly touched (int_commit_profile's weighted vote over
  -- its files); 'other' for an empty commit with no file changes
  COALESCE(prf.dominant_subsystem, 'other') AS dominant_subsystem,
  gcm.subject,
  gcm.fix_key,
  gcm.is_housekeeping,
  -- ONE commit per backpatched fix: within the stable (backpatch) scope, the
  -- fix_key's LARGEST backpatch by total churn (an older branch's version can
  -- carry extra conflict-resolution lines, so this is the fix's full size),
  -- newest major then newest commit as the tiebreaks. A fix backpatched to N
  -- branches is N commits, and the number of branches inside the corpus grew
  -- from one (2021) to five (2025+), so anything summed per commit inflates
  -- with the corpus rather than the work; churn views sum the representatives
  -- instead. False outside the backpatch stream.
  (
    COALESCE(icv.release_status IN ('shipped', 'open'), false)
    AND ROW_NUMBER() OVER (
      PARTITION BY gcm.fix_key, COALESCE(icv.release_status IN ('shipped', 'open'), false)
      ORDER BY COALESCE(prf.churn, 0) DESC, dmj.major DESC, gcm.commit_ts DESC, gcm.commit_hash ASC
    ) = 1
  ) AS is_representative_commit,
  dfx.documented_item_ord IS NOT null AS is_documented,
  -- the citing release-notes item (fct_fixes.item_ord); NULL when none cites
  -- this commit -- an attribute, not an FK, so no special member stands in
  dfx.documented_item_ord,
  -- no Kimball special members here (built from the commit spine), so every
  -- row is real; the flag exists for uniformity across all dimensions
  false AS is_synthetic_row
FROM {{ ref('int_git_commits') }} AS gcm
LEFT JOIN {{ ref('int_commit_versions') }} AS icv
  ON gcm.branch = icv.branch AND gcm.commit_hash = icv.commit_hash
LEFT JOIN {{ ref('int_commit_origins') }} AS org ON gcm.commit_hash = org.commit_hash
-- the commit's file-level profile (churn, dominant subsystem), once per commit
LEFT JOIN {{ ref('int_commit_profile') }} AS prf ON gcm.commit_hash = prf.commit_hash
LEFT JOIN documented AS dfx ON gcm.commit_hash = dfx.commit_hash
-- one label row per fix_key (int_commit_ai_texts covers every commit)
LEFT JOIN {{ ref('int_commit_ai_labels') }} AS ail ON gcm.fix_key = ail.fix_key
-- the release (shipped or open) from the registry that mints its key, and the
-- shipped minor from dim_version (1:1 on version)
LEFT JOIN {{ ref('int_releases') }} AS irl ON icv.ship_release_dt = irl.release_dt
LEFT JOIN {{ ref('dim_version') }} AS dvr ON icv.version = dvr.version
LEFT JOIN {{ ref('dim_major') }} AS dmj ON gcm.branch = dmj.stable_branch
LEFT JOIN {{ ref('int_person_map') }} AS pmp_a
  ON pmp_a.node_id = {{ person_node('gcm.patch_author_email', 'gcm.patch_author_name') }}
LEFT JOIN {{ ref('int_person_map') }} AS pmp_c
  ON pmp_c.node_id = {{ person_node('gcm.committer_email', 'gcm.committer_name') }}
