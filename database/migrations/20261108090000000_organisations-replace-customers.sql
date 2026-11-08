-- Up Migration

-- Organisations are the customers (owner's decision, 2026-11-08). Until now every subsidiary had
-- a hidden customer record behind it (decision D1); dispatches, invoices and payments pointed at
-- those records. From here on they point at the organisation itself and the customers table is
-- gone:
--   * a customer not linked to any organisation (an old shop) becomes a subsidiary organisation
--     with the same name, a code as close to its own as the organisation rules allow, and its
--     phone, address, credit limit and active flag, so its history and balance carry over;
--   * the credit limit moves onto the organisation; a linked customer's phone and address fill
--     the organisation's contact phone and address where those are empty;
--   * issued invoices keep the buyer details printed on them (customer_code, customer_name,
--     customer_phone, customer_address), which are a frozen snapshot;
--   * the customer.* permissions go: organisations are managed with organisation.manage, and the
--     credit limit with the new organisation.edit_credit_limit (whoever could change customer
--     credit limits).
-- Old audit entries about customers are kept as they are.

ALTER TABLE organisations ADD COLUMN credit_limit numeric(12, 2);
ALTER TABLE organisations
  ADD CONSTRAINT organisations_credit_limit_not_negative CHECK (credit_limit >= 0);
COMMENT ON COLUMN organisations.credit_limit IS
  'Most the organisation may owe the Head Office at once, in the base currency. NULL = no limit.';

-- Old shops become subsidiaries. Organisation codes are 2-20 characters of A-Z, 0-9, "-" or "_"
-- (customer codes also allowed "." and a single character); a taken code gets "-2", "-3", ...
DO $$
DECLARE
  shop record;
  base text;
  candidate text;
  n integer;
  new_id uuid;
BEGIN
  FOR shop IN
    SELECT * FROM customers WHERE organisation_id IS NULL ORDER BY created_at, code
  LOOP
    base := upper(regexp_replace(shop.code, '[^A-Za-z0-9_-]', '-', 'g'));
    IF base !~ '^[A-Z0-9]' THEN
      base := 'C' || base;
    END IF;
    IF length(base) < 2 THEN
      base := base || '-1';
    END IF;
    base := left(base, 20);
    candidate := base;
    n := 1;
    WHILE EXISTS (SELECT 1 FROM organisations WHERE code = candidate) LOOP
      n := n + 1;
      candidate := left(base, 20 - length(n::text) - 1) || '-' || n;
    END LOOP;

    INSERT INTO organisations (code, name, organisation_type, is_active, contact_phone, address,
                               credit_limit, created_at)
    VALUES (candidate, shop.name, 'SUBSIDIARY', shop.is_active, shop.phone, shop.address,
            shop.credit_limit, shop.created_at)
    RETURNING id INTO new_id;
    UPDATE customers SET organisation_id = new_id WHERE id = shop.id;
  END LOOP;
END;
$$;

-- Linked customers: their credit limit, and their phone and address where the organisation has
-- none.
UPDATE organisations o
SET credit_limit = c.credit_limit,
    contact_phone = COALESCE(o.contact_phone, c.phone),
    address = COALESCE(o.address, c.address)
FROM customers c
WHERE c.organisation_id = o.id;

-- Dispatches, invoices and payments point at the organisation. Their protection triggers are
-- paused while the column is swapped (finished records may not otherwise change), and the
-- functions that named customer_id are rewritten before they are switched back on.
ALTER TABLE dispatches DISABLE TRIGGER USER;
ALTER TABLE invoices DISABLE TRIGGER USER;
ALTER TABLE payments DISABLE TRIGGER USER;

ALTER TABLE dispatches ADD COLUMN organisation_id uuid REFERENCES organisations (id);
UPDATE dispatches d SET organisation_id = c.organisation_id
FROM customers c WHERE c.id = d.customer_id;
ALTER TABLE dispatches ALTER COLUMN organisation_id SET NOT NULL;
ALTER TABLE dispatches DROP COLUMN customer_id;
CREATE INDEX dispatches_organisation_date_idx ON dispatches (organisation_id, dispatch_date);

ALTER TABLE invoices ADD COLUMN organisation_id uuid REFERENCES organisations (id);
UPDATE invoices i SET organisation_id = c.organisation_id
FROM customers c WHERE c.id = i.customer_id;
ALTER TABLE invoices ALTER COLUMN organisation_id SET NOT NULL;
ALTER TABLE invoices DROP COLUMN customer_id;
CREATE INDEX invoices_organisation_period_idx ON invoices (organisation_id, period_from);
CREATE INDEX invoices_organisation_due_idx ON invoices (organisation_id, due_date)
  WHERE status = 'issued';

ALTER TABLE payments ADD COLUMN organisation_id uuid REFERENCES organisations (id);
UPDATE payments p SET organisation_id = c.organisation_id
FROM customers c WHERE c.id = p.customer_id;
ALTER TABLE payments ALTER COLUMN organisation_id SET NOT NULL;
ALTER TABLE payments DROP COLUMN customer_id;
CREATE INDEX payments_organisation_date_idx ON payments (organisation_id, payment_date);

CREATE OR REPLACE FUNCTION protect_finished_dispatch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;
  IF OLD.status = 'confirmed' AND NEW.status = 'reversed'
     AND (NEW.organisation_id, NEW.dispatch_date, NEW.notes, NEW.confirmed_by, NEW.confirmed_at)
         IS NOT DISTINCT FROM
         (OLD.organisation_id, OLD.dispatch_date, OLD.notes, OLD.confirmed_by, OLD.confirmed_at)
  THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Dispatch % is % and cannot be changed', OLD.dispatch_number, OLD.status
    USING ERRCODE = 'check_violation';
END;
$$;

CREATE OR REPLACE FUNCTION protect_payment() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> 'recorded' OR NEW.status <> 'voided'
     OR (NEW.payment_number, NEW.organisation_id, NEW.payment_date, NEW.amount, NEW.currency,
         NEW.method, NEW.reference, NEW.notes, NEW.idempotency_key, NEW.recorded_by,
         NEW.created_at)
        IS DISTINCT FROM
        (OLD.payment_number, OLD.organisation_id, OLD.payment_date, OLD.amount, OLD.currency,
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

DO $$
DECLARE
  definition text := pg_get_functiondef('check_payment_allocation()'::regprocedure);
BEGIN
  IF position('inv.customer_id <> pay.customer_id' IN definition) = 0 THEN
    RAISE EXCEPTION 'check_payment_allocation() is not the expected version';
  END IF;
  EXECUTE replace(definition, 'inv.customer_id <> pay.customer_id',
                  'inv.organisation_id <> pay.organisation_id');
END;
$$;

ALTER TABLE dispatches ENABLE TRIGGER USER;
ALTER TABLE invoices ENABLE TRIGGER USER;
ALTER TABLE payments ENABLE TRIGGER USER;

-- Permissions: the credit limit keeps its holders under a new name; the rest of customer.* goes.
INSERT INTO permissions (code, description) VALUES
  ('organisation.edit_credit_limit', 'Change organisations'' credit limits');
UPDATE role_permissions SET permission_code = 'organisation.edit_credit_limit'
WHERE permission_code = 'customer.edit_credit_limit';
DELETE FROM role_permissions WHERE permission_code LIKE 'customer.%';
DELETE FROM permissions WHERE code LIKE 'customer.%';

DROP TABLE customers;
DROP SEQUENCE customer_code_seq;

-- Down Migration

-- Puts back one customer record per subsidiary (the old shops stay organisations), points the
-- money tables at those records again and restores the customer.* permissions.

CREATE SEQUENCE customer_code_seq;
CREATE TABLE customers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code         text NOT NULL,
  name         text NOT NULL,
  phone        text,
  address      text,
  credit_limit numeric(12, 2),
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  organisation_id uuid REFERENCES organisations (id),

  CONSTRAINT customers_code_key UNIQUE (code),
  CONSTRAINT customers_code_format CHECK (code ~ '^[A-Z0-9][A-Z0-9._-]{0,19}$'),
  CONSTRAINT customers_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 120),
  CONSTRAINT customers_phone_format CHECK (phone ~ '^\+?[0-9][0-9 ()-]{5,22}$'),
  CONSTRAINT customers_address_valid
    CHECK (address = btrim(address) AND length(address) BETWEEN 1 AND 300),
  CONSTRAINT customers_credit_limit_not_negative CHECK (credit_limit >= 0),
  CONSTRAINT customers_organisation_key UNIQUE (organisation_id)
);
CREATE INDEX customers_name_idx ON customers (lower(name));
CREATE TRIGGER customers_set_updated_at
  BEFORE UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
