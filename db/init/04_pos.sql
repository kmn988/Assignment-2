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
-- POS sale attempt
-- Stock belongs to Inventory (inventory_db), so POS asks Inventory before it
-- records a sale. dblink runs one query in inventory_db:
--   sell_stock(...)  checks Available-to-Sell (= on-hand - reserved) and, only if enough
--                    is available, takes the stock in one atomic step. It returns
--                    (success, reason): reason is NONE, RESERVED_STOCK (units are on hand
--                    but reserved) or OUT_OF_STOCK, and POS stores that reason as it is.
-- Result: COMPLETED/NONE, or BLOCKED with the reason Inventory gave. A blocked attempt is
-- stored too (total 0.00, item kept), as in the seed data, so it feeds the warehouse.
--
-- pos_sale_form is an insert-only "form" so a Metabase Action (which can only run
-- INSERT / UPDATE) can make a sale.
-- Limit: sell_stock commits in inventory_db on its own, so the stock change is not
-- rolled back if the insert below fails.
-- ---------------------------------------------------------------------------
-- BEGIN live-demo functions
CREATE EXTENSION IF NOT EXISTS dblink;

-- Older version (integer ids, employee / payment / receipt tables) no longer matches the tables above
DROP FUNCTION IF EXISTS pos_attempt_sale(INT, INT, INT, INT, NUMERIC);

-- Shared ID format: prefix + at least 3 digits (T051, TI051)
CREATE OR REPLACE FUNCTION shared_id(p_prefix TEXT, p_number INTEGER)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT p_prefix || LPAD(p_number::TEXT, GREATEST(3, LENGTH(p_number::TEXT)), '0');
$$;

CREATE OR REPLACE FUNCTION pos_attempt_sale(
    p_store_id VARCHAR,
    p_product_id VARCHAR,
    p_quantity INTEGER
)
RETURNS TABLE (
    out_transaction_id VARCHAR,
    out_transaction_status VARCHAR,
    out_rejection_reason VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price  NUMERIC(10,2);
    v_line_amount NUMERIC(10,2);
    v_txn_id      VARCHAR(20);
    v_item_id     VARCHAR(20);
    v_sold        BOOLEAN;
    v_status      VARCHAR(20);
    v_reason      VARCHAR(255);
    v_total       NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be greater than zero';
    END IF;

    -- Product master data (and its price) belongs to inventory_db
    SELECT t.unit_price
    INTO v_unit_price
    FROM dblink(
        'dbname=inventory_db',
        format('SELECT unit_price FROM product WHERE product_id = %L', p_product_id)
    ) AS t(unit_price NUMERIC);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown product %', p_product_id;
    END IF;

    v_line_amount := p_quantity * v_unit_price;

    -- Serialise ID generation so two attempts cannot receive the same ID
    PERFORM pg_advisory_xact_lock(hashtext('pos_shared_ids'));

    SELECT shared_id('T', COALESCE(MAX(regexp_replace(transaction_id, '\D', '', 'g')::INTEGER), 0) + 1)
    INTO v_txn_id FROM pos_transaction;

    SELECT shared_id('TI', COALESCE(MAX(regexp_replace(transaction_item_id, '\D', '', 'g')::INTEGER), 0) + 1)
    INTO v_item_id FROM pos_transaction_item;

    -- Ask Inventory whether the sale is allowed. sell_stock returns (success, reason); the
    -- transaction ID is the idempotency reference, so a retry cannot take the stock twice.
    SELECT s.success, s.reason
    INTO v_sold, v_reason
    FROM dblink(
        'dbname=inventory_db',
        format('SELECT success, reason FROM sell_stock(%L, %L, %s, %L)',
               p_product_id, p_store_id, p_quantity, v_txn_id)
    ) AS s(success BOOLEAN, reason VARCHAR);

    IF v_sold IS TRUE THEN
        v_status := 'COMPLETED';
        v_reason := 'NONE';
        v_total  := v_line_amount;
    ELSE
        v_status := 'BLOCKED';
        v_reason := COALESCE(v_reason, 'OUT_OF_STOCK');
        v_total  := 0.00;
    END IF;

    INSERT INTO pos_transaction (
        transaction_id, store_id, transaction_status, rejection_reason, total_amount
    )
    VALUES (v_txn_id, p_store_id, v_status, v_reason, v_total);

    INSERT INTO pos_transaction_item (
        transaction_item_id, transaction_id, product_id, quantity, unit_price, line_amount
    )
    VALUES (v_item_id, v_txn_id, p_product_id, p_quantity, v_unit_price, v_line_amount);

    RETURN QUERY SELECT v_txn_id::VARCHAR, v_status::VARCHAR, v_reason::VARCHAR;
END;
$$;

-- Insert-only form used by the Metabase "Make POS sale" action
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
-- END live-demo functions