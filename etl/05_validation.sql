-- =====================================================================
-- 05_validation.sql  —  VALIDATE
-- Answers the 8 ETL/warehouse items on Swapnil's Miro "Integration QA
-- Checklist" — one PASS/FAIL row per item, in the same words.
--
-- Each item is proven by a few small tests (listed under "tests" below,
-- 22 in total). An item PASSES only if ALL its tests pass; if one fails,
-- the "failed_tests" column names it.
--
-- Items 6 and 7 look for the Miro scenario in whatever data is loaded:
-- a fully-reserved last unit, its active reservation and a blocked POS
-- attempt; and cancelled reservations releasing their stock.
-- Run after 04_etl_load.sql and screenshot the result for evidence.
-- =====================================================================

WITH snap AS (
  SELECT f.*, p.product_name, s.store_name
  FROM dw.fact_inventory_snapshot f
  JOIN dw.dim_product p USING (product_key)
  JOIN dw.dim_store   s USING (store_key)
  WHERE f.date_key = (SELECT max(date_key) FROM dw.fact_inventory_snapshot)   -- the latest snapshot
),
-- product/store pairs where the last physical stock is fully held for online customers
fully_reserved AS (
  SELECT product_key, store_key FROM snap
  WHERE on_hand_quantity > 0 AND reserved_quantity > 0 AND available_to_sell = 0
),
checks AS (

  -- ---------- 1. Row-count reconciliation (clean staging vs warehouse) ----------
  SELECT 1 AS n, 'Dimensions load: DIM_PRODUCT = stg_products' AS check_name,
         (SELECT count(*) FROM dw.dim_product) = (SELECT count(*) FROM staging.stg_products) AS ok
  UNION ALL SELECT 2, 'Dimensions load: DIM_STORE = stg_stores',
         (SELECT count(*) FROM dw.dim_store) = (SELECT count(*) FROM staging.stg_stores)
  UNION ALL SELECT 3, 'Dimensions load: DIM_CUSTOMER = stg_customers',
         (SELECT count(*) FROM dw.dim_customer) = (SELECT count(*) FROM staging.stg_customers)
  UNION ALL SELECT 4, 'Facts load: FACT_POS_ACTIVITY = stg_pos_items',
         (SELECT count(*) FROM dw.fact_pos_activity) = (SELECT count(*) FROM staging.stg_pos_items)
  UNION ALL SELECT 5, 'Facts load: FACT_ONLINE_ORDER = stg_order_items',
         (SELECT count(*) FROM dw.fact_online_order) = (SELECT count(*) FROM staging.stg_order_items)
  UNION ALL SELECT 6, 'Facts load: FACT_RESERVATION = stg_reservations',
         (SELECT count(*) FROM dw.fact_reservation) = (SELECT count(*) FROM staging.stg_reservations)
  UNION ALL SELECT 7, 'Facts load: FACT_INVENTORY_SNAPSHOT = stg_inventory',
         (SELECT count(*) FROM snap) = (SELECT count(*) FROM staging.stg_inventory)

  -- ---------- 2. Measure reconciliation ----------
  UNION ALL SELECT 8, 'Revenue reconciles: completed POS line_amount = source',
         (SELECT COALESCE(sum(line_amount),0) FROM dw.fact_pos_activity WHERE transaction_status = 'COMPLETED')
       = (SELECT COALESCE(sum(i.quantity * i.unit_price),0) FROM pos.pos_transaction_item i
          JOIN pos.pos_transaction t USING (transaction_id)
          WHERE UPPER(TRIM(t.transaction_status)) IN ('COMPLETED','APPROVED'))
  UNION ALL SELECT 9, 'On-hand total reconciles with source INVENTORY',
         (SELECT sum(on_hand_quantity) FROM snap) = (SELECT sum(on_hand_quantity) FROM inventory.inventory)

  -- ---------- 3. Surrogate keys resolve (no orphans / nulls) ----------
  UNION ALL SELECT 10, 'Surrogate keys resolve: no NULL keys in any fact',
         NOT EXISTS (SELECT 1 FROM dw.fact_pos_activity WHERE product_key IS NULL OR store_key IS NULL OR date_key IS NULL)
     AND NOT EXISTS (SELECT 1 FROM dw.fact_online_order WHERE product_key IS NULL OR store_key IS NULL OR customer_key IS NULL OR date_key IS NULL)
     AND NOT EXISTS (SELECT 1 FROM dw.fact_reservation  WHERE product_key IS NULL OR store_key IS NULL OR customer_key IS NULL OR date_key IS NULL)

  -- ---------- 4. ATS business rule ----------
  UNION ALL SELECT 11, 'ATS calculation correct: ATS = on_hand - reserved (all rows)',
         NOT EXISTS (SELECT 1 FROM snap WHERE available_to_sell <> on_hand_quantity - reserved_quantity)
  UNION ALL SELECT 12, 'ATS matches source available_to_sell',
         NOT EXISTS (SELECT 1 FROM dw.fact_inventory_snapshot f
                     JOIN dw.dim_product p USING (product_key) JOIN dw.dim_store s USING (store_key)
                     JOIN inventory.inventory i ON i.product_id = p.product_id AND i.store_id = s.store_id
                     WHERE f.date_key = (SELECT max(date_key) FROM dw.fact_inventory_snapshot)
                       AND f.available_to_sell <> i.available_to_sell)
  UNION ALL SELECT 13, 'No negative ATS (no oversell)',
         NOT EXISTS (SELECT 1 FROM snap WHERE available_to_sell < 0)
  UNION ALL SELECT 14, 'Reserved qty = sum of ACTIVE reservations per product/store',
         NOT EXISTS (
           SELECT 1 FROM snap sn
           LEFT JOIN (SELECT product_key, store_key, sum(quantity) q
                      FROM dw.fact_reservation WHERE reservation_status = 'ACTIVE'
                      GROUP BY product_key, store_key) r USING (product_key, store_key)
           WHERE sn.reserved_quantity <> COALESCE(r.q, 0))

  -- ---------- 5. End-to-end scenario: last-unit conflict (Miro frame 09) ----------
  -- Data-driven: works on any dataset that contains the scenario.
  UNION ALL SELECT 15, 'Scenario: some product/store has On Hand > 0, Reserved > 0, ATS = 0',
         EXISTS (SELECT 1 FROM fully_reserved)
  UNION ALL SELECT 16, 'Scenario: FACT_RESERVATION holds an ACTIVE reservation on that stock',
         EXISTS (SELECT 1 FROM dw.fact_reservation f JOIN fully_reserved USING (product_key, store_key)
                 WHERE f.reservation_status = 'ACTIVE')
  UNION ALL SELECT 17, 'Scenario: FACT_POS_ACTIVITY records a BLOCKED / RESERVED_STOCK attempt on that stock',
         EXISTS (SELECT 1 FROM dw.fact_pos_activity f JOIN fully_reserved USING (product_key, store_key)
                 WHERE f.transaction_status = 'BLOCKED' AND f.rejection_reason = 'RESERVED_STOCK')
  UNION ALL SELECT 18, 'Every BLOCKED attempt has a reason, and every OUT_OF_STOCK one is on stock with On Hand = 0',
         NOT EXISTS (SELECT 1 FROM dw.fact_pos_activity
                     WHERE transaction_status = 'BLOCKED' AND rejection_reason IS NULL)
     AND NOT EXISTS (SELECT 1 FROM dw.fact_pos_activity f JOIN snap USING (product_key, store_key)
                     WHERE f.rejection_reason = 'OUT_OF_STOCK' AND snap.on_hand_quantity > 0)

  -- ---------- 6. Additional scenarios ----------
  UNION ALL SELECT 19, 'Reservation cancellation works: cancelled reservations no longer hold stock',
         EXISTS (SELECT 1 FROM dw.fact_reservation WHERE reservation_status = 'CANCELLED')
     AND NOT EXISTS (
           SELECT 1 FROM snap sn
           JOIN (SELECT DISTINCT product_key, store_key FROM dw.fact_reservation
                 WHERE reservation_status = 'CANCELLED') c USING (product_key, store_key)
           LEFT JOIN (SELECT product_key, store_key, sum(quantity) q FROM dw.fact_reservation
                      WHERE reservation_status = 'ACTIVE' GROUP BY 1, 2) a USING (product_key, store_key)
           WHERE sn.reserved_quantity <> COALESCE(a.q, 0))
  UNION ALL SELECT 20, 'Normal POS sale: COMPLETED sales are recorded with revenue',
         EXISTS (SELECT 1 FROM dw.fact_pos_activity
                 WHERE transaction_status = 'COMPLETED' AND line_amount > 0)

  -- ---------- 7. Cleaning worked ----------
  UNION ALL SELECT 21, 'Cleaning: no duplicate natural keys in any dimension',
         NOT EXISTS (SELECT product_id  FROM dw.dim_product  GROUP BY 1 HAVING count(*) > 1)
     AND NOT EXISTS (SELECT store_id    FROM dw.dim_store    GROUP BY 1 HAVING count(*) > 1)
     AND NOT EXISTS (SELECT customer_id FROM dw.dim_customer GROUP BY 1 HAVING count(*) > 1)
  UNION ALL SELECT 22, 'Cleaning: statuses standardised (no lower-case / padded values)',
         NOT EXISTS (SELECT 1 FROM dw.fact_online_order WHERE order_status <> UPPER(TRIM(order_status)))
)
,
-- Which QA checklist item each small test belongs to
items(item, qa_item, tests) AS (VALUES
  (1, 'ETL executes',                     ARRAY[21, 22]),
  (2, 'Dimensions load',                  ARRAY[1, 2, 3]),
  (3, 'Facts load',                       ARRAY[4, 5, 6, 7]),
  (4, 'Surrogate keys resolve',           ARRAY[10]),
  (5, 'ATS calculation correct',          ARRAY[11, 12, 13, 14]),
  (6, 'POS conflict works',               ARRAY[15, 16, 17, 18, 20]),
  (7, 'Reservation cancellation works',   ARRAY[19]),
  (8, 'Dashboard totals reconcile',       ARRAY[8, 9])
)
SELECT i.item,
       i.qa_item                                              AS qa_checklist_item,
       CASE WHEN bool_and(COALESCE(c.ok, false)) THEN 'PASS' ELSE 'FAIL' END AS result,
       count(*) FILTER (WHERE c.ok IS TRUE) || ' of ' || count(*) AS tests_passed,
       COALESCE(string_agg(c.check_name, '; ') FILTER (WHERE c.ok IS NOT TRUE), '') AS failed_tests