REVOKE DELETE ON customers FROM snackify_app;

INSERT INTO customers (code, name, phone, address, credit_limit, is_active, organisation_id)
SELECT o.code, o.name, o.contact_phone, o.address, o.credit_limit, o.is_active, o.id
FROM organisations o WHERE o.organisation_type = 'SUBSIDIARY';

ALTER TABLE dispatches DISABLE TRIGGER USER;
ALTER TABLE invoices DISABLE TRIGGER USER;
ALTER TABLE payments DISABLE TRIGGER USER;

ALTER TABLE dispatches ADD COLUMN customer_id uuid REFERENCES customers (id);
UPDATE dispatches d SET customer_id = c.id FROM customers c WHERE c.organisation_id = d.organisation_id;
ALTER TABLE dispatches ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE dispatches DROP COLUMN organisation_id;
CREATE INDEX dispatches_customer_date_idx ON dispatches (customer_id, dispatch_date);

ALTER TABLE invoices ADD COLUMN customer_id uuid REFERENCES customers (id);
UPDATE invoices i SET customer_id = c.id FROM customers c WHERE c.organisation_id = i.organisation_id;
ALTER TABLE invoices ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE invoices DROP COLUMN organisation_id;
CREATE INDEX invoices_customer_period_idx ON invoices (customer_id, period_from);
CREATE INDEX invoices_customer_due_idx ON invoices (customer_id, due_date) WHERE status = 'issued';

