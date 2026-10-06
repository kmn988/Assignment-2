-- =====================================================================
-- Metabase Actions for the live demo (INSERT / UPDATE statements)
--
-- Each statement below becomes ONE custom action, run by a button on the
-- dashboard. Actions only run when the button is clicked, unlike a normal
-- question, which re-runs every time the dashboard loads.
--
-- Set up (once per database that has an action):
--   1. Admin settings > Databases > the database > turn on "Model actions".
--   2. Create any model on that database (New > SQL query > Save as model,
--      e.g. SELECT * FROM inventory).
--   3. Open the model > info > Actions > New action > custom (SQL) action.
--   4. Paste the statement, set each {{field}} to the type shown, then save.
--   5. On the dashboard (edit mode) add an action button for each action and
--      leave the fields on "Ask the user".
--
-- The functions behind the forms live in the system files:
--   place_online_order  -> db/init/03_ecommerce.sql
--   pos_attempt_sale    -> db/init/04_pos.sql
--   check_availability  -> db/init/02_inventory.sql
--
-- Demo values:  customer C001 | product P006 (Helldivers 2) | store S001 (Broadway)
--               P006 at S001 starts with 2 units available to sell.
-- If a form complains about a type, wrap the field, e.g. CAST({{quantity}} AS INTEGER).
-- =====================================================================


-- ---------------------------------------------------------------------
-- ACTION 1: Place online order                        model on: ecommerce_db
-- Fields: customer_id (Text), store_id (Text), product_id (Text), quantity (Number)
-- Try:    C001, S001, P006, 2
-- Creates the order, its item and an ACTIVE reservation, and reserves the stock in
-- Inventory. If there is not enough available stock the whole order is refused.
-- ---------------------------------------------------------------------
INSERT INTO online_order_form (customer_id, store_id, product_id, quantity)
VALUES ({{customer_id}}, {{store_id}}, {{product_id}}, {{quantity}});


-- ---------------------------------------------------------------------
-- ACTION 2: Make POS sale                             model on: pos_db
-- Fields: store_id (Text), product_id (Text), quantity (Number)
-- Try:    S001, P006, 1
-- Asks Inventory first. With Available-to-Sell at 0 the sale is stored as BLOCKED
-- with RESERVED_STOCK. Metabase shows "success" either way, because the attempt is
-- always recorded. Read the result in dashboard question 4.
-- ---------------------------------------------------------------------
INSERT INTO pos_sale_form (store_id, product_id, quantity)
VALUES ({{store_id}}, {{product_id}}, {{quantity}});


-- ---------------------------------------------------------------------
-- ACTION 3 (optional): Reset demo stock               model on: inventory_db
-- No fields.
-- Puts Helldivers 2 at Broadway back to its seed values (3 on hand, 1 reserved) so the
-- demo can be repeated. Orders and POS attempts already created stay in their tables,
-- and the older stock movements stay in the ledger.
-- ---------------------------------------------------------------------
UPDATE inventory
SET on_hand_quantity  = 3,
    reserved_quantity = 1,
    updated_at        = CURRENT_TIMESTAMP
WHERE product_id = 'P006'
  AND store_id   = 'S001';