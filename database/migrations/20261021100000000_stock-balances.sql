-- Up Migration

-- StockFlow Stage 4.2 and 4.3 (docs/STAGE_3_5_PLAN.md): stock balances keyed by
-- product + owner organisation + warehouse + batch, kept in step with the ledger by a trigger.
-- The API role cannot write balances itself, so a balance can never change without a ledger
-- entry, and both are saved in the same transaction.

-- ------------------------------------------------------------------ Ledger columns

-- Where the stock is (location is not ownership: owner_organisation_id says who owns it).
ALTER TABLE stock_movements
  ADD COLUMN warehouse_id uuid NOT NULL DEFAULT default_warehouse_id() REFERENCES warehouses (id);
ALTER TABLE stock_batches
  ADD COLUMN warehouse_id uuid NOT NULL DEFAULT default_warehouse_id() REFERENCES warehouses (id);

-- The unit and quantity as entered (e.g. 2 cartons), when not the product's base unit.
-- quantity_delta is always in base units.
ALTER TABLE stock_movements ADD COLUMN unit_id uuid REFERENCES units (id);
ALTER TABLE stock_movements ADD COLUMN entered_quantity integer;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_entered_quantity_valid
  CHECK ((unit_id IS NULL) = (entered_quantity IS NULL) AND (entered_quantity IS NULL OR entered_quantity > 0));

-- The document behind a movement, e.g. a goods-received note.
ALTER TABLE stock_movements ADD COLUMN related_document_type text;
ALTER TABLE stock_movements ADD COLUMN related_document_id uuid;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_related_document_valid
  CHECK ((related_document_type IS NULL) = (related_document_id IS NULL)
         AND (related_document_type IS NULL OR related_document_type ~ '^[a-z_]{1,40}$'));

-- Every movement has its own unique reference, M0000001, M0000002, ... (in recorded order).
CREATE SEQUENCE stock_movement_number_seq;
ALTER TABLE stock_movements ADD COLUMN movement_number text;
UPDATE stock_movements m
SET movement_number = 'M' || lpad(numbered.n::text, 7, '0')
FROM (SELECT id, row_number() OVER (ORDER BY occurred_at, id) AS n FROM stock_movements) numbered
WHERE numbered.id = m.id;
SELECT setval('stock_movement_number_seq', GREATEST((SELECT count(*) FROM stock_movements), 1),
              (SELECT count(*) FROM stock_movements) > 0);
ALTER TABLE stock_movements
  ALTER COLUMN movement_number SET DEFAULT 'M' || lpad(nextval('stock_movement_number_seq')::text, 7, '0'),
  ALTER COLUMN movement_number SET NOT NULL;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_number_key UNIQUE (movement_number);

-- Movement types reserved for later stages (custody releases, transfers, supplier returns).
-- The spec's PURCHASE_RECEIPT is "receipt", HQ_SALE_DISPATCH "dispatch", WRITE_OFF "damage".
ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_type_valid;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_type_valid CHECK (movement_type IN (
  'opening_balance', 'receipt', 'dispatch', 'customer_return', 'damage', 'adjustment', 'reversal',
  'custody_release', 'internal_transfer', 'return_to_supplier'
));
ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_direction;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_direction CHECK (
  (movement_type IN ('opening_balance', 'receipt', 'customer_return') AND quantity_delta > 0)
  OR (movement_type IN ('dispatch', 'damage', 'custody_release', 'return_to_supplier')
      AND quantity_delta < 0)
  OR movement_type IN ('adjustment', 'reversal', 'internal_transfer')
);

-- ------------------------------------------------------------------ Balances

-- The view of the same name (Stage 3) is replaced by a table.
DROP VIEW stock_balances;

CREATE TABLE stock_balances (
  product_id            uuid NOT NULL REFERENCES products (id),
  owner_organisation_id uuid NOT NULL REFERENCES organisations (id),
  warehouse_id          uuid NOT NULL REFERENCES warehouses (id),
  -- NULL: stock not tied to a delivery (e.g. a count correction upwards).
  batch_id              uuid REFERENCES stock_batches (id),
  quantity_on_hand      integer NOT NULL DEFAULT 0,
  -- Set aside for approved orders (Stage 5 and 6). Available = on hand - reserved, calculated
  -- when read, never stored.
  quantity_reserved     integer NOT NULL DEFAULT 0,
  updated_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT stock_balances_key
    UNIQUE NULLS NOT DISTINCT (product_id, owner_organisation_id, warehouse_id, batch_id),
  CONSTRAINT stock_balances_on_hand_not_negative CHECK (quantity_on_hand >= 0),
  CONSTRAINT stock_balances_reserved_valid
    CHECK (quantity_reserved >= 0 AND quantity_reserved <= quantity_on_hand)
);
CREATE INDEX stock_balances_owner_idx ON stock_balances (owner_organisation_id, product_id);
CREATE INDEX stock_balances_batch_idx ON stock_balances (batch_id);

