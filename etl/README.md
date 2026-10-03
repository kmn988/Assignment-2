# ETL + Warehouse (owner: Aravind)

Moves data from the three source databases into the dimensional warehouse:

```
inventory_db ─┐
ecommerce_db ─┼─► warehouse_db:  inventory/ecommerce/pos (linked)  →  staging  →  dw (star schema)  →  Metabase
pos_db ───────┘
```

- **Empty warehouse tables** are created once at first start by `db/init/05_warehouse.sql` (schema `dw`).
- **This folder fills them.** Run it whenever source data changes.

## Run

From the repo root, with the stack up (`docker compose up -d postgres metabase`):

```bash
./etl/run_etl.sh          # real data
./etl/run_etl.sh --test   # demo: loads test data into the 3 source DBs first
```

On Windows without bash, run the same files in DBeaver against `warehouse_db`, in order: 01 → 02 → 03 → 04 → 05.
Test data: run `test_data/seed_inventory.sql` in `inventory_db`, `seed_ecommerce.sql` in `ecommerce_db`,
`seed_pos.sql` in `pos_db` first, and `test_data/add_dirty_rows.sql` between 03 and 04.

Success = all **8 QA checklist items** in step 05 say **PASS**, and the last line shows `1 | 0 | 1`
(Game B: 1 active reservation, 0 available, 1 blocked POS attempt). Items 6–7 test the Miro
demo scenario and pass only if the data contains it.

## Files

| File | Runs in | What it does |
| --- | --- | --- |
| `01_link_sources.sql` | warehouse_db | Links the 3 source DBs with `postgres_fdw`, so their tables appear as `inventory.*`, `ecommerce.*`, `pos.*` |
| `02_check_sources.sql` | warehouse_db | Lists any table, column or status that doesn't match the Miro design, plus row counts |
| `03_staging.sql` | warehouse_db | Copies source rows into `staging.stg_*` (9 tables) |
| `04_etl_load.sql` | warehouse_db | Clean (rejects logged in `dw.etl_reject_log`) → transform → load 4 dims, then 4 facts |
| `05_validation.sql` | warehouse_db | PASS/FAIL for the 8 ETL items on the QA checklist (22 small tests underneath) + the scenario figures |
| `test_data/seed_*.sql` | each source DB | Test rows with the Miro scenario (only until real data arrives) |
| `test_data/add_dirty_rows.sql` | warehouse_db | Fake bad rows to show the cleaning rules working (test only) |

## What the ETL needs from each source owner

- Tables in your own database's **`public` schema** (the default), with the **Miro table and column names** (`02_check_sources.sql` lists any that differ).
- Integer IDs for `product_id`, `store_id`, `customer_id`, `order_id`, `reservation_id`, `transaction_id`.
- Status words:
  - POS `transaction_status`: `APPROVED` / `REJECTED` / `PENDING` (the ETL maps them to the Miro words `COMPLETED` / `BLOCKED`; `PENDING` rows are skipped until final)
  - POS `rejection_reason`: `RESERVED_STOCK` when on-hand > 0 but ATS is 0 (the last-unit case), `OUT_OF_STOCK` when on-hand is 0. **Inventory owner: please make `sell_stock()` return exactly these words.**
  - Orders: `CONFIRMED` / `CANCELLED` / `COLLECTED`
  - Reservations: `ACTIVE` / `CANCELLED` / `COLLECTED` / `EXPIRED`
- Inventory: `reserved_quantity` must equal the total of ACTIVE reservations for that product and store (QA item 5).

## For the dashboard owner (Metabase → `warehouse_db`, schema `dw`)

- Dimensions: `dw.dim_product`, `dw.dim_store`, `dw.dim_customer`, `dw.dim_date`
- Facts: `dw.fact_pos_activity`, `dw.fact_online_order`, `dw.fact_reservation`, `dw.fact_inventory_snapshot`
- Revenue = `fact_pos_activity` where `transaction_status = 'COMPLETED'`. Blocked attempts are kept for Report 2 but aren't revenue.
- `fact_inventory_snapshot` has one row per product, store and ETL-run date: filter to one `date_key` (usually the latest) before summing stock.

## When something breaks

| Message | Fix |
| --- | --- |
| `MISSING TABLE` / `MISSING COLUMN` in step 02 | A source table or column name differs from Miro: ask the owner to rename it (or `ALTER TABLE ... RENAME`) |
| `BAD STATUS` in step 02 | A status word outside the list above: agree a word with the owner |
| `schema "dw" does not exist` | The volume was created before `05_warehouse.sql` existed: run it once in DBeaver, or `docker compose down -v` and start again (deletes data) |
| `server "src_..." does not exist` / fdw errors | Run `01_link_sources.sql` again |
| `violates check constraint "ck_ats_formula"` | A source inventory row with an impossible ATS: check it with the Inventory owner |
