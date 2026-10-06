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
-- Stock belongs to Inventory (inventory_db), so POS asks Inventory before
-- approving a sale. A failed sale is still recorded as BLOCKED so the attempt
-- is available to the warehouse and dashboard.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS dblink;

DROP FUNCTION IF EXISTS pos_attempt_sale(INT, INT, INT, INT, NUMERIC);

CREATE OR REPLACE FUNCTION pos_attempt_sale(
    p_store_id VARCHAR,
    p_product_id VARCHAR,
    p_quantity INTEGER
)
RETURNS TABLE (
    out_transaction_id VARCHAR,
    out_status VARCHAR,
    out_reason VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_txn_id       VARCHAR(20);
    v_item_id      VARCHAR(20);
    v_unit_price   NUMERIC(10,2);
    v_total        NUMERIC(10,2);
    v_success      BOOLEAN;
    v_reason       VARCHAR(30);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Sale quantity must be greater than zero';
    END IF;

    -- Product master data and price belong to Inventory.
    SELECT t.unit_price
    INTO v_unit_price
    FROM dblink(
        'dbname=inventory_db',
        format('SELECT unit_price FROM product WHERE product_id = %L', p_product_id)
    ) AS t(unit_price NUMERIC(10,2));

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown product %', p_product_id;
    END IF;

    v_total := p_quantity * v_unit_price;

    -- Keep shared POS IDs simple and unique within this database.
    PERFORM pg_advisory_xact_lock(hashtext('pos_demo_transaction_ids'));

    SELECT 'T' || LPAD(
        (COALESCE(MAX(regexp_replace(transaction_id, '\D', '', 'g')::INTEGER), 0) + 1)::TEXT,
        3,
        '0'
    )
    INTO v_txn_id
    FROM pos_transaction;

    SELECT 'TI' || LPAD(
        (COALESCE(MAX(regexp_replace(transaction_item_id, '\D', '', 'g')::INTEGER), 0) + 1)::TEXT,
        3,
        '0'
    )
    INTO v_item_id
    FROM pos_transaction_item;

    -- Ask Inventory first. sell_stock checks Available-to-Sell and updates
    -- inventory atomically when the sale is allowed.
    SELECT r.success, r.reason
    INTO v_success, v_reason
    FROM dblink(
        'dbname=inventory_db',
        format(
            'SELECT success, reason FROM sell_stock(%L, %L, %s, %L)',
            p_product_id, p_store_id, p_quantity, v_txn_id
        )
    ) AS r(success BOOLEAN, reason VARCHAR(30));

    INSERT INTO pos_transaction (
        transaction_id,
        store_id,
        transaction_timestamp,
        transaction_status,
        rejection_reason,
        total_amount
    )
    VALUES (
        v_txn_id,
        p_store_id,
        CURRENT_TIMESTAMP,
        CASE WHEN v_success THEN 'COMPLETED' ELSE 'BLOCKED' END,
        CASE WHEN v_success THEN 'NONE' ELSE v_reason END,
        CASE WHEN v_success THEN v_total ELSE 0.00 END
    );

    INSERT INTO pos_transaction_item (
        transaction_item_id,
        transaction_id,
        product_id,
        quantity,
        unit_price,
        line_amount
    )
    VALUES (
        v_item_id,
        v_txn_id,
        p_product_id,
        p_quantity,
        v_unit_price,
        v_total
    );

    RETURN QUERY
    SELECT v_txn_id,
           CASE WHEN v_success THEN 'COMPLETED' ELSE 'BLOCKED' END::VARCHAR,
           CASE WHEN v_success THEN 'NONE' ELSE v_reason END::VARCHAR;
END;
$$;

-- Insert-only form used by the Metabase "Make POS sale" action.
CREATE OR REPLACE VIEW pos_sale_form AS
SELECT NULL::VARCHAR(20) AS store_id,
       NULL::VARCHAR(20) AS product_id,
       NULL::INTEGER     AS quantity
WHERE FALSE;

CREATE OR REPLACE FUNCTION pos_sale_form_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pos_attempt_sale(NEW.store_id, NEW.product_id, NEW.quantity);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pos_sale_form ON pos_sale_form;
CREATE TRIGGER trg_pos_sale_form
INSTEAD OF INSERT ON pos_sale_form
FOR EACH ROW
EXECUTE FUNCTION pos_sale_form_insert();
