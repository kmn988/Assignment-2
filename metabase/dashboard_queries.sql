-- Dashboard queries for Metabase go here.
-- Add them once the warehouse tables (db/init/05_warehouse.sql) are defined.
-- =====================================================================
-- Dashboard queries for the live demo (read-only SELECTs)
--
-- In Metabase: New > SQL query, choose the database named in each heading,
-- paste the query, then Visualize and Save. Add all four to one dashboard.
-- A Metabase question can use only ONE database, but a dashboard can hold
-- questions from different databases.
--
-- Each query has two variables. Create them as type "Text" in the variables
-- panel and give them defaults:
--     product_id = P006      (Helldivers 2)
--     store_id   = S001      (Broadway)
-- That product starts with 3 on hand, 1 reserved, 2 available to sell, so an
-- online order for 2 units takes Available-to-Sell to 0.
--
-- These queries only READ. The statements that create the order and the sale
-- are in demo_actions.sql (Metabase Actions), never in a question.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. STOCK POSITION                                   database: inventory_db
--    Shows on hand, reserved and Available-to-Sell. ATS drops to 0 after the order.
-- ---------------------------------------------------------------------
SELECT
    p.product_name,
    s.store_name,
    i.on_hand_quantity,
    i.reserved_quantity,
    i.available_to_sell
FROM inventory.inventory i
JOIN inventory.product p ON p.product_id = i.product_id
JOIN inventory.store   s ON s.store_id   = i.store_id
WHERE i.product_id = {{product_id}}
  AND i.store_id   = {{store_id}};


-- ---------------------------------------------------------------------
-- 2. STOCK MOVEMENTS (newest first)                   database: inventory_db
--    The online order appears as ONLINE_RESERVATION. A blocked POS sale adds
--    nothing here: there is no POS_SALE row for it.
-- ---------------------------------------------------------------------
SELECT
    movement_timestamp,
    movement_type,
    quantity_change,
    source_system,
    source_reference_id
FROM inventory.inventory_movement
WHERE product_id = {{product_id}}
  AND store_id   = {{store_id}}
ORDER BY movement_timestamp DESC, movement_id DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- 3. ONLINE ORDERS AND RESERVATIONS (newest first)    database: ecommerce_db
--    Customer's order, with its ACTIVE reservation.
-- ---------------------------------------------------------------------
SELECT
    o.order_id,
    c.customer_name,
    o.order_status,
    r.reservation_id,
    r.reservation_status,
    r.quantity,
    o.created_at
FROM ecommerce.online_order o
JOIN ecommerce.customer    c ON c.customer_id = o.customer_id
JOIN ecommerce.reservation r ON r.order_id    = o.order_id
WHERE r.product_id = {{product_id}}
  AND r.store_id   = {{store_id}}
ORDER BY o.created_at DESC, o.order_id DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- 4. POS SALE ATTEMPTS (newest first)                 database: pos_db
--    The blocked sale shows BLOCKED with RESERVED_STOCK and a total of 0.00
--    (the item row keeps the quantity and price that were requested).
-- ---------------------------------------------------------------------
SELECT
    t.transaction_id,
    t.transaction_timestamp,
    t.transaction_status,
    t.rejection_reason,
    i.quantity,
    i.line_amount AS requested_amount,
    t.total_amount
FROM pos.pos_transaction t
JOIN pos.pos_transaction_item i ON i.transaction_id = t.transaction_id
WHERE i.product_id = {{product_id}}
  AND t.store_id   = {{store_id}}
ORDER BY t.transaction_timestamp DESC, t.transaction_id DESC
LIMIT 10;