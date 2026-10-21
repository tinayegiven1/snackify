-- Up Migration

-- StockFlow Stage 4.1 (docs/STAGE_3_5_PLAN.md): product categories, units of measure and
-- conversions, suppliers and warehouses. Additive: existing products get the base unit "pack".

-- ------------------------------------------------------------------ Categories

CREATE TABLE product_categories (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT product_categories_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 60)
);
CREATE UNIQUE INDEX product_categories_name_key ON product_categories (lower(name));
CREATE TRIGGER product_categories_set_updated_at
  BEFORE UPDATE ON product_categories FOR EACH ROW EXECUTE FUNCTION set_updated_at();
REVOKE DELETE ON product_categories FROM snackify_app;

-- ------------------------------------------------------------------ Units

-- A unit of measure, e.g. pack or carton. Stock is always counted in each product's base unit;
-- other units are converted with unit_conversions and recorded as entered.
CREATE TABLE units (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text NOT NULL,
  name       text NOT NULL,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT units_code_key UNIQUE (code),
  CONSTRAINT units_code_format CHECK (code ~ '^[a-z][a-z0-9_]{0,19}$'),
  CONSTRAINT units_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 40)
);
REVOKE DELETE ON units FROM snackify_app;

INSERT INTO units (code, name) VALUES ('pack', 'Pack'), ('carton', 'Carton'), ('case', 'Case');

CREATE FUNCTION pack_unit_id() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM units WHERE code = 'pack' $$;

-- ------------------------------------------------------------------ Products

ALTER TABLE products ADD COLUMN description text;
ALTER TABLE products ADD CONSTRAINT products_description_valid
  CHECK (description = btrim(description) AND length(description) BETWEEN 1 AND 500);
ALTER TABLE products ADD COLUMN category_id uuid REFERENCES product_categories (id);
ALTER TABLE products ADD COLUMN base_unit_id uuid NOT NULL DEFAULT pack_unit_id() REFERENCES units (id);
CREATE INDEX products_category_idx ON products (category_id);

-- How many base units one of another unit holds, per product: e.g. 1 carton = 24 packs.
-- Never between incompatible units: only whole numbers of the product's base unit.
CREATE TABLE unit_conversions (
  product_id    uuid NOT NULL REFERENCES products (id),
  unit_id       uuid NOT NULL REFERENCES units (id),
  base_quantity integer NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (product_id, unit_id),
  CONSTRAINT unit_conversions_base_quantity_valid CHECK (base_quantity BETWEEN 2 AND 100000)
);

-- A product's own base unit never has a conversion (it is always 1).
CREATE FUNCTION check_unit_conversion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM products WHERE id = NEW.product_id AND base_unit_id = NEW.unit_id) THEN
    RAISE EXCEPTION 'A product''s base unit needs no conversion'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'unit_conversions_not_base_unit';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER unit_conversions_not_base_unit
  BEFORE INSERT OR UPDATE ON unit_conversions
  FOR EACH ROW EXECUTE FUNCTION check_unit_conversion();

-- ------------------------------------------------------------------ Suppliers

CREATE TABLE suppliers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code         text NOT NULL,
  name         text NOT NULL,
  contact_name text,
  phone        text,
  email        text,
  address      text,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT suppliers_code_key UNIQUE (code),
  CONSTRAINT suppliers_code_format CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{1,19}$'),
  CONSTRAINT suppliers_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 120),
  CONSTRAINT suppliers_contact_name_valid
    CHECK (contact_name = btrim(contact_name) AND length(contact_name) BETWEEN 1 AND 120),
  CONSTRAINT suppliers_phone_format CHECK (phone ~ '^\+?[0-9][0-9 ()-]{5,22}$'),
  CONSTRAINT suppliers_email_format CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(email) <= 254),
  CONSTRAINT suppliers_address_valid
    CHECK (address = btrim(address) AND length(address) BETWEEN 1 AND 300)
);
CREATE TRIGGER suppliers_set_updated_at
  BEFORE UPDATE ON suppliers FOR EACH ROW EXECUTE FUNCTION set_updated_at();
REVOKE DELETE ON suppliers FROM snackify_app;

-- ------------------------------------------------------------------ Warehouses

-- A place stock is kept. Physical location is not ownership: one warehouse holds stock owned
-- by several organisations. Exactly one is the default (where today's screens keep stock).
CREATE TABLE warehouses (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code            text NOT NULL,
  name            text NOT NULL,
  address         text,
  -- The organisation that runs it (the Head Office's warehouse holds subsidiaries' stock too).
  organisation_id uuid NOT NULL REFERENCES organisations (id),
  is_default      boolean NOT NULL DEFAULT false,
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT warehouses_code_key UNIQUE (code),
  CONSTRAINT warehouses_code_format CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{1,19}$'),
  CONSTRAINT warehouses_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 120),
  CONSTRAINT warehouses_address_valid
    CHECK (address = btrim(address) AND length(address) BETWEEN 1 AND 300),
  CONSTRAINT warehouses_default_active CHECK (NOT is_default OR is_active)
);
CREATE UNIQUE INDEX warehouses_one_default ON warehouses ((true)) WHERE is_default;
CREATE TRIGGER warehouses_set_updated_at
  BEFORE UPDATE ON warehouses FOR EACH ROW EXECUTE FUNCTION set_updated_at();
REVOKE DELETE ON warehouses FROM snackify_app;

INSERT INTO warehouses (code, name, organisation_id, is_default)
VALUES ('HQ-MAIN', 'Head Office main warehouse', hq_organisation_id(), true);

CREATE FUNCTION default_warehouse_id() RETURNS uuid
LANGUAGE sql STABLE AS $$ SELECT id FROM warehouses WHERE is_default $$;

-- ------------------------------------------------------------------ Permissions

INSERT INTO permissions (code, description) VALUES
  ('catalogue.manage', 'Manage product categories, units, unit conversions and warehouses'),
  ('supplier.manage', 'Add suppliers and change their details');

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, grants.permission_code
FROM (VALUES
  ('system_admin', 'catalogue.manage'),
  ('system_admin', 'supplier.manage'),
  ('hq_warehouse_officer', 'supplier.manage')
) AS grants (role_code, permission_code)
JOIN roles r ON r.code = grants.role_code;

-- Down Migration

DELETE FROM role_permissions WHERE permission_code IN ('catalogue.manage', 'supplier.manage');
DELETE FROM permissions WHERE code IN ('catalogue.manage', 'supplier.manage');
DROP FUNCTION default_warehouse_id();
DROP TABLE warehouses;
DROP TABLE suppliers;
DROP TRIGGER unit_conversions_not_base_unit ON unit_conversions;
DROP FUNCTION check_unit_conversion();
DROP TABLE unit_conversions;
DROP INDEX products_category_idx;
ALTER TABLE products DROP COLUMN base_unit_id;
ALTER TABLE products DROP COLUMN category_id;
ALTER TABLE products DROP CONSTRAINT products_description_valid;
ALTER TABLE products DROP COLUMN description;
DROP FUNCTION pack_unit_id();
DROP TABLE units;
DROP TABLE product_categories;
