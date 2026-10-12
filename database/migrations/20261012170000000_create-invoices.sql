-- Up Migration

-- Invoice numbers INV-000001, ... are given when an invoice is issued, so voided drafts never
-- leave gaps in the numbering.
CREATE SEQUENCE invoice_number_seq;

-- Invoices (spec 6.8): draft -> issued, or draft -> voided.
-- An issued invoice is a frozen snapshot: its lines, amounts and the customer details printed
-- on it never change. Corrections will use credit notes (a later stage).
CREATE TABLE invoices (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number   text,
  customer_id      uuid NOT NULL REFERENCES customers (id),
  status           text NOT NULL DEFAULT 'draft',
  period_from      date NOT NULL,
  period_to        date NOT NULL,
  currency         text NOT NULL,
  subtotal         numeric(14, 2) NOT NULL,
  -- No discounts or adjustments yet, so the total always equals the subtotal.
  total            numeric(14, 2) NOT NULL,
  -- Customer details exactly as printed on the issued invoice.
  customer_code    text,
  customer_name    text,
  customer_phone   text,
  customer_address text,
  issue_date       date,
  created_by       uuid NOT NULL REFERENCES users (id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  issued_by        uuid REFERENCES users (id),
  issued_at        timestamptz,
  voided_by        uuid REFERENCES users (id),
  voided_at        timestamptz,
  void_reason      text,

  CONSTRAINT invoices_number_key UNIQUE (invoice_number),
  CONSTRAINT invoices_status_valid CHECK (status IN ('draft', 'issued', 'voided')),
  CONSTRAINT invoices_period_valid CHECK (period_to >= period_from),
  CONSTRAINT invoices_currency_format CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT invoices_subtotal_not_negative CHECK (subtotal >= 0),
  CONSTRAINT invoices_total_matches CHECK (total = subtotal),
  CONSTRAINT invoices_issue_recorded CHECK (
    status <> 'issued' OR (
      invoice_number IS NOT NULL AND issue_date IS NOT NULL AND issued_by IS NOT NULL
      AND issued_at IS NOT NULL AND customer_code IS NOT NULL AND customer_name IS NOT NULL
    )
  ),
  CONSTRAINT invoices_void_recorded CHECK (
    status <> 'voided'
    OR (voided_by IS NOT NULL AND voided_at IS NOT NULL AND length(btrim(void_reason)) >= 3)
  )
);

CREATE INDEX invoices_customer_period_idx ON invoices (customer_id, period_from);
CREATE INDEX invoices_status_idx ON invoices (status, issue_date);

CREATE TRIGGER invoices_set_updated_at
  BEFORE UPDATE ON invoices
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- One line per dispatch line billed, with a snapshot of what was dispatched.
CREATE TABLE invoice_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id       uuid NOT NULL REFERENCES invoices (id),
  dispatch_item_id uuid NOT NULL REFERENCES dispatch_items (id),
  dispatch_number  text NOT NULL,
  dispatch_date    date NOT NULL,
  product_id       uuid NOT NULL REFERENCES products (id),
  sku              text NOT NULL,
  description      text NOT NULL,
  quantity         integer NOT NULL,
  unit_price       numeric(12, 2) NOT NULL,
  line_total       numeric(14, 2) NOT NULL,

  -- A dispatch line can be on at most one invoice: it can never be billed twice (spec 6.8).
  CONSTRAINT invoice_items_dispatch_item_key UNIQUE (dispatch_item_id),
  CONSTRAINT invoice_items_quantity_positive CHECK (quantity > 0),
  CONSTRAINT invoice_items_unit_price_not_negative CHECK (unit_price >= 0),
  CONSTRAINT invoice_items_line_total_matches CHECK (line_total = quantity * unit_price)
);

CREATE INDEX invoice_items_invoice_idx ON invoice_items (invoice_id);

-- Issued and voided invoices never change. Issuing additionally checks that the total equals
-- the sum of the lines (spec 11: invoice totals equal the sum of item lines).
CREATE FUNCTION protect_finished_invoice() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  lines_total numeric;
BEGIN
  IF OLD.status <> 'draft' THEN
    RAISE EXCEPTION 'Invoice % is % and cannot be changed', COALESCE(OLD.invoice_number, OLD.id::text), OLD.status
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status = 'issued' THEN
    SELECT COALESCE(sum(line_total), 0) INTO lines_total FROM invoice_items WHERE invoice_id = NEW.id;
    IF lines_total <> NEW.subtotal OR lines_total = 0 THEN
      RAISE EXCEPTION 'Invoice subtotal % does not match its lines (%)', NEW.subtotal, lines_total
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER invoices_protect_finished
  BEFORE UPDATE ON invoices
  FOR EACH ROW EXECUTE FUNCTION protect_finished_invoice();

CREATE FUNCTION protect_finished_invoice_items() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  parent_status text;
BEGIN
  SELECT status INTO parent_status FROM invoices WHERE id = COALESCE(NEW.invoice_id, OLD.invoice_id);
  IF parent_status <> 'draft' THEN
    RAISE EXCEPTION 'The lines of a % invoice cannot be changed', parent_status
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER invoice_items_protect_finished
  BEFORE INSERT OR UPDATE OR DELETE ON invoice_items
  FOR EACH ROW EXECUTE FUNCTION protect_finished_invoice_items();

-- Invoices are voided, never deleted. A draft's lines are removed when it is voided, which
-- frees those dispatch lines to be invoiced again (the trigger guards issued invoices).
REVOKE DELETE ON invoices FROM snackify_app;

-- Down Migration

DROP TRIGGER invoice_items_protect_finished ON invoice_items;
DROP FUNCTION protect_finished_invoice_items();
DROP TRIGGER invoices_protect_finished ON invoices;
DROP FUNCTION protect_finished_invoice();
DROP TABLE invoice_items;
DROP TABLE invoices;
DROP SEQUENCE invoice_number_seq;
