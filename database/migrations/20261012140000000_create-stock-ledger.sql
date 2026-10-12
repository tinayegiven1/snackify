-- Up Migration

-- Optional low-stock alert level per product (spec 6.3). NULL means "no alert".
ALTER TABLE products ADD COLUMN reorder_level integer;
ALTER TABLE products ADD CONSTRAINT products_reorder_level_not_negative CHECK (reorder_level >= 0);

-- Stock received: one row per delivery of one product (spec 6.3 and 7).
-- Receipts are never edited; mistakes are corrected with a stock adjustment.
CREATE TABLE stock_batches (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id         uuid NOT NULL REFERENCES products (id),
  quantity_received  integer NOT NULL,
  -- The business day the stock arrived (Africa/Harare), not the moment it was typed in.
  received_date      date NOT NULL,
  batch_number       text,
  expiry_date        date,
  -- Supplier name or delivery-note number, if any.
  supplier_reference text,
  -- Stock that was already on the shelf when the business started using Snackify.
  is_opening_balance boolean NOT NULL DEFAULT false,
  received_by        uuid NOT NULL REFERENCES users (id),
  created_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT stock_batches_quantity_positive CHECK (quantity_received > 0),
  CONSTRAINT stock_batches_expiry_not_before_received CHECK (expiry_date >= received_date),
  CONSTRAINT stock_batches_batch_number_valid
    CHECK (batch_number = btrim(batch_number) AND length(batch_number) BETWEEN 1 AND 60),
  CONSTRAINT stock_batches_supplier_reference_valid
    CHECK (supplier_reference = btrim(supplier_reference) AND length(supplier_reference) BETWEEN 1 AND 120)
);

CREATE INDEX stock_batches_received_date_idx ON stock_batches (received_date);
CREATE INDEX stock_batches_product_idx ON stock_batches (product_id, received_date);

REVOKE UPDATE, DELETE ON stock_batches FROM snackify_app;

-- The stock ledger (spec 6.4). Every change in stock is one row: positive quantity_delta adds
-- stock, negative removes it. Rows are never changed or deleted, and the stock on hand is
-- always the sum of the ledger, so the balance and its history cannot disagree.
CREATE TABLE stock_movements (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id           uuid NOT NULL REFERENCES products (id),
  batch_id             uuid REFERENCES stock_batches (id),
  movement_type        text NOT NULL,
  quantity_delta       integer NOT NULL,
  -- The business day the movement belongs to (Africa/Harare).
  business_date        date NOT NULL,
  occurred_at          timestamptz NOT NULL DEFAULT now(),
  created_by           uuid NOT NULL REFERENCES users (id),
  -- A document number such as a delivery note (receipts) or dispatch number (later).
  reference            text,
  -- Why stock was changed by hand. Required for damage, adjustments and reversals.
  reason               text,
  -- For a reversal: the movement it cancels (used by later stages).
  reverses_movement_id uuid REFERENCES stock_movements (id),

  CONSTRAINT stock_movements_type_valid CHECK (movement_type IN (
    'opening_balance', 'receipt', 'dispatch', 'customer_return', 'damage', 'adjustment', 'reversal'
  )),
  CONSTRAINT stock_movements_delta_not_zero CHECK (quantity_delta <> 0),
  -- Receipts and returns add stock; dispatches and damage remove it.
  CONSTRAINT stock_movements_direction CHECK (
    (movement_type IN ('opening_balance', 'receipt', 'customer_return') AND quantity_delta > 0)
    OR (movement_type IN ('dispatch', 'damage') AND quantity_delta < 0)
    OR movement_type IN ('adjustment', 'reversal')
  ),
  CONSTRAINT stock_movements_reason_required CHECK (
    movement_type NOT IN ('damage', 'adjustment', 'reversal')
    OR (reason = btrim(reason) AND length(reason) BETWEEN 3 AND 500)
  ),
  CONSTRAINT stock_movements_receipt_has_batch
    CHECK (movement_type NOT IN ('opening_balance', 'receipt') OR batch_id IS NOT NULL),
  CONSTRAINT stock_movements_reversal_has_target
    CHECK ((movement_type = 'reversal') = (reverses_movement_id IS NOT NULL))
);

CREATE INDEX stock_movements_product_date_idx ON stock_movements (product_id, business_date);
CREATE INDEX stock_movements_business_date_idx ON stock_movements (business_date);
CREATE UNIQUE INDEX stock_movements_reversed_once ON stock_movements (reverses_movement_id);

REVOKE UPDATE, DELETE ON stock_movements FROM snackify_app;

-- Stock on hand per product, always calculated from the ledger.
CREATE VIEW stock_balances AS
SELECT p.id AS product_id, COALESCE(sum(m.quantity_delta), 0)::integer AS quantity_on_hand
FROM products p
LEFT JOIN stock_movements m ON m.product_id = p.id
GROUP BY p.id;

-- Down Migration

DROP VIEW stock_balances;
DROP TABLE stock_movements;
DROP TABLE stock_batches;
ALTER TABLE products DROP COLUMN reorder_level;
