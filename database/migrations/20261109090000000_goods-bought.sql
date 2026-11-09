-- Up Migration

-- Goods bought (owner's request, 2026-11-09): finance or an administrator records what was
-- bought (supplier, products, quantities, prices) and can print it. When the goods arrive the
-- storekeeper receives against the list: a goods-received note is started from it and points
-- back at it, line by line, so the list shows what has arrived. Receiving without a list is still
-- allowed. A list can be changed only until something is received against it, and cancelled
-- (with a reason) only while nothing has been.

CREATE SEQUENCE purchase_number_seq;

CREATE TABLE purchases (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_number         text NOT NULL DEFAULT 'GB' || lpad(nextval('purchase_number_seq')::text, 6, '0'),
  -- Whose stock it is for: the Head Office or a subsidiary.
  owner_organisation_id   uuid NOT NULL REFERENCES organisations (id),
  supplier_id             uuid REFERENCES suppliers (id),
  supplier_invoice_number text,
  purchase_date           date NOT NULL,
  currency                text NOT NULL,
  status                  text NOT NULL DEFAULT 'OPEN',
  notes                   text,
  created_by              uuid NOT NULL REFERENCES users (id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  cancelled_by            uuid REFERENCES users (id),
  cancelled_at            timestamptz,
  cancel_reason           text,

  CONSTRAINT purchases_number_key UNIQUE (purchase_number),
  CONSTRAINT purchases_status_valid CHECK (status IN ('OPEN', 'CANCELLED')),
  CONSTRAINT purchases_currency_format CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT purchases_supplier_invoice_valid CHECK (
    supplier_invoice_number = btrim(supplier_invoice_number)
    AND length(supplier_invoice_number) BETWEEN 1 AND 60
  ),
  CONSTRAINT purchases_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 1000),
  CONSTRAINT purchases_cancel_recorded CHECK (
    (status = 'CANCELLED') = (cancelled_at IS NOT NULL)
    AND (status <> 'CANCELLED'
         OR (cancelled_by IS NOT NULL AND length(btrim(cancel_reason)) BETWEEN 3 AND 500))
  )
);
CREATE INDEX purchases_date_idx ON purchases (purchase_date DESC, created_at DESC);
CREATE TRIGGER purchases_set_updated_at
  BEFORE UPDATE ON purchases
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
REVOKE DELETE ON purchases FROM snackify_app;

CREATE TABLE purchase_lines (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id uuid NOT NULL REFERENCES purchases (id),
  line_number integer NOT NULL,
  product_id  uuid NOT NULL REFERENCES products (id),
  unit_id     uuid NOT NULL REFERENCES units (id),
  quantity    integer NOT NULL,
  unit_cost   numeric(14, 4) NOT NULL,
  -- Worked out by the database, exactly: never in floating point.
  line_total  numeric(14, 2) GENERATED ALWAYS AS (round(quantity * unit_cost, 2)) STORED,
  notes       text,

  CONSTRAINT purchase_lines_number_key UNIQUE (purchase_id, line_number),
  CONSTRAINT purchase_lines_quantity_valid CHECK (quantity > 0),
  CONSTRAINT purchase_lines_unit_cost_valid CHECK (unit_cost >= 0),
  CONSTRAINT purchase_lines_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 500)
);
CREATE INDEX purchase_lines_purchase_idx ON purchase_lines (purchase_id);
-- Lines are replaced while the list is being written, so the API may delete them; the API only
-- does so while nothing has been received against the list.

-- A goods-received note may be received against a list, and each of its lines against a line.
ALTER TABLE stock_receipts ADD COLUMN purchase_id uuid REFERENCES purchases (id);
ALTER TABLE stock_receipt_lines ADD COLUMN purchase_line_id uuid REFERENCES purchase_lines (id);
CREATE INDEX stock_receipts_purchase_idx ON stock_receipts (purchase_id) WHERE purchase_id IS NOT NULL;
CREATE INDEX stock_receipt_lines_purchase_line_idx ON stock_receipt_lines (purchase_line_id)
  WHERE purchase_line_id IS NOT NULL;

-- Who may enter goods bought: finance and administrators. Warehouse staff see the lists so
-- they can receive against them (stock.receive), and so does anyone who verifies receipts.
INSERT INTO permissions (code, description) VALUES
  ('purchase.manage', 'Enter, change and cancel lists of goods bought');
INSERT INTO role_permissions (role_id, permission_code)
SELECT id, 'purchase.manage' FROM roles WHERE code IN ('hq_finance_officer', 'system_admin');

-- Down Migration

DELETE FROM role_permissions WHERE permission_code = 'purchase.manage';
DELETE FROM permissions WHERE code = 'purchase.manage';
DROP INDEX stock_receipt_lines_purchase_line_idx;
DROP INDEX stock_receipts_purchase_idx;
ALTER TABLE stock_receipt_lines DROP COLUMN purchase_line_id;
ALTER TABLE stock_receipts DROP COLUMN purchase_id;
DROP TABLE purchase_lines;
DROP TABLE purchases;
DROP SEQUENCE purchase_number_seq;
