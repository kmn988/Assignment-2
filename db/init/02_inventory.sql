\connect inventory_db

BEGIN;

CREATE TABLE product (
    product_id VARCHAR(20) PRIMARY KEY,
    sku VARCHAR(50) NOT NULL UNIQUE,
    product_name VARCHAR(150) NOT NULL,
    category VARCHAR(50) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    active_flag BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE store (
    store_id VARCHAR(20) PRIMARY KEY,
    store_name VARCHAR(100) NOT NULL,
    location VARCHAR(150) NOT NULL,
    active_flag BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE inventory (
    inventory_id VARCHAR(20) PRIMARY KEY,
    product_id VARCHAR(20) NOT NULL REFERENCES product(product_id),
    store_id VARCHAR(20) NOT NULL REFERENCES store(store_id),
    on_hand_quantity INTEGER NOT NULL DEFAULT 0 CHECK (on_hand_quantity >= 0),
    reserved_quantity INTEGER NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
    available_to_sell INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (product_id, store_id),
    CHECK (reserved_quantity <= on_hand_quantity),
    CHECK (available_to_sell = on_hand_quantity - reserved_quantity)
);

CREATE TABLE inventory_movement (
    movement_id VARCHAR(50) PRIMARY KEY,
    product_id VARCHAR(20) NOT NULL,
    store_id VARCHAR(20) NOT NULL,
    movement_type VARCHAR(30) NOT NULL,
    quantity_change INTEGER NOT NULL,
    source_system VARCHAR(30) NOT NULL,
    source_reference_id VARCHAR(100),
    movement_timestamp TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id, store_id)
        REFERENCES inventory(product_id, store_id)
);

CREATE OR REPLACE FUNCTION calculate_available_to_sell()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.available_to_sell :=
        NEW.on_hand_quantity - NEW.reserved_quantity;
    RETURN NEW;
END;
$$;

CREATE TRIGGER calculate_available_to_sell
BEFORE INSERT OR UPDATE ON inventory
FOR EACH ROW
EXECUTE FUNCTION calculate_available_to_sell();

CREATE OR REPLACE FUNCTION reserve_stock(
    p_product_id VARCHAR,
    p_store_id VARCHAR,
    p_quantity INTEGER,
    p_reservation_reference VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_available INTEGER;
    v_previous_quantity INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Reservation quantity must be greater than zero';
    END IF;

    IF p_reservation_reference IS NULL
       OR BTRIM(p_reservation_reference) = '' THEN
        RAISE EXCEPTION 'Reservation reference is required';
    END IF;

    SELECT available_to_sell
    INTO v_available
    FROM inventory
    WHERE product_id = p_product_id
      AND store_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT -quantity_change
    INTO v_previous_quantity
    FROM inventory_movement
    WHERE product_id = p_product_id
      AND store_id = p_store_id
      AND movement_type = 'ONLINE_RESERVATION'
      AND source_system = 'ECOMMERCE'
      AND source_reference_id = p_reservation_reference;

    IF FOUND THEN
        IF v_previous_quantity <> p_quantity THEN
            RAISE EXCEPTION
                'This reservation reference was already used with a different quantity';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM inventory_movement
            WHERE product_id = p_product_id
              AND store_id = p_store_id
              AND source_system = 'ECOMMERCE'
              AND source_reference_id = p_reservation_reference
              AND movement_type IN (
                  'RESERVATION_RELEASE', 'RESERVATION_COLLECTION'
              )
        ) THEN
            RETURN FALSE;
        END IF;

        RETURN TRUE;
    END IF;

    IF v_available < p_quantity THEN
        RETURN FALSE;
    END IF;

    UPDATE inventory
    SET reserved_quantity = reserved_quantity + p_quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE product_id = p_product_id
      AND store_id = p_store_id;

    INSERT INTO inventory_movement (
        movement_id, product_id, store_id, movement_type,
        quantity_change, source_system, source_reference_id, movement_timestamp
    )
    VALUES (
        'M-' || gen_random_uuid()::TEXT, p_product_id, p_store_id, 'ONLINE_RESERVATION',
        -p_quantity, 'ECOMMERCE', p_reservation_reference, CURRENT_TIMESTAMP
    );

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION sell_stock(
    p_product_id VARCHAR,
    p_store_id VARCHAR,
    p_quantity INTEGER,
    p_transaction_reference VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_available INTEGER;
    v_previous_quantity INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Sale quantity must be greater than zero';
    END IF;

    IF p_transaction_reference IS NULL
       OR BTRIM(p_transaction_reference) = '' THEN
        RAISE EXCEPTION 'Transaction reference is required';
    END IF;

    SELECT available_to_sell
    INTO v_available
    FROM inventory
    WHERE product_id = p_product_id
      AND store_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT -quantity_change
    INTO v_previous_quantity
    FROM inventory_movement
    WHERE product_id = p_product_id
      AND store_id = p_store_id
      AND movement_type = 'POS_SALE'
      AND source_system = 'POS'
      AND source_reference_id = p_transaction_reference;

    IF FOUND THEN
        IF v_previous_quantity <> p_quantity THEN
            RAISE EXCEPTION
                'This transaction reference was already used with a different quantity';
        END IF;
        RETURN TRUE;
    END IF;

    IF v_available < p_quantity THEN
        RETURN FALSE;
    END IF;

    UPDATE inventory
    SET on_hand_quantity = on_hand_quantity - p_quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE product_id = p_product_id
      AND store_id = p_store_id;

    INSERT INTO inventory_movement (
        movement_id, product_id, store_id, movement_type,
        quantity_change, source_system, source_reference_id, movement_timestamp
    )
    VALUES (
        'M-' || gen_random_uuid()::TEXT, p_product_id, p_store_id, 'POS_SALE',
        -p_quantity, 'POS', p_transaction_reference, CURRENT_TIMESTAMP
    );

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION release_stock(
    p_product_id VARCHAR,
    p_store_id VARCHAR,
    p_quantity INTEGER,
    p_reservation_reference VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_reserved_quantity INTEGER;
    v_reference_balance BIGINT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Release quantity must be greater than zero';
    END IF;

    IF p_reservation_reference IS NULL
       OR BTRIM(p_reservation_reference) = '' THEN
        RAISE EXCEPTION 'Reservation reference is required';
    END IF;

    SELECT reserved_quantity
    INTO v_reserved_quantity
    FROM inventory
    WHERE product_id = p_product_id
      AND store_id = p_store_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT COALESCE(SUM(
        CASE
            WHEN movement_type = 'ONLINE_RESERVATION' THEN -quantity_change
            WHEN movement_type = 'RESERVATION_RELEASE' THEN -quantity_change
            WHEN movement_type = 'RESERVATION_COLLECTION' THEN quantity_change
        END
    ), 0)
    INTO v_reference_balance
    FROM inventory_movement
    WHERE product_id = p_product_id
      AND store_id = p_store_id
      AND source_system = 'ECOMMERCE'
      AND source_reference_id = p_reservation_reference
      AND movement_type IN (
          'ONLINE_RESERVATION', 'RESERVATION_RELEASE', 'RESERVATION_COLLECTION'
      );

    IF v_reference_balance < p_quantity
       OR v_reserved_quantity < p_quantity THEN
        RETURN FALSE;
    END IF;

    UPDATE inventory
    SET reserved_quantity = reserved_quantity - p_quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE product_id = p_product_id
      AND store_id = p_store_id;

    INSERT INTO inventory_movement (
        movement_id, product_id, store_id, movement_type,
        quantity_change, source_system, source_reference_id, movement_timestamp
    )
    VALUES (
        'M-' || gen_random_uuid()::TEXT, p_product_id, p_store_id, 'RESERVATION_RELEASE',
        p_quantity, 'ECOMMERCE', p_reservation_reference, CURRENT_TIMESTAMP
    );

    RETURN TRUE;
END;
$$;

COMMIT;