\connect pos_db

-- store_id / product_id refer to the Inventory database (separate database, so no
-- enforced foreign key). POS never stores stock quantities: Inventory owns them.

-- A sale ATTEMPT: rejected attempts are stored too (they feed FACT_POS_ACTIVITY)
CREATE TABLE IF NOT EXISTS pos_transaction (
    transaction_id         VARCHAR(20)    PRIMARY KEY,
    store_id               VARCHAR(20)    NOT NULL,
    transaction_timestamp  TIMESTAMP      NOT NULL DEFAULT now(),
    transaction_status     VARCHAR(20)    NOT NULL
        CHECK (transaction_status IN ('BLOCKED','COMPLETED')),
    rejection_reason       VARCHAR(255)   NULL
        CHECK (rejection_reason IN ('RESERVED_STOCK','OUT_OF_STOCK','NONE')),
    total_amount           NUMERIC(10,2)  NOT NULL CHECK (total_amount >= 0),
    -- a rejected attempt must say why
    CONSTRAINT ck_rejection_reason
        CHECK (transaction_status <> 'BLOCKED' OR rejection_reason IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS pos_transaction_item (
    transaction_item_id  VARCHAR(20)    PRIMARY KEY,
    transaction_id       VARCHAR(20)    NOT NULL REFERENCES pos_transaction (transaction_id),
    product_id           VARCHAR(20)    NOT NULL,
    quantity             INT            NOT NULL CHECK (quantity > 0),
    unit_price           NUMERIC(10,2)  NOT NULL CHECK (unit_price >= 0),
    line_amount          NUMERIC(10,2)  NOT NULL CHECK (line_amount >= 0)
);

-- ---------------------------------------------------------------------------
-- POS sale check
-- Stock belongs to Inventory (inventory_db), so POS asks Inventory before approving a sale.
-- dblink lets this function run one query in inventory_db: sell_stock(...), which checks
-- Available-to-Sell (= on-hand - reserved) and takes the stock in one atomic step.
-- Needs: the Inventory owner's sell_stock function and a stock row for the product.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE OR REPLACE FUNCTION pos_attempt_sale(
    p_store_id INT, p_employee_id INT, p_product_id INT, p_quantity INT, p_unit_price NUMERIC)
RETURNS TABLE (out_transaction_id INT, out_status VARCHAR, out_reason VARCHAR)
LANGUAGE plpgsql AS $$
DECLARE
    v_txn_id  INT;
    v_total   NUMERIC(10,2) := p_quantity * p_unit_price;
    v_success BOOLEAN;
    v_reason  TEXT;
BEGIN
    -- 1. Record the attempt (rejected attempts are kept for the warehouse)
    INSERT INTO pos_transaction (store_id, employee_id, transaction_status, total_amount)
    VALUES (p_store_id, p_employee_id, 'PENDING', v_total)
    RETURNING pos_transaction.transaction_id INTO v_txn_id;

    INSERT INTO pos_transaction_item (transaction_id, product_id, quantity, unit_price, line_amount)
    VALUES (v_txn_id, p_product_id, p_quantity, p_unit_price, v_total);

    -- 2. Ask Inventory whether the sale is allowed (transaction_id is the idempotency key)
    SELECT r.success, r.reason INTO v_success, v_reason
    FROM dblink('dbname=inventory_db',
                format('SELECT success, reason FROM sell_stock(%s, %s, %s, %L, %s)',
                       p_product_id, p_store_id, p_quantity, 'POS', v_txn_id))
         AS r(success BOOLEAN, reason TEXT);

    -- 3. Save the answer
    IF v_success THEN
        UPDATE pos_transaction SET transaction_status = 'APPROVED'
        WHERE pos_transaction.transaction_id = v_txn_id;
        INSERT INTO pos_payment (transaction_id, payment_method, payment_amount, payment_status)
        VALUES (v_txn_id, 'CARD', v_total, 'APPROVED');
        INSERT INTO pos_receipts (transaction_id, receipt_number, delivery_method)
        VALUES (v_txn_id, 'RC-' || lpad(v_txn_id::TEXT, 8, '0'), 'PRINTED');
    ELSE
        UPDATE pos_transaction SET transaction_status = 'REJECTED', rejection_reason = v_reason
        WHERE pos_transaction.transaction_id = v_txn_id;
    END IF;

    RETURN QUERY
    SELECT t.transaction_id, t.transaction_status, t.rejection_reason
    FROM pos_transaction t WHERE t.transaction_id = v_txn_id;
END $$;