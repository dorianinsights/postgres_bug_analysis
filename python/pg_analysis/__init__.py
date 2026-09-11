# pyright: strict
"""The PostgreSQL patch-analysis pipeline's Python side, as one package.

- `paths`        -- the repo layout (caches, data/raw, the dbt project), computed once
- `corpus`       -- the corpus definition (FIRST_MAJOR and the tag-bounded ranges)
- the fetchers   -- `postgres_clone`, `mailing_list_sync`, `scrape_cve_severity`
- `refresh_data` -- runs the fetchers in-process, then the dbt build
- the backfills  -- `backfill_ai_involvement`, `backfill_classifications`
- `embed_fixes`  -- an exploratory embedding prototype, not wired into dbt
- `sources`      -- the build-time readers the dbt Python models import

Installed editable from the repo (`pip install -e .`); the console entry points
in pyproject.toml (`pg-refresh`, `pg-clone`, ...) map onto the modules' main().
"""
