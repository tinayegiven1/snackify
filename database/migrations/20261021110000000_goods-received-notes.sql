-- Up Migration

-- StockFlow Stage 4.4 and 4.5 (docs/STAGE_3_5_PLAN.md): goods-received notes (GRNs) with lines
-- and supporting documents. A GRN says whose stock arrived (the Head Office or a subsidiary),
-- from which supplier, and what was bought against what physically arrived.
--
-- Statuses: DRAFT -> PENDING_VERIFICATION -> VERIFIED -> POSTED, or -> REJECTED; a POSTED
-- receipt can later be REVERSED. When stock is available before verification (setting
-- RECEIPT_STOCK_AVAILABLE_BEFORE_VERIFICATION, decision D3) it is posted on submission
-- (posted_at is set while still PENDING_VERIFICATION) and verifying moves it straight to POSTED.

CREATE SEQUENCE stock_receipt_number_seq;

CREATE TABLE stock_receipts (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  grn_number              text NOT NULL DEFAULT 'GRN' || lpad(nextval('stock_receipt_number_seq')::text, 6, '0'),
  owner_organisation_id   uuid NOT NULL REFERENCES organisations (id),
  warehouse_id            uuid NOT NULL REFERENCES warehouses (id),
  supplier_id             uuid REFERENCES suppliers (id),
  supplier_invoice_number text,
  purchase_date           date,
  -- The business day the goods arrived (Africa/Harare); created_at is the moment it was typed.
  received_date           date NOT NULL,
  currency                text NOT NULL,
  status                  text NOT NULL DEFAULT 'DRAFT',
  notes                   text,
  received_by             uuid NOT NULL REFERENCES users (id),
  submitted_by            uuid REFERENCES users (id),
  submitted_at            timestamptz,
  -- Set when the stock was added (on submission or on verification, see above).
  posted_by               uuid REFERENCES users (id),
  posted_at               timestamptz,
  verified_by             uuid REFERENCES users (id),
  verified_at             timestamptz,
  verification_notes      text,
  rejected_reason         text,
  reversed_by             uuid REFERENCES users (id),
  reversed_at             timestamptz,
  reversal_reason         text,
  -- Submitted without a supporting document: allowed only with permission and a reason.
  no_document_reason      text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT stock_receipts_grn_number_key UNIQUE (grn_number),
  CONSTRAINT stock_receipts_status_valid CHECK (status IN (
    'DRAFT', 'PENDING_VERIFICATION', 'VERIFIED', 'REJECTED', 'POSTED', 'REVERSED'
  )),
  CONSTRAINT stock_receipts_currency_format CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT stock_receipts_supplier_invoice_valid CHECK (
    supplier_invoice_number = btrim(supplier_invoice_number)
    AND length(supplier_invoice_number) BETWEEN 1 AND 60
  ),
  CONSTRAINT stock_receipts_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 1000),
  CONSTRAINT stock_receipts_purchase_not_after_receipt CHECK (purchase_date <= received_date),
  -- What each status needs.
  CONSTRAINT stock_receipts_submitted CHECK (
    status = 'DRAFT' OR (submitted_at IS NOT NULL AND submitted_by IS NOT NULL AND supplier_id IS NOT NULL)
  ),
  CONSTRAINT stock_receipts_posted CHECK (
    status NOT IN ('POSTED', 'REVERSED') OR posted_at IS NOT NULL
  ),
  CONSTRAINT stock_receipts_verified CHECK (
    status NOT IN ('VERIFIED', 'POSTED', 'REVERSED') OR verified_at IS NOT NULL
  ),
  CONSTRAINT stock_receipts_rejected CHECK (
    (status = 'REJECTED') = (rejected_reason IS NOT NULL)
    AND (rejected_reason IS NULL OR length(btrim(rejected_reason)) BETWEEN 3 AND 500)
  ),
  CONSTRAINT stock_receipts_reversed CHECK (
    (status = 'REVERSED') = (reversal_reason IS NOT NULL)
    AND (reversal_reason IS NULL OR length(btrim(reversal_reason)) BETWEEN 3 AND 500)
  ),
  CONSTRAINT stock_receipts_no_document_reason_valid
    CHECK (no_document_reason IS NULL OR length(btrim(no_document_reason)) BETWEEN 3 AND 500)
);
CREATE INDEX stock_receipts_owner_idx ON stock_receipts (owner_organisation_id, received_date);
CREATE INDEX stock_receipts_status_idx ON stock_receipts (status);
CREATE TRIGGER stock_receipts_set_updated_at
  BEFORE UPDATE ON stock_receipts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