ALTER TABLE payments ADD COLUMN customer_id uuid REFERENCES customers (id);
UPDATE payments p SET customer_id = c.id FROM customers c WHERE c.organisation_id = p.organisation_id;
ALTER TABLE payments ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments DROP COLUMN organisation_id;
CREATE INDEX payments_customer_date_idx ON payments (customer_id, payment_date);

CREATE OR REPLACE FUNCTION protect_finished_dispatch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status = 'draft' THEN
    RETURN NEW;
  END IF;
  IF OLD.status = 'confirmed' AND NEW.status = 'reversed'
     AND (NEW.customer_id, NEW.dispatch_date, NEW.notes, NEW.confirmed_by, NEW.confirmed_at)
         IS NOT DISTINCT FROM
         (OLD.customer_id, OLD.dispatch_date, OLD.notes, OLD.confirmed_by, OLD.confirmed_at) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Dispatch % is % and cannot be changed', OLD.dispatch_number, OLD.status
    USING ERRCODE = 'check_violation';
END;
$$;

CREATE OR REPLACE FUNCTION protect_payment() RETURNS trigger
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

DO $$
BEGIN
  EXECUTE replace(pg_get_functiondef('check_payment_allocation()'::regprocedure),
                  'inv.organisation_id <> pay.organisation_id',
                  'inv.customer_id <> pay.customer_id');
END;
$$;

ALTER TABLE dispatches ENABLE TRIGGER USER;
ALTER TABLE invoices ENABLE TRIGGER USER;
ALTER TABLE payments ENABLE TRIGGER USER;

INSERT INTO permissions (code, description) VALUES
  ('customer.view', 'See customers'),
  ('customer.edit_details', 'Change customer names, codes, phones and addresses'),
  ('customer.edit_credit_limit', 'Change customer credit limits'),
  ('customer.change_active', 'Deactivate and reactivate customers');
UPDATE role_permissions SET permission_code = 'customer.edit_credit_limit'
WHERE permission_code = 'organisation.edit_credit_limit';
DELETE FROM permissions WHERE code = 'organisation.edit_credit_limit';
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.permission_code
FROM (VALUES
  ('system_admin', 'customer.view'),
  ('system_admin', 'customer.edit_details'),
  ('system_admin', 'customer.change_active'),
  ('hq_warehouse_officer', 'customer.view'),
  ('hq_finance_officer', 'customer.view'),
  ('hq_sales_officer', 'customer.view'),
  ('hq_sales_officer', 'customer.edit_details')
) AS p (role_code, permission_code)
JOIN roles r ON r.code = p.role_code;

ALTER TABLE organisations DROP CONSTRAINT organisations_credit_limit_not_negative;
ALTER TABLE organisations DROP COLUMN credit_limit;
