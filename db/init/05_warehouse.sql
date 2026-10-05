\connect warehouse_db

-- =====================================================================
-- 05_warehouse.sql  —  DIMENSIONAL WAREHOUSE (STAR SCHEMA)
-- Owner: Warehouse/ETL (Aravind). Miro frame 05 "Star Schema".
--
-- Runs once, on the first start (db/init). It only creates the EMPTY
-- warehouse. The ETL in etl/ fills it:  ./etl/run_etl.sh
--
-- 4 conformed dimensions shared by 4 fact tables, in schema "dw".
-- Surrogate keys (*_key) decouple the warehouse from source IDs;
-- natural keys (*_id) are kept for lineage and reconciliation.
-- =====================================================================

-- postgres_fdw lets the ETL read the three source databases from here
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

DROP SCHEMA IF EXISTS dw CASCADE;
CREATE SCHEMA dw;

-- ---------------------------------------------------------------------
-- DIMENSIONS
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_date (
    date_key     INT PRIMARY KEY,          -- YYYYMMDD, e.g. 20260928
    full_date    DATE NOT NULL UNIQUE,
    day          INT NOT NULL,
    month        INT NOT NULL,
    month_name   VARCHAR(10) NOT NULL,
    quarter      INT NOT NULL,
    year         INT NOT NULL,
    day_of_week  VARCHAR(10) NOT NULL,
    is_weekend   BOOLEAN NOT NULL
);

CREATE TABLE dw.dim_product (
    product_key   SERIAL PRIMARY KEY,
    product_id    INT NOT NULL UNIQUE,     -- natural key from Inventory.PRODUCT
    sku           VARCHAR(20) NOT NULL,
    product_name  VARCHAR(100) NOT NULL,
    category      VARCHAR(50),
    unit_price    NUMERIC(10,2) NOT NULL,
    active_flag   BOOLEAN NOT NULL
);

CREATE TABLE dw.dim_store (
    store_key    SERIAL PRIMARY KEY,
    store_id     INT NOT NULL UNIQUE,      -- natural key from Inventory.STORE
    store_name   VARCHAR(100) NOT NULL,
    location     VARCHAR(100),
    active_flag  BOOLEAN NOT NULL
);

CREATE TABLE dw.dim_customer (
    customer_key   SERIAL PRIMARY KEY,
    customer_id    INT NOT NULL UNIQUE,    -- natural key from E-Commerce.CUSTOMER
    customer_name  VARCHAR(100) NOT NULL,
    email          VARCHAR(150)
);

-- ---------------------------------------------------------------------
-- FACTS
-- ---------------------------------------------------------------------

-- Grain: one product line per POS attempt (completed OR blocked)
CREATE TABLE dw.fact_pos_activity (
    pos_fact_key         SERIAL PRIMARY KEY,
    transaction_id       INT NOT NULL,
    transaction_item_id  INT NOT NULL UNIQUE,
    product_key          INT NOT NULL REFERENCES dw.dim_product(product_key),
    store_key            INT NOT NULL REFERENCES dw.dim_store(store_key),
    date_key             INT NOT NULL REFERENCES dw.dim_date(date_key),
    quantity             INT NOT NULL,
    unit_price           NUMERIC(10,2) NOT NULL,
    line_amount          NUMERIC(10,2) NOT NULL,
    transaction_status   VARCHAR(20) NOT NULL,
    rejection_reason     VARCHAR(30)
);

-- Grain: one product line per online order
CREATE TABLE dw.fact_online_order (
    order_fact_key  SERIAL PRIMARY KEY,
    order_id        INT NOT NULL,
    order_item_id   INT NOT NULL UNIQUE,
    product_key     INT NOT NULL REFERENCES dw.dim_product(product_key),
    store_key       INT NOT NULL REFERENCES dw.dim_store(store_key),
    customer_key    INT NOT NULL REFERENCES dw.dim_customer(customer_key),
    date_key        INT NOT NULL REFERENCES dw.dim_date(date_key),
    quantity        INT NOT NULL,
    unit_price      NUMERIC(10,2) NOT NULL,
    line_amount     NUMERIC(10,2) NOT NULL,
    order_status    VARCHAR(20) NOT NULL
);

-- Grain: one reservation
CREATE TABLE dw.fact_reservation (
    reservation_fact_key  SERIAL PRIMARY KEY,
    reservation_id        INT NOT NULL UNIQUE,
    order_id              INT NOT NULL,
    product_key           INT NOT NULL REFERENCES dw.dim_product(product_key),
    store_key             INT NOT NULL REFERENCES dw.dim_store(store_key),
    customer_key          INT NOT NULL REFERENCES dw.dim_customer(customer_key),
    date_key              INT NOT NULL REFERENCES dw.dim_date(date_key),
    quantity              INT NOT NULL,
    reservation_status    VARCHAR(20) NOT NULL
);

-- Grain: product · store · date (periodic snapshot, one row per ETL run date)
CREATE TABLE dw.fact_inventory_snapshot (
    inventory_fact_key  SERIAL PRIMARY KEY,
    product_key         INT NOT NULL REFERENCES dw.dim_product(product_key),
    store_key           INT NOT NULL REFERENCES dw.dim_store(store_key),
    date_key            INT NOT NULL REFERENCES dw.dim_date(date_key),
    on_hand_quantity    INT NOT NULL,
    reserved_quantity   INT NOT NULL,
    available_to_sell   INT NOT NULL,
    CONSTRAINT uq_snapshot_grain UNIQUE (product_key, store_key, date_key),
    CONSTRAINT ck_ats_formula CHECK (available_to_sell = on_hand_quantity - reserved_quantity)
);

-- Indexes on fact foreign keys (star-join performance)
CREATE INDEX ix_pos_product  ON dw.fact_pos_activity (product_key);
CREATE INDEX ix_pos_store    ON dw.fact_pos_activity (store_key);
CREATE INDEX ix_pos_date     ON dw.fact_pos_activity (date_key);
CREATE INDEX ix_ord_product  ON dw.fact_online_order (product_key);
CREATE INDEX ix_ord_store    ON dw.fact_online_order (store_key);
CREATE INDEX ix_ord_date     ON dw.fact_online_order (date_key);
CREATE INDEX ix_res_product  ON dw.fact_reservation (product_key);
CREATE INDEX ix_res_store    ON dw.fact_reservation (store_key);
CREATE INDEX ix_snap_date    ON dw.fact_inventory_snapshot (date_key);

-- ETL audit tables
CREATE TABLE dw.etl_reject_log (
    reject_id      SERIAL PRIMARY KEY,
    source_table   VARCHAR(50) NOT NULL,
    record_id      TEXT,
    reject_reason  VARCHAR(100) NOT NULL,
    rejected_at    TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE dw.etl_run_log (
    run_id        SERIAL PRIMARY KEY,
    step          VARCHAR(50) NOT NULL,
    rows_affected INT,
    logged_at     TIMESTAMP NOT NULL DEFAULT now()
);