FROM items i
JOIN checks c ON c.n = ANY (i.tests)
GROUP BY i.item, i.qa_item
ORDER BY i.item;

-- Detail: every small test (only needed if an item above FAILS)
-- (to see each small test, replace the final SELECT with: SELECT n, check_name, ok FROM checks ORDER BY n;)

-- Last-unit conflict figures (Miro frame 09, step 10), one row per product/store
-- where the last physical stock is fully reserved:
--   active_reservations · available_units (ATS) · blocked_pos_conflicts (RESERVED_STOCK)
SELECT s.store_name, p.product_name,
       sn.on_hand_quantity, sn.reserved_quantity,
       (SELECT count(*) FROM dw.fact_reservation r
         WHERE r.product_key = sn.product_key AND r.store_key = sn.store_key
           AND r.reservation_status = 'ACTIVE')                          AS active_reservations,
       sn.available_to_sell                                              AS available_units,
       (SELECT count(DISTINCT transaction_id) FROM dw.fact_pos_activity f
         WHERE f.product_key = sn.product_key AND f.store_key = sn.store_key
           AND f.transaction_status = 'BLOCKED' AND f.rejection_reason = 'RESERVED_STOCK') AS blocked_pos_conflicts
FROM dw.fact_inventory_snapshot sn
JOIN dw.dim_product p USING (product_key)
JOIN dw.dim_store   s USING (store_key)
WHERE sn.date_key = (SELECT max(date_key) FROM dw.fact_inventory_snapshot)
  AND sn.on_hand_quantity > 0 AND sn.reserved_quantity > 0 AND sn.available_to_sell = 0
ORDER BY s.store_name, p.product_name;

-- Data-consistency warning: OUT_OF_STOCK attempts on stock that has units on hand
SELECT f.transaction_id, s.store_name, p.product_name, sn.on_hand_quantity, sn.available_to_sell,
       f.rejection_reason
FROM dw.fact_pos_activity f
JOIN dw.dim_product p USING (product_key)
JOIN dw.dim_store   s USING (store_key)
JOIN dw.fact_inventory_snapshot sn
  ON sn.product_key = f.product_key AND sn.store_key = f.store_key AND sn.date_key = (SELECT max(date_key) FROM dw.fact_inventory_snapshot)
WHERE f.rejection_reason = 'OUT_OF_STOCK' AND sn.on_hand_quantity > 0
ORDER BY f.transaction_id;