-- Fill it from the ledger. Movements recorded before this stage did not say which delivery they
-- took stock from, so each product's remaining stock is assigned to its newest deliveries
-- (the oldest are assumed sold first); anything beyond them is stock without a batch.
-- From now on every movement says exactly which batch it changes.
WITH totals AS (
  SELECT product_id, owner_organisation_id, sum(quantity_delta)::integer AS on_hand
  FROM stock_movements GROUP BY product_id, owner_organisation_id
),
batches AS (
  SELECT b.id, b.product_id, b.owner_organisation_id, b.warehouse_id, b.quantity_received,
         COALESCE(sum(b.quantity_received) OVER (
           PARTITION BY b.product_id, b.owner_organisation_id
           ORDER BY b.received_date DESC, b.created_at DESC, b.id DESC
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS newer
  FROM stock_batches b
),
per_batch AS (
  SELECT b.product_id, b.owner_organisation_id, b.warehouse_id, b.id AS batch_id,
         GREATEST(0, LEAST(b.quantity_received, t.on_hand - b.newer))::integer AS quantity
  FROM batches b
  JOIN totals t USING (product_id, owner_organisation_id)
),
unbatched AS (
  SELECT t.product_id, t.owner_organisation_id, default_warehouse_id() AS warehouse_id,
         NULL::uuid AS batch_id,
         (t.on_hand - COALESCE((SELECT sum(p.quantity) FROM per_batch p
                                WHERE p.product_id = t.product_id
                                  AND p.owner_organisation_id = t.owner_organisation_id), 0))::integer
           AS quantity
  FROM totals t
)
INSERT INTO stock_balances (product_id, owner_organisation_id, warehouse_id, batch_id, quantity_on_hand)
SELECT product_id, owner_organisation_id, warehouse_id, batch_id, quantity
FROM (SELECT * FROM per_batch UNION ALL SELECT * FROM unbatched) rows
WHERE quantity > 0;

-- Every new ledger entry changes its balance row, in the same transaction. Owned by the schema
-- owner (SECURITY DEFINER), because the API role may not write balances directly. A movement
-- that would take a balance below zero fails with stock_balances_on_hand_not_negative.
CREATE FUNCTION apply_stock_movement() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Update first: an INSERT ... ON CONFLICT would check "not below zero" on the row it tries
  -- to insert (the bare delta) before noticing the row exists, and refuse every removal.
  UPDATE stock_balances
  SET quantity_on_hand = quantity_on_hand + NEW.quantity_delta, updated_at = now()
  WHERE product_id = NEW.product_id
    AND owner_organisation_id = NEW.owner_organisation_id
    AND warehouse_id = NEW.warehouse_id
    AND batch_id IS NOT DISTINCT FROM NEW.batch_id;
  IF NOT FOUND THEN
    INSERT INTO stock_balances
      (product_id, owner_organisation_id, warehouse_id, batch_id, quantity_on_hand)
    VALUES (NEW.product_id, NEW.owner_organisation_id, NEW.warehouse_id, NEW.batch_id,
            NEW.quantity_delta);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION apply_stock_movement() FROM PUBLIC;

CREATE TRIGGER stock_movements_apply
  AFTER INSERT ON stock_movements
  FOR EACH ROW EXECUTE FUNCTION apply_stock_movement();

REVOKE INSERT, UPDATE, DELETE ON stock_balances FROM snackify_app;

-- The Head Office's own stock per product (all its warehouses): what dispatches, forecasts and
-- reports use. It never includes stock owned by a subsidiary.
CREATE VIEW hq_stock_on_hand AS
SELECT p.id AS product_id,
       COALESCE(sum(b.quantity_on_hand), 0)::integer AS quantity_on_hand,
       COALESCE(sum(b.quantity_reserved), 0)::integer AS quantity_reserved
FROM products p
LEFT JOIN stock_balances b
  ON b.product_id = p.id AND b.owner_organisation_id = hq_organisation_id()
GROUP BY p.id;
REVOKE INSERT, UPDATE, DELETE ON hq_stock_on_hand FROM snackify_app;

-- Down Migration

DROP VIEW hq_stock_on_hand;
DROP TRIGGER stock_movements_apply ON stock_movements;
DROP FUNCTION apply_stock_movement();
DROP TABLE stock_balances;
CREATE VIEW stock_balances AS
SELECT p.id AS product_id, COALESCE(sum(m.quantity_delta), 0)::integer AS quantity_on_hand
FROM products p
LEFT JOIN stock_movements m
  ON m.product_id = p.id AND m.owner_organisation_id = hq_organisation_id()
GROUP BY p.id;

ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_direction;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_direction CHECK (
  (movement_type IN ('opening_balance', 'receipt', 'customer_return') AND quantity_delta > 0)
  OR (movement_type IN ('dispatch', 'damage') AND quantity_delta < 0)
  OR movement_type IN ('adjustment', 'reversal')
);
ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_type_valid;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_type_valid CHECK (movement_type IN (
  'opening_balance', 'receipt', 'dispatch', 'customer_return', 'damage', 'adjustment', 'reversal'
));
ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_number_key;
ALTER TABLE stock_movements DROP COLUMN movement_number;
DROP SEQUENCE stock_movement_number_seq;
ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_related_document_valid;
ALTER TABLE stock_movements DROP COLUMN related_document_id;
ALTER TABLE stock_movements DROP COLUMN related_document_type;
ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_entered_quantity_valid;
ALTER TABLE stock_movements DROP COLUMN entered_quantity;
ALTER TABLE stock_movements DROP COLUMN unit_id;
ALTER TABLE stock_batches DROP COLUMN warehouse_id;
ALTER TABLE stock_movements DROP COLUMN warehouse_id;
