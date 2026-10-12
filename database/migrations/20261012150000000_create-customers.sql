-- Up Migration

-- Generates customer codes C0001, C0002, ... when staff do not choose their own.
CREATE SEQUENCE customer_code_seq;

-- Customers (spec 6.5). Only what billing and deliveries need: no other personal details.
-- Customers are deactivated, never deleted, so their dispatch and invoice history stays valid.
CREATE TABLE customers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code         text NOT NULL,
  name         text NOT NULL,
  phone        text,
  address      text,
  -- Most the customer may owe at once, in the base currency. NULL means no limit set.
  credit_limit numeric(12, 2),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT customers_code_key UNIQUE (code),
  -- Stored in upper case, so "c0001" and "C0001" cannot both exist.
  CONSTRAINT customers_code_format CHECK (code ~ '^[A-Z0-9][A-Z0-9._-]{0,19}$'),
  CONSTRAINT customers_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 120),
  CONSTRAINT customers_phone_format CHECK (phone ~ '^\+?[0-9][0-9 ()-]{5,22}$'),
  CONSTRAINT customers_address_valid
    CHECK (address = btrim(address) AND length(address) BETWEEN 1 AND 300),
  CONSTRAINT customers_credit_limit_not_negative CHECK (credit_limit >= 0)
);

CREATE INDEX customers_name_idx ON customers (lower(name));

CREATE TRIGGER customers_set_updated_at
  BEFORE UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

REVOKE DELETE ON customers FROM snackify_app;

-- Down Migration

DROP TABLE customers;
DROP SEQUENCE customer_code_seq;
