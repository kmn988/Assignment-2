-- =====================================================================
-- add_dirty_rows.sql  —  TEST ONLY: fake bad rows to prove the CLEAN step
-- run_etl.sh --test runs this right after 03_staging.sql.
-- Never used with real data (it writes to staging only, never to sources).
-- =====================================================================
-- ---------------------------------------------------------------------
INSERT INTO staging.stg_customers (customer_id, customer_name, email, source_system, extracted_at) VALUES
 (1,    'Customer A', 'customer.a@example.com', 'ECOMMERCE', now()),  -- exact duplicate
 (NULL, 'Ghost User', 'ghost@example.com',      'ECOMMERCE', now());  -- null ID

INSERT INTO staging.stg_order_items (order_item_id, order_id, product_id, quantity, unit_price, line_amount, source_system, extracted_at) VALUES
 (99, 1001, 999, 1, 10.00, 10.00, 'ECOMMERCE', now()),   -- product_id not in product master
 (98, 1001, 1,  -2, 79.95, -159.90, 'ECOMMERCE', now()); -- negative quantity

INSERT INTO staging.stg_online_orders (order_id, customer_id, fulfilment_store_id, order_status, order_total, created_at, updated_at, source_system, extracted_at) VALUES
 (1005, 4, 2, ' confirmed ', 79.95, '2026-09-28 18:00:00', '2026-09-28 18:00:00', 'ECOMMERCE', now()); -- messy status casing

INSERT INTO staging.stg_order_items (order_item_id, order_id, product_id, quantity, unit_price, line_amount, source_system, extracted_at) VALUES
 (5, 1005, 1, 1, 79.95, 0, 'ECOMMERCE', now());  -- wrong line_amount, recalculated in CLEAN

