-- =====================================================================
-- 04_etl_load.sql  —  CLEAN → TRANSFORM → STANDARDISE → LOAD
-- Miro "ETL Workflow" steps 4–9, following the Load Sequence exactly:
--   Clean → DIM_DATE → DIM_PRODUCT → DIM_STORE → DIM_CUSTOMER
--   → resolve surrogate keys → FACT_POS_ACTIVITY → FACT_ONLINE_ORDER
--   → FACT_RESERVATION → FACT_INVENTORY_SNAPSHOT
--
-- Re-runnable: dimensions are upserted (surrogate keys stay stable),
-- transaction facts are fully refreshed, and the inventory snapshot
-- replaces only today's rows (history from earlier runs is kept).
-- Run after 03_staging.sql, every time new source data is staged.
-- =====================================================================

-- The reject log shows THIS run's rejected rows only (cleared at the start of each run)
TRUNCATE dw.etl_reject_log RESTART IDENTITY;

-- =====================================================================
-- STEP 4: CLEAN  (every rejected row is logged before it is removed)
-- =====================================================================

-- 4a. Remove exact duplicates (keep one copy)
WITH d AS (
  DELETE FROM staging.stg_customers a
  USING staging.stg_customers b
  WHERE a.ctid > b.ctid
    AND a.customer_id IS NOT DISTINCT FROM b.customer_id
    AND a.customer_name IS NOT DISTINCT FROM b.customer_name
    AND a.email IS NOT DISTINCT FROM b.email
  RETURNING a.customer_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_customers', customer_id::text, 'Duplicate record removed' FROM d;

-- 4b. Reject invalid / null IDs
WITH d AS (DELETE FROM staging.stg_customers WHERE customer_id IS NULL RETURNING customer_name)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_customers', customer_name, 'Null customer_id' FROM d;

WITH d AS (DELETE FROM staging.stg_products WHERE product_id IS NULL RETURNING sku)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_products', sku, 'Null product_id' FROM d;

WITH d AS (DELETE FROM staging.stg_stores WHERE store_id IS NULL RETURNING store_name)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_stores', store_name, 'Null store_id' FROM d;

-- 4c. Standardise statuses (trim + upper case) and timestamps
UPDATE staging.stg_online_orders    SET order_status       = UPPER(TRIM(order_status));
UPDATE staging.stg_reservations     SET reservation_status = UPPER(TRIM(reservation_status));
-- POS source uses APPROVED / REJECTED / PENDING; the warehouse uses the Miro
-- business words COMPLETED / BLOCKED so every report speaks one vocabulary.
UPDATE staging.stg_pos_transactions
   SET transaction_status = CASE UPPER(TRIM(transaction_status))
                              WHEN 'APPROVED' THEN 'COMPLETED'
                              WHEN 'REJECTED' THEN 'BLOCKED'
                              ELSE UPPER(TRIM(transaction_status)) END,
       rejection_reason   = NULLIF(NULLIF(UPPER(TRIM(rejection_reason)), ''), 'NONE');  -- 'NONE' = no reason

-- PENDING = an attempt still being processed; it is not a final result yet
WITH d AS (DELETE FROM staging.stg_pos_transactions WHERE transaction_status = 'PENDING' RETURNING transaction_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_pos_transactions', transaction_id::text, 'PENDING (not final) - skipped this run' FROM d;

-- 4d. Validate product_id and store_id against master data
WITH d AS (
  DELETE FROM staging.stg_order_items oi
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_products p WHERE p.product_id = oi.product_id)
  RETURNING order_item_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_order_items', order_item_id::text, 'Unknown product_id' FROM d;

WITH d AS (
  DELETE FROM staging.stg_pos_items pi
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_products p WHERE p.product_id = pi.product_id)
  RETURNING transaction_item_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_pos_items', transaction_item_id::text, 'Unknown product_id' FROM d;

WITH d AS (
  DELETE FROM staging.stg_reservations r
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_products p WHERE p.product_id = r.product_id)
     OR NOT EXISTS (SELECT 1 FROM staging.stg_stores  s WHERE s.store_id  = r.store_id)
  RETURNING reservation_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_reservations', reservation_id::text, 'Unknown product_id or store_id' FROM d;

WITH d AS (
  DELETE FROM staging.stg_online_orders o
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_stores    s WHERE s.store_id    = o.fulfilment_store_id)
     OR NOT EXISTS (SELECT 1 FROM staging.stg_customers c WHERE c.customer_id = o.customer_id)
  RETURNING order_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_online_orders', order_id::text, 'Unknown store_id or customer_id' FROM d;

WITH d AS (
  DELETE FROM staging.stg_pos_transactions t
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_stores s WHERE s.store_id = t.store_id)
  RETURNING transaction_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_pos_transactions', transaction_id::text, 'Unknown store_id' FROM d;

WITH d AS (
  DELETE FROM staging.stg_inventory i
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_products p WHERE p.product_id = i.product_id)
     OR NOT EXISTS (SELECT 1 FROM staging.stg_stores   s WHERE s.store_id   = i.store_id)
  RETURNING inventory_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_inventory', inventory_id::text, 'Unknown product_id or store_id' FROM d;

-- 4e. Ensure quantity >= 0 and price >= 0
WITH d AS (DELETE FROM staging.stg_order_items WHERE quantity < 0 OR unit_price < 0 RETURNING order_item_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_order_items', order_item_id::text, 'Negative quantity or price' FROM d;

WITH d AS (DELETE FROM staging.stg_pos_items WHERE quantity < 0 OR unit_price < 0 RETURNING transaction_item_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_pos_items', transaction_item_id::text, 'Negative quantity or price' FROM d;

WITH d AS (DELETE FROM staging.stg_inventory WHERE on_hand_quantity < 0 OR reserved_quantity < 0 RETURNING inventory_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_inventory', inventory_id::text, 'Negative on_hand or reserved' FROM d;

-- 4f. Orphan child rows (parent removed during cleaning)
WITH d AS (
  DELETE FROM staging.stg_order_items oi
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_online_orders o WHERE o.order_id = oi.order_id)
  RETURNING order_item_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_order_items', order_item_id::text, 'Parent order missing' FROM d;

WITH d AS (
  DELETE FROM staging.stg_reservations r
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_online_orders o WHERE o.order_id = r.order_id)
  RETURNING reservation_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_reservations', reservation_id::text, 'Parent order missing' FROM d;

WITH d AS (
  DELETE FROM staging.stg_pos_items pi
  WHERE NOT EXISTS (SELECT 1 FROM staging.stg_pos_transactions t WHERE t.transaction_id = pi.transaction_id)
  RETURNING transaction_item_id)
INSERT INTO dw.etl_reject_log (source_table, record_id, reject_reason)
SELECT 'stg_pos_items', transaction_item_id::text, 'Parent transaction missing' FROM d;

-- =====================================================================
-- STEP 5–6: TRANSFORM + STANDARDISE (business rules)
-- =====================================================================
-- line_amount = quantity × unit_price
UPDATE staging.stg_order_items SET line_amount = quantity * unit_price;
UPDATE staging.stg_pos_items   SET line_amount = quantity * unit_price;

-- ATS is recalculated in the warehouse load below: ATS = on_hand − reserved
-- (source_available_to_sell is only used to reconcile in 05_validation.sql)

-- =====================================================================
-- STEP 7: LOAD DIMENSIONS  (upsert on natural key → stable surrogate keys)
-- Keys come from SERIAL; ON CONFLICT means a re-run updates instead of
-- duplicating, so product_key / store_key / customer_key never change.
-- =====================================================================

-- DIM_DATE: every day from the earliest source date to today (or the latest
-- source date), so every fact date — and today's snapshot — has a row.
WITH bounds AS (
  SELECT LEAST(min(d)::date, CURRENT_DATE) AS lo, GREATEST(max(d)::date, CURRENT_DATE) AS hi
  FROM (SELECT transaction_timestamp AS d FROM staging.stg_pos_transactions
        UNION ALL SELECT created_at FROM staging.stg_online_orders
        UNION ALL SELECT created_at FROM staging.stg_reservations
        UNION ALL SELECT updated_at FROM staging.stg_inventory) x
),
ins AS (
  INSERT INTO dw.dim_date (date_key, full_date, day, month, quarter, year, day_of_week)
  SELECT TO_CHAR(d, 'YYYYMMDD')::INT, d::DATE,
         EXTRACT(DAY FROM d)::INT,
         TO_CHAR(d, 'FMMonth'),
         'Q' || EXTRACT(QUARTER FROM d)::INT,
         EXTRACT(YEAR FROM d)::INT,
         TO_CHAR(d, 'FMDay')
  FROM bounds, generate_series(bounds.lo, bounds.hi, INTERVAL '1 day') AS d
  ON CONFLICT (date_key) DO NOTHING
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'DIM_DATE', count(*) FROM ins;

-- DIM_PRODUCT
WITH ins AS (
  INSERT INTO dw.dim_product (product_id, sku, product_name, category, unit_price)
  SELECT product_id, sku, product_name, category, unit_price
  FROM staging.stg_products
  ON CONFLICT (product_id) DO UPDATE
    SET sku = EXCLUDED.sku, product_name = EXCLUDED.product_name,
        category = EXCLUDED.category, unit_price = EXCLUDED.unit_price
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'DIM_PRODUCT', count(*) FROM ins;

-- DIM_STORE
WITH ins AS (
  INSERT INTO dw.dim_store (store_id, store_name, location)
  SELECT store_id, store_name, location
  FROM staging.stg_stores
  ON CONFLICT (store_id) DO UPDATE
    SET store_name = EXCLUDED.store_name, location = EXCLUDED.location
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'DIM_STORE', count(*) FROM ins;

-- DIM_CUSTOMER
WITH ins AS (
  INSERT INTO dw.dim_customer (customer_id, customer_name)
  SELECT customer_id, customer_name
  FROM staging.stg_customers
  ON CONFLICT (customer_id) DO UPDATE
    SET customer_name = EXCLUDED.customer_name
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'DIM_CUSTOMER', count(*) FROM ins;

-- =====================================================================
-- STEP 8–9: RESOLVE SURROGATE KEYS + LOAD FACTS
-- Facts are built from the CLEANED staging tables (not the raw sources),
-- joined to the dimensions on the natural key; only surrogate keys are
-- stored. INNER JOIN = a row whose key can't be resolved can't load.
-- =====================================================================
TRUNCATE dw.fact_pos_activity, dw.fact_online_order, dw.fact_reservation RESTART IDENTITY;

-- FACT_POS_ACTIVITY  (POS_TRANSACTION + POS_TRANSACTION_ITEM)
WITH ins AS (
  INSERT INTO dw.fact_pos_activity
    (transaction_id, transaction_item_id, product_key, store_key, date_key,
     quantity, unit_price, line_amount, transaction_status, rejection_reason)
  SELECT t.transaction_id, i.transaction_item_id, p.product_key, s.store_key, d.date_key,
         i.quantity, i.unit_price, i.line_amount, t.transaction_status, t.rejection_reason
  FROM staging.stg_pos_items i
  JOIN staging.stg_pos_transactions t ON t.transaction_id = i.transaction_id
  JOIN dw.dim_product p ON p.product_id = i.product_id
  JOIN dw.dim_store   s ON s.store_id   = t.store_id
  JOIN dw.dim_date    d ON d.full_date  = t.transaction_timestamp::DATE
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'FACT_POS_ACTIVITY', count(*) FROM ins;

-- FACT_ONLINE_ORDER  (ONLINE_ORDER + ORDER_ITEM)
WITH ins AS (
  INSERT INTO dw.fact_online_order
    (order_id, order_item_id, product_key, store_key, customer_key, date_key,
     quantity, unit_price, line_amount, order_status)
  SELECT o.order_id, oi.order_item_id, p.product_key, s.store_key, c.customer_key, d.date_key,
         oi.quantity, oi.unit_price, oi.line_amount, o.order_status
  FROM staging.stg_order_items oi
  JOIN staging.stg_online_orders o ON o.order_id = oi.order_id
  JOIN dw.dim_product  p ON p.product_id  = oi.product_id
  JOIN dw.dim_store    s ON s.store_id    = o.fulfilment_store_id
  JOIN dw.dim_customer c ON c.customer_id = o.customer_id
  JOIN dw.dim_date     d ON d.full_date   = o.created_at::DATE
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'FACT_ONLINE_ORDER', count(*) FROM ins;

-- FACT_RESERVATION  (RESERVATION, customer resolved through its order)
WITH ins AS (
  INSERT INTO dw.fact_reservation
    (reservation_id, order_id, product_key, store_key, customer_key, date_key,
     quantity, reservation_status)
  SELECT r.reservation_id, r.order_id, p.product_key, s.store_key, c.customer_key, d.date_key,
         r.quantity, r.reservation_status
  FROM staging.stg_reservations r
  JOIN staging.stg_online_orders o ON o.order_id = r.order_id
  JOIN dw.dim_product  p ON p.product_id  = r.product_id
  JOIN dw.dim_store    s ON s.store_id    = r.store_id
  JOIN dw.dim_customer c ON c.customer_id = o.customer_id
  JOIN dw.dim_date     d ON d.full_date   = r.created_at::DATE
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'FACT_RESERVATION', count(*) FROM ins;

-- FACT_INVENTORY_SNAPSHOT  (INVENTORY, one snapshot per ETL-run date)
-- A re-run on the same day replaces that day's rows; earlier days are kept as history.
DELETE FROM dw.fact_inventory_snapshot
WHERE date_key = TO_CHAR(CURRENT_DATE, 'YYYYMMDD')::INT;

WITH ins AS (
  INSERT INTO dw.fact_inventory_snapshot
    (product_key, store_key, date_key, on_hand_quantity, reserved_quantity, available_to_sell)
  SELECT p.product_key, s.store_key, d.date_key,
         i.on_hand_quantity, i.reserved_quantity,
         i.on_hand_quantity - i.reserved_quantity          -- ATS = On-Hand − Reserved
  FROM staging.stg_inventory i
  JOIN dw.dim_product p ON p.product_id = i.product_id
  JOIN dw.dim_store   s ON s.store_id   = i.store_id
  JOIN dw.dim_date    d ON d.full_date  = CURRENT_DATE
  RETURNING 1)
INSERT INTO dw.etl_run_log (step, rows_affected) SELECT 'FACT_INVENTORY_SNAPSHOT', count(*) FROM ins;

-- Load summary (screenshot for evidence)
SELECT step, rows_affected, logged_at FROM dw.etl_run_log ORDER BY run_id DESC LIMIT 8;
-- Rows rejected in this run ((0 rows) = nothing rejected)
SELECT source_table, record_id, reject_reason FROM dw.etl_reject_log ORDER BY reject_id;
