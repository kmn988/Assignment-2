-- =====================================================================
-- TEST DATA ONLY — pos_db
-- Uses the POS owner's REAL tables from db/init/04_pos.sql (no new tables).
-- Rows are inserted directly, so this works before the Inventory owner's
-- sell_stock() function exists. In the live demo, use pos_attempt_sale()
-- instead to create these rows.
-- Safe to re-run (ON CONFLICT DO NOTHING). run_etl.sh --test loads it.
--
-- Scenarios (Miro frame 09):
--   7001 Game A @ Broadway        APPROVED  (normal sale)
--   7002 Game B @ Broadway        REJECTED  RESERVED_STOCK (Customer B, last unit)
--   7003 / 7004 other stores      APPROVED
-- =====================================================================

INSERT INTO pos_employee (employee_id, store_id, employee_name, employee_role, active_flag) VALUES
 (1, 1, 'Sam Lee',    'Sales Associate', TRUE),
 (2, 2, 'Mia Chen',   'Store Manager',   TRUE),
 (3, 3, 'Noah Patel', 'Sales Associate', TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO pos_transaction (transaction_id, store_id, employee_id, transaction_timestamp,
                             transaction_status, rejection_reason, total_amount) VALUES
 (7001, 1, 1, '2026-09-28 11:05:00', 'APPROVED', NULL,              79.95),
 (7002, 1, 1, '2026-09-28 10:20:00', 'REJECTED', 'RESERVED_STOCK',  89.95),
 (7003, 2, 2, '2026-09-27 12:10:00', 'APPROVED', NULL,             149.90),
 (7004, 3, 3, '2026-09-27 16:40:00', 'APPROVED', NULL,              99.95)
ON CONFLICT DO NOTHING;

INSERT INTO pos_transaction_item (transaction_item_id, transaction_id, product_id, promotion_id,
                                  quantity, unit_price, line_amount) VALUES
 (1, 7001, 1, NULL, 1, 79.95, 79.95),   -- Game A sold
 (2, 7002, 2, NULL, 1, 89.95, 89.95),   -- Game B scan attempt (rejected)
 (3, 7003, 5, NULL, 1, 59.95, 59.95),
 (4, 7003, 2, NULL, 1, 89.95, 89.95),
 (5, 7004, 4, NULL, 1, 99.95, 99.95)
ON CONFLICT DO NOTHING;

INSERT INTO pos_payment (payment_id, transaction_id, payment_method, payment_amount, payment_status, payment_timestamp) VALUES
 (1, 7001, 'CARD',  79.95, 'APPROVED', '2026-09-28 11:05:00'),
 (2, 7003, 'CARD', 149.90, 'APPROVED', '2026-09-27 12:10:00'),
 (3, 7004, 'CASH',  99.95, 'APPROVED', '2026-09-27 16:40:00')
ON CONFLICT DO NOTHING;

INSERT INTO pos_receipts (receipt_id, transaction_id, receipt_number, issued_at, delivery_method) VALUES
 (1, 7001, 'RC-00007001', '2026-09-28 11:05:00', 'PRINTED'),
 (2, 7003, 'RC-00007003', '2026-09-27 12:10:00', 'EMAIL'),
 (3, 7004, 'RC-00007004', '2026-09-27 16:40:00', 'PRINTED')
ON CONFLICT DO NOTHING;

-- Identity columns: move the counters past the test IDs so new
-- pos_attempt_sale() calls don't collide with them
SELECT setval(pg_get_serial_sequence('pos_employee','employee_id'),
              (SELECT max(employee_id) FROM pos_employee));
SELECT setval(pg_get_serial_sequence('pos_transaction','transaction_id'),
              (SELECT max(transaction_id) FROM pos_transaction));
SELECT setval(pg_get_serial_sequence('pos_transaction_item','transaction_item_id'),
              (SELECT max(transaction_item_id) FROM pos_transaction_item));
SELECT setval(pg_get_serial_sequence('pos_payment','payment_id'),
              (SELECT max(payment_id) FROM pos_payment));
SELECT setval(pg_get_serial_sequence('pos_receipts','receipt_id'),
              (SELECT max(receipt_id) FROM pos_receipts));
