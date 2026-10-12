-- Up Migration

-- Keeps updated_at current on every UPDATE. Reused by later tables.
CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- One row per sellable variation, e.g. "Potato Crisps — BBQ — Small" (spec 6.2).
-- default_price is in the business's base currency; transactions will store their own
-- price snapshot and currency, so changing it never rewrites history.
CREATE TABLE products (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sku           text NOT NULL,
  name          text NOT NULL,
  flavour       text NOT NULL,
  size          text NOT NULL,
  barcode       text,
  default_price numeric(12, 2) NOT NULL,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT products_sku_key UNIQUE (sku),
  -- Several products may have no barcode (NULL), but an assigned barcode is unique.
  CONSTRAINT products_barcode_key UNIQUE (barcode),
  -- SKUs are stored in upper case, so "pc-bbq-s" and "PC-BBQ-S" cannot both exist.
  CONSTRAINT products_sku_format CHECK (sku ~ '^[A-Z0-9][A-Z0-9._-]{0,39}$'),
  CONSTRAINT products_barcode_format CHECK (barcode ~ '^[A-Za-z0-9-]{4,48}$'),
  CONSTRAINT products_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 100),
  CONSTRAINT products_flavour_valid CHECK (flavour = btrim(flavour) AND length(flavour) BETWEEN 1 AND 60),
  CONSTRAINT products_size_valid CHECK (size = btrim(size) AND length(size) BETWEEN 1 AND 40),
  CONSTRAINT products_default_price_not_negative CHECK (default_price >= 0)
);

-- The same name + flavour + size must not be registered twice, ignoring letter case.
CREATE UNIQUE INDEX products_variation_key ON products (lower(name), lower(flavour), lower(size));

CREATE TRIGGER products_set_updated_at
  BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Products are deactivated, never deleted, so history that references them stays valid.
REVOKE DELETE ON products FROM snackify_app;

-- The API must not be able to change the record of which migrations have run.
REVOKE ALL ON schema_migrations FROM snackify_app;

-- Down Migration

DROP TABLE products;
DROP FUNCTION set_updated_at();
