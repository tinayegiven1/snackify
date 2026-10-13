-- Up Migration

-- Invoices get a due date when they are issued (issue date + payment terms), so overdue balances
-- can be shown (spec 6.9). Invoices issued before this migration get the default 7 days; the
-- trigger that freezes issued invoices is paused only for that one-off backfill.
ALTER TABLE invoices ADD COLUMN due_date date;
ALTER TABLE invoices DISABLE TRIGGER invoices_protect_finished;
UPDATE invoices SET due_date = issue_date + 7 WHERE status = 'issued';
ALTER TABLE invoices ENABLE TRIGGER invoices_protect_finished;
ALTER TABLE invoices ADD CONSTRAINT invoices_due_date_recorded
  CHECK (status <> 'issued' OR (due_date IS NOT NULL AND due_date >= issue_date));
CREATE INDEX invoices_customer_due_idx ON invoices (customer_id, due_date) WHERE status = 'issued';

-- Receipt numbers P000001, ... are given when the payment is recorded.
CREATE SEQUENCE payment_number_seq;

-- Money received from a customer (spec 6.9). A payment is never edited or deleted: a mistake
-- is corrected by voiding it (with a reason) and recording it again.
CREATE TABLE payments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_number  text NOT NULL DEFAULT 'P' || lpad(nextval('payment_number_seq')::text, 6, '0'),
  customer_id     uuid NOT NULL REFERENCES customers (id),
  status          text NOT NULL DEFAULT 'recorded',
  -- The business day the money was received.
  payment_date    date NOT NULL,
  amount          numeric(14, 2) NOT NULL,
  currency        text NOT NULL,
  method          text NOT NULL,
  -- Bank reference, mobile money transaction id, cheque number, ...
  reference       text,
  notes           text,
  -- Sent by the app with each new payment, so a repeated request cannot record it twice.
  idempotency_key uuid,
  recorded_by     uuid NOT NULL REFERENCES users (id),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  voided_by       uuid REFERENCES users (id),
  voided_at       timestamptz,
  void_reason     text,

  CONSTRAINT payments_number_key UNIQUE (payment_number),
  CONSTRAINT payments_idempotency_key_key UNIQUE (idempotency_key),
  CONSTRAINT payments_status_valid CHECK (status IN ('recorded', 'voided')),
  CONSTRAINT payments_amount_positive CHECK (amount > 0),
  CONSTRAINT payments_currency_format CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT payments_method_valid
    CHECK (method IN ('cash', 'bank_transfer', 'mobile_money', 'card', 'cheque', 'other')),
  CONSTRAINT payments_reference_valid
    CHECK (reference = btrim(reference) AND length(reference) BETWEEN 1 AND 100),
  CONSTRAINT payments_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 500),
  CONSTRAINT payments_void_recorded CHECK (
    status <> 'voided'
    OR (voided_by IS NOT NULL AND voided_at IS NOT NULL AND length(btrim(void_reason)) >= 3)
  )
);

CREATE INDEX payments_customer_date_idx ON payments (customer_id, payment_date);
CREATE INDEX payments_date_idx ON payments (payment_date);

CREATE TRIGGER payments_set_updated_at
  BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- The only change ever allowed to a payment: recorded -> voided, with nothing else changed.
CREATE FUNCTION protect_payment() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> 'recorded' OR NEW.status <> 'voided'
     OR (NEW.payment_number, NEW.customer_id, NEW.payment_date, NEW.amount, NEW.currency,
         NEW.method, NEW.reference, NEW.notes, NEW.idempotency_key, NEW.recorded_by,
         NEW.created_at)
        IS DISTINCT FROM
        (OLD.payment_number, OLD.customer_id, OLD.payment_date, OLD.amount, OLD.currency,
         OLD.method, OLD.reference, OLD.notes, OLD.idempotency_key, OLD.recorded_by,
         OLD.created_at)
  THEN
    RAISE EXCEPTION 'Payment % cannot be changed; a recorded payment can only be voided',
      OLD.payment_number
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER payments_protect
  BEFORE UPDATE ON payments
  FOR EACH ROW EXECUTE FUNCTION protect_payment();