REVOKE DELETE ON stock_receipts FROM snackify_app;

CREATE TABLE stock_receipt_lines (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id         uuid NOT NULL REFERENCES stock_receipts (id),
  line_number        integer NOT NULL,
  product_id         uuid NOT NULL REFERENCES products (id),
  -- Quantities in the unit entered (e.g. cartons); base_quantity_received is in the product's
  -- base unit, converted when the line is saved.
  unit_id            uuid NOT NULL REFERENCES units (id),
  quantity_purchased integer NOT NULL,
  quantity_received  integer NOT NULL,
  base_quantity_received integer NOT NULL,
  unit_cost          numeric(14, 4) NOT NULL,
  -- quantity_purchased x unit_cost, rounded to cents: what the supplier charges.
  line_total         numeric(14, 2) NOT NULL,
  batch_number       text,
  expiry_date        date,
  discrepancy_reason text,
  notes              text,
  -- The delivery batch created when the line is posted.
  batch_id           uuid REFERENCES stock_batches (id),

  CONSTRAINT stock_receipt_lines_number_key UNIQUE (receipt_id, line_number),
  CONSTRAINT stock_receipt_lines_quantities_valid CHECK (
    quantity_purchased >= 0 AND quantity_received >= 0 AND base_quantity_received >= 0
    AND (quantity_purchased > 0 OR quantity_received > 0)
  ),
  CONSTRAINT stock_receipt_lines_unit_cost_valid CHECK (unit_cost >= 0),
  CONSTRAINT stock_receipt_lines_total_matches CHECK (line_total = round(quantity_purchased * unit_cost, 2)),
  CONSTRAINT stock_receipt_lines_batch_number_valid
    CHECK (batch_number = btrim(batch_number) AND length(batch_number) BETWEEN 1 AND 60),
  -- A difference between what was bought and what arrived always has a reason.
  CONSTRAINT stock_receipt_lines_discrepancy CHECK (
    (quantity_purchased = quantity_received) = (discrepancy_reason IS NULL)
    AND (discrepancy_reason IS NULL
         OR discrepancy_reason IN ('shortage', 'overage', 'damaged', 'rejected'))
  ),
  CONSTRAINT stock_receipt_lines_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 500)
);
CREATE INDEX stock_receipt_lines_product_idx ON stock_receipt_lines (product_id);

-- Lines change only while their receipt is a draft (posting records the batch it created).
CREATE FUNCTION protect_submitted_receipt_lines() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  receipt_status text;
BEGIN
  SELECT status INTO receipt_status FROM stock_receipts
  WHERE id = COALESCE(NEW.receipt_id, OLD.receipt_id);
  IF receipt_status = 'DRAFT' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.batch_id IS NULL AND NEW.batch_id IS NOT NULL
     AND (to_jsonb(NEW) - 'batch_id') = (to_jsonb(OLD) - 'batch_id') THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Lines of a submitted receipt cannot be changed'
    USING ERRCODE = 'check_violation', CONSTRAINT = 'stock_receipt_lines_draft_only';
END;
$$;
CREATE TRIGGER stock_receipt_lines_draft_only
  BEFORE INSERT OR UPDATE OR DELETE ON stock_receipt_lines
  FOR EACH ROW EXECUTE FUNCTION protect_submitted_receipt_lines();

-- Only these status changes are possible, and a finished receipt's details never change.
CREATE FUNCTION protect_receipt() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> NEW.status AND NOT (
    (OLD.status = 'DRAFT' AND NEW.status = 'PENDING_VERIFICATION')
    OR (OLD.status = 'PENDING_VERIFICATION' AND NEW.status IN ('VERIFIED', 'POSTED', 'REJECTED'))
    OR (OLD.status = 'VERIFIED' AND NEW.status = 'POSTED')
    OR (OLD.status = 'POSTED' AND NEW.status = 'REVERSED')
  ) THEN
    RAISE EXCEPTION 'A receipt cannot go from % to %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation', CONSTRAINT = 'stock_receipts_transition';
  END IF;
  IF OLD.status <> 'DRAFT' AND (
    NEW.owner_organisation_id, NEW.warehouse_id, NEW.supplier_id, NEW.supplier_invoice_number,
    NEW.purchase_date, NEW.received_date, NEW.currency, NEW.notes, NEW.received_by,
    NEW.no_document_reason
  ) IS DISTINCT FROM (
    OLD.owner_organisation_id, OLD.warehouse_id, OLD.supplier_id, OLD.supplier_invoice_number,
    OLD.purchase_date, OLD.received_date, OLD.currency, OLD.notes, OLD.received_by,
    OLD.no_document_reason
  ) THEN
    RAISE EXCEPTION 'A submitted receipt cannot be changed'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'stock_receipts_submitted_unchanged';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER stock_receipts_protect
  BEFORE UPDATE ON stock_receipts FOR EACH ROW EXECUTE FUNCTION protect_receipt();

