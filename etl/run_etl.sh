#!/usr/bin/env bash
# =====================================================================
# run_etl.sh — run the Warehouse/ETL pipeline (owner: Aravind)
#
# From the repo root, with the stack running (docker compose up -d postgres metabase):
#   ./etl/run_etl.sh          # real data: link sources, check, stage, load, validate
#   ./etl/run_etl.sh --test   # first load the TEST data into the 3 source DBs
#                             # and add fake dirty rows to prove the cleaning step
#
# It runs psql inside the "ebg_postgres" container from docker-compose.yml,
# using POSTGRES_USER from .env. The warehouse tables themselves are created
# once at first start by db/init/05_warehouse.sql.
# =====================================================================
set -euo pipefail

ETL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$ETL_DIR")"
CONTAINER="${PG_CONTAINER:-ebg_postgres}"

# POSTGRES_USER from .env (default postgres)
DB_USER="postgres"
if [[ -f "$REPO_DIR/.env" ]]; then
  DB_USER="$(grep -E '^POSTGRES_USER=' "$REPO_DIR/.env" | cut -d= -f2- | tr -d '\r' || true)"
  DB_USER="${DB_USER:-postgres}"
fi

TEST=false
[[ "${1:-}" == "--test" ]] && TEST=true

run() {   # run <database> <file>
  echo ""
  echo "==================== $2  (in $1) ===================="
  docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$1" < "$ETL_DIR/$2"
}

if $TEST; then
  run inventory_db test_data/seed_inventory.sql
  run ecommerce_db test_data/seed_ecommerce.sql
  run pos_db       test_data/seed_pos.sql
fi

run warehouse_db 01_link_sources.sql
run warehouse_db 02_check_sources.sql
echo ">> Any MISSING TABLE / MISSING COLUMN / BAD STATUS rows above must be fixed first (see etl/README.md)."
run warehouse_db 03_staging.sql
$TEST && run warehouse_db test_data/add_dirty_rows.sql
run warehouse_db 04_etl_load.sql
run warehouse_db 05_validation.sql
echo ""
echo "Done. Check the PASS / FAIL list above."
