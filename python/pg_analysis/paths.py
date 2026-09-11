# pyright: strict
"""Where the repo's on-disk state lives, computed ONCE from this package's
location. Everything that touches the caches, the raw data, the dbt project
or the warehouse imports these instead of resolving `__file__` or the cwd
itself, so the scripts and the dbt Python models agree on one layout and run
from any working directory.

The package is installed EDITABLE (`pip install -e .`, via requirements.txt),
so this file sits at <repo>/python/pg_analysis/paths.py and the repo root is two
levels up. It is a working checkout's tool, not a distributable package: a
non-editable install would resolve to site-packages and find nothing.
"""

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# The immutable raw stores (gitignored; recreated by pg-clone / pg-mail-sync).
CACHE_DIR = REPO_ROOT / ".cache"
CLONE = CACHE_DIR / "postgres.git"
MBOX_CACHE = CACHE_DIR / "mbox"

# The committed CSVs dbt reads as sources (the one scraped CSV + the
# classify-once label caches).
DATA_RAW = REPO_ROOT / "data" / "raw"

# The dbt project and the DuckDB warehouse it builds.
TRANSFORM_DIR = REPO_ROOT / "transform"
SEEDS_DIR = TRANSFORM_DIR / "seeds"
WAREHOUSE = TRANSFORM_DIR / "transform.duckdb"

# Credentials for the mailing-list sync (gitignored).
ENV_FILE = REPO_ROOT / ".env"