-- Supporting documents (supplier invoices, delivery notes, photos). The file itself is stored
-- outside the web app under a generated name (storage_key); only an authorised download route
-- serves it. Documents are never deleted: a rejected one stays, and a replacement is added.
CREATE TABLE stock_receipt_attachments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id          uuid NOT NULL REFERENCES stock_receipts (id),
  original_filename   text NOT NULL,
  storage_key         text NOT NULL,
  mime_type           text NOT NULL,
  size_bytes          integer NOT NULL,
  sha256              text NOT NULL,
  uploaded_by         uuid NOT NULL REFERENCES users (id),
  uploaded_at         timestamptz NOT NULL DEFAULT now(),
  verification_status text NOT NULL DEFAULT 'PENDING',
  reviewed_by         uuid REFERENCES users (id),
  reviewed_at         timestamptz,
  review_notes        text,
  -- The total printed on the document, when the reviewer enters it, to compare with the GRN.
  document_total      numeric(14, 2),

  CONSTRAINT stock_receipt_attachments_storage_key_key UNIQUE (storage_key),
  CONSTRAINT stock_receipt_attachments_storage_key_format CHECK (storage_key ~ '^[a-f0-9]{64}$'),
  CONSTRAINT stock_receipt_attachments_filename_valid
    CHECK (length(original_filename) BETWEEN 1 AND 200),
  CONSTRAINT stock_receipt_attachments_mime_valid
    CHECK (mime_type IN ('application/pdf', 'image/jpeg', 'image/png')),
  CONSTRAINT stock_receipt_attachments_size_valid CHECK (size_bytes > 0),
  CONSTRAINT stock_receipt_attachments_sha256_format CHECK (sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT stock_receipt_attachments_status_valid
    CHECK (verification_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
  CONSTRAINT stock_receipt_attachments_reviewed CHECK (
    (verification_status = 'PENDING') = (reviewed_at IS NULL)
    AND (verification_status <> 'REJECTED' OR length(btrim(review_notes)) BETWEEN 3 AND 500)
  ),
  CONSTRAINT stock_receipt_attachments_document_total_valid CHECK (document_total >= 0)
);
CREATE INDEX stock_receipt_attachments_receipt_idx ON stock_receipt_attachments (receipt_id);
REVOKE DELETE ON stock_receipt_attachments FROM snackify_app;

-- Batches and ledger entries point at the receipt they came from.
ALTER TABLE stock_batches ADD COLUMN receipt_line_id uuid REFERENCES stock_receipt_lines (id);
CREATE UNIQUE INDEX stock_batches_receipt_line_key ON stock_batches (receipt_line_id);

-- ------------------------------------------------------------------ Permissions

INSERT INTO permissions (code, description) VALUES
  ('receipt.verify', 'Check goods-received notes and their documents; verify or reject them'),
  ('receipt.no_document', 'Submit a goods-received note without a document, with a reason'),
  ('receipt.reverse', 'Reverse a posted goods-received note, with a reason');

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, grants.permission_code
FROM (VALUES
  ('hq_finance_officer', 'receipt.verify'),
  ('system_admin', 'receipt.no_document'),
  ('system_admin', 'receipt.reverse')
) AS grants (role_code, permission_code)
JOIN roles r ON r.code = grants.role_code;

-- Down Migration

DELETE FROM role_permissions
WHERE permission_code IN ('receipt.verify', 'receipt.no_document', 'receipt.reverse');
DELETE FROM permissions WHERE code IN ('receipt.verify', 'receipt.no_document', 'receipt.reverse');
DROP INDEX stock_batches_receipt_line_key;
ALTER TABLE stock_batches DROP COLUMN receipt_line_id;
DROP TABLE stock_receipt_attachments;
DROP TRIGGER stock_receipts_protect ON stock_receipts;
DROP FUNCTION protect_receipt();
DROP TRIGGER stock_receipt_lines_draft_only ON stock_receipt_lines;
DROP FUNCTION protect_submitted_receipt_lines();
DROP TABLE stock_receipt_lines;
DROP TABLE stock_receipts;
DROP SEQUENCE stock_receipt_number_seq;