-- How much of a payment pays which issued invoice (spec 6.9). Append-only: allocations of a
-- voided payment stay as history but no longer count.
CREATE TABLE payment_allocations (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL REFERENCES payments (id),
  invoice_id uuid NOT NULL REFERENCES invoices (id),
  amount     numeric(14, 2) NOT NULL,
  created_by uuid NOT NULL REFERENCES users (id),
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT payment_allocations_amount_positive CHECK (amount > 0)
);

CREATE INDEX payment_allocations_payment_idx ON payment_allocations (payment_id);
CREATE INDEX payment_allocations_invoice_idx ON payment_allocations (invoice_id);

-- Every allocation is checked with the payment and the invoice locked (in that order, as the
-- API does), so allocations made at the same moment are checked one after the other:
-- the payment must not be voided, the invoice must be the same customer's issued invoice in
-- the same currency, a payment cannot be allocated beyond its amount, and an invoice cannot be
-- paid beyond its total.
CREATE FUNCTION check_payment_allocation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  pay payments%ROWTYPE;
  inv invoices%ROWTYPE;
  allocated numeric;
  paid numeric;
BEGIN
  SELECT * INTO pay FROM payments WHERE id = NEW.payment_id FOR UPDATE;
  SELECT * INTO inv FROM invoices WHERE id = NEW.invoice_id FOR UPDATE;
  IF pay.status <> 'recorded' THEN
    RAISE EXCEPTION 'Payment % is voided', pay.payment_number USING ERRCODE = 'check_violation';
  END IF;
  IF inv.status <> 'issued' OR inv.customer_id <> pay.customer_id OR inv.currency <> pay.currency
  THEN
    RAISE EXCEPTION 'Payment % cannot pay invoice %', pay.payment_number,
      COALESCE(inv.invoice_number, inv.id::text)
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(sum(amount), 0) INTO allocated
  FROM payment_allocations WHERE payment_id = NEW.payment_id;
  IF allocated + NEW.amount > pay.amount THEN
    RAISE EXCEPTION 'Allocations of payment % would exceed its amount (%)', pay.payment_number,
      pay.amount
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT COALESCE(sum(a.amount), 0) INTO paid
  FROM payment_allocations a JOIN payments p ON p.id = a.payment_id
  WHERE a.invoice_id = NEW.invoice_id AND p.status = 'recorded';
  IF paid + NEW.amount > inv.total THEN
    RAISE EXCEPTION 'Invoice % would be paid more than its total (%)', inv.invoice_number,
      inv.total
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER payment_allocations_check
  BEFORE INSERT ON payment_allocations
  FOR EACH ROW EXECUTE FUNCTION check_payment_allocation();

-- What has been paid on each invoice: allocations from payments that have not been voided.
CREATE VIEW invoice_amounts_paid AS
SELECT a.invoice_id, sum(a.amount)::numeric(14, 2) AS amount_paid
FROM payment_allocations a
JOIN payments p ON p.id = a.payment_id
WHERE p.status = 'recorded'
GROUP BY a.invoice_id;

-- How much of each payment has been allocated to invoices.
CREATE VIEW payment_amounts_allocated AS
SELECT payment_id, sum(amount)::numeric(14, 2) AS amount_allocated
FROM payment_allocations
GROUP BY payment_id;

REVOKE DELETE ON payments FROM snackify_app;
REVOKE UPDATE, DELETE ON payment_allocations FROM snackify_app;
REVOKE INSERT, UPDATE, DELETE ON invoice_amounts_paid, payment_amounts_allocated FROM snackify_app;

-- Down Migration

DROP VIEW payment_amounts_allocated;
DROP VIEW invoice_amounts_paid;
DROP TRIGGER payment_allocations_check ON payment_allocations;
DROP FUNCTION check_payment_allocation();
DROP TABLE payment_allocations;
DROP TRIGGER payments_protect ON payments;
DROP FUNCTION protect_payment();
DROP TABLE payments;
DROP SEQUENCE payment_number_seq;
DROP INDEX invoices_customer_due_idx;
ALTER TABLE invoices DROP CONSTRAINT invoices_due_date_recorded;
ALTER TABLE invoices DROP COLUMN due_date;
