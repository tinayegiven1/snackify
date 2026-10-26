-- Up Migration

-- StockFlow Stage 5 (docs/STAGE_3_5_PLAN.md): orders from subsidiaries to the Head Office, with
-- the prices the subsidiary expects and the most it will pay, and the actual price the Head
-- Office sets. An actual price above the maximum is a price exception: approving it needs the
-- price.exception.approve permission and a comment.
--
-- Statuses: DRAFT -> SUBMITTED -> UNDER_REVIEW -> APPROVED or REJECTED; DRAFT or SUBMITTED ->
-- CANCELLED. PARTIALLY_DISPATCHED, FULLY_DISPATCHED and COMPLETED are reserved for Stage 6.
--
-- Money is numeric (exact). Line totals and the price-exception flag are generated columns, so
-- the database itself works them out; nothing the app sends can change them.

CREATE SEQUENCE order_number_seq;

CREATE TABLE orders (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_number             text NOT NULL DEFAULT 'ORD' || lpad(nextval('order_number_seq')::text, 6, '0'),
  -- The subsidiary that orders. The API takes it from the signed-in user, never the request.
  organisation_id          uuid NOT NULL REFERENCES organisations (id),
  order_date               date NOT NULL,
  required_date            date,
  requested_by             uuid NOT NULL REFERENCES users (id),
  currency                 text NOT NULL,
  notes                    text,
  status                   text NOT NULL DEFAULT 'DRAFT',
  -- Sent by the app with a new order: the same key again returns the same order, so a retry or
  -- a double click never creates a second one.
  idempotency_key          uuid NOT NULL,
  -- Hooks for tax and discounts (none for now; see the plan).
  tax_amount               numeric(14, 2) NOT NULL DEFAULT 0,
  discount_amount          numeric(14, 2) NOT NULL DEFAULT 0,
  submitted_by             uuid REFERENCES users (id),
  submitted_at             timestamptz,
  decided_by               uuid REFERENCES users (id),
  decided_at               timestamptz,
  decision_comment         text,
  price_exception_approved boolean NOT NULL DEFAULT false,
  cancelled_by             uuid REFERENCES users (id),
  cancelled_at             timestamptz,
  cancel_reason            text,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT orders_number_key UNIQUE (order_number),
  CONSTRAINT orders_idempotency_key UNIQUE (requested_by, idempotency_key),
  CONSTRAINT orders_status_valid CHECK (status IN (
    'DRAFT', 'SUBMITTED', 'UNDER_REVIEW', 'APPROVED', 'REJECTED', 'CANCELLED',
    'PARTIALLY_DISPATCHED', 'FULLY_DISPATCHED', 'COMPLETED')),
  CONSTRAINT orders_currency_format CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT orders_required_date_valid CHECK (required_date >= order_date),
  CONSTRAINT orders_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 1000),
  CONSTRAINT orders_tax_discount_valid CHECK (tax_amount >= 0 AND discount_amount >= 0),
  CONSTRAINT orders_submitted CHECK (status IN ('DRAFT', 'CANCELLED') OR submitted_at IS NOT NULL),
  CONSTRAINT orders_decided CHECK (
    (status IN ('APPROVED', 'REJECTED', 'PARTIALLY_DISPATCHED', 'FULLY_DISPATCHED', 'COMPLETED'))
    = (decided_at IS NOT NULL)
  ),
  -- A rejection always says why.
  CONSTRAINT orders_rejection_comment CHECK (
    status <> 'REJECTED' OR length(btrim(decision_comment)) BETWEEN 3 AND 1000
  ),
  CONSTRAINT orders_decision_comment_valid CHECK (length(decision_comment) <= 1000),
  CONSTRAINT orders_cancelled CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL)),
  CONSTRAINT orders_cancel_reason_valid
    CHECK (cancel_reason IS NULL OR length(btrim(cancel_reason)) BETWEEN 3 AND 500)
);

CREATE INDEX orders_organisation_idx ON orders (organisation_id, created_at DESC);
CREATE INDEX orders_status_idx ON orders (status);

-- Only subsidiaries order (from the Head Office).
CREATE FUNCTION orders_subsidiary_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM organisations
                 WHERE id = NEW.organisation_id AND organisation_type = 'SUBSIDIARY') THEN
    RAISE EXCEPTION 'Only a subsidiary can place an order'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'orders_subsidiary_only';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER orders_subsidiary_only BEFORE INSERT OR UPDATE OF organisation_id ON orders
  FOR EACH ROW EXECUTE FUNCTION orders_subsidiary_only();

-- New tables give the API role every data right by default (database/setup); take back what
-- it must never do. Orders are never deleted.
REVOKE DELETE ON orders FROM snackify_app;

CREATE TABLE order_items (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id            uuid NOT NULL REFERENCES orders (id),
  line_number         integer NOT NULL,
  product_id          uuid NOT NULL REFERENCES products (id),
  -- The quantity in the unit chosen (e.g. cartons); prices are per that unit.
  unit_id             uuid NOT NULL REFERENCES units (id),
  requested_quantity  integer NOT NULL,
  -- requested_quantity in the product's base unit (packs), for dispatching (Stage 6).
  base_quantity       integer NOT NULL,
  expected_unit_price numeric(12, 2) NOT NULL,
  maximum_unit_price  numeric(12, 2) NOT NULL,
  -- Set by the Head Office during review.
  actual_unit_price   numeric(12, 2),
  notes               text,
  expected_line_total numeric(14, 2)
    GENERATED ALWAYS AS (requested_quantity * expected_unit_price) STORED,
  maximum_line_total  numeric(14, 2)
    GENERATED ALWAYS AS (requested_quantity * maximum_unit_price) STORED,
  actual_line_total   numeric(14, 2)
    GENERATED ALWAYS AS (requested_quantity * actual_unit_price) STORED,
  price_exception     boolean
    GENERATED ALWAYS AS (COALESCE(actual_unit_price > maximum_unit_price, false)) STORED,

  CONSTRAINT order_items_line_key UNIQUE (order_id, line_number),
  CONSTRAINT order_items_product_key UNIQUE (order_id, product_id, unit_id),
  CONSTRAINT order_items_quantity_valid
    CHECK (requested_quantity >= 1 AND requested_quantity <= 1000000
           AND base_quantity >= requested_quantity),
  CONSTRAINT order_items_prices_valid CHECK (
    expected_unit_price >= 0 AND maximum_unit_price >= expected_unit_price
    AND (actual_unit_price IS NULL OR actual_unit_price >= 0)
  ),
  CONSTRAINT order_items_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 500)
);

CREATE INDEX order_items_product_idx ON order_items (product_id);

-- Draft lines are replaced when a draft is saved (the trigger below refuses it later).

-- Who changed what, and when: every status change, with its comment.
CREATE TABLE order_status_history (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    uuid NOT NULL REFERENCES orders (id),
  from_status text,
  to_status   text NOT NULL,
  changed_by  uuid NOT NULL REFERENCES users (id),
  changed_at  timestamptz NOT NULL DEFAULT clock_timestamp(),
  comment     text,

  CONSTRAINT order_status_history_comment_valid CHECK (length(comment) <= 1000)
);

CREATE INDEX order_status_history_order_idx ON order_status_history (order_id, changed_at);

-- History is only ever added to.
REVOKE UPDATE, DELETE ON order_status_history FROM snackify_app;

-- Every change to a line after submission (today: the actual price), with the old and new value.
CREATE TABLE order_item_changes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      uuid NOT NULL REFERENCES orders (id),
  order_item_id uuid NOT NULL REFERENCES order_items (id),
  field         text NOT NULL,
  old_value     text,
  new_value     text,
  changed_by    uuid NOT NULL REFERENCES users (id),
  changed_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
  comment       text,

  CONSTRAINT order_item_changes_field_valid CHECK (field IN ('actual_unit_price')),
  CONSTRAINT order_item_changes_comment_valid CHECK (length(comment) <= 500)
);

CREATE INDEX order_item_changes_order_idx ON order_item_changes (order_id, changed_at);

REVOKE UPDATE, DELETE ON order_item_changes FROM snackify_app;

-- Only the allowed status changes, and the subsidiary's submitted values never change.
CREATE FUNCTION protect_order() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status <> NEW.status AND NOT (
    (OLD.status = 'DRAFT' AND NEW.status IN ('SUBMITTED', 'CANCELLED'))
    OR (OLD.status = 'SUBMITTED' AND NEW.status IN ('UNDER_REVIEW', 'REJECTED', 'CANCELLED'))
    OR (OLD.status = 'UNDER_REVIEW' AND NEW.status IN ('APPROVED', 'REJECTED'))
  ) THEN
    RAISE EXCEPTION 'An order cannot go from % to %', OLD.status, NEW.status
      USING ERRCODE = 'check_violation', CONSTRAINT = 'orders_transition';
  END IF;
  IF OLD.status <> 'DRAFT' AND (
    NEW.organisation_id, NEW.order_date, NEW.required_date, NEW.requested_by, NEW.currency,
    NEW.notes, NEW.idempotency_key
  ) IS DISTINCT FROM (
    OLD.organisation_id, OLD.order_date, OLD.required_date, OLD.requested_by, OLD.currency,
    OLD.notes, OLD.idempotency_key
  ) THEN
    RAISE EXCEPTION 'A submitted order cannot be changed'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'orders_submitted_unchanged';
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER orders_protect BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION protect_order();

-- Lines change freely only in a draft. Afterwards only the actual price may be set, and only
-- while the Head Office reviews the order.
CREATE FUNCTION protect_order_items() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  order_status text;
BEGIN
  SELECT status INTO order_status FROM orders
  WHERE id = COALESCE(NEW.order_id, OLD.order_id);
  IF order_status = 'DRAFT' THEN
    IF TG_OP = 'UPDATE' AND NEW.actual_unit_price IS DISTINCT FROM OLD.actual_unit_price THEN
      RAISE EXCEPTION 'The actual price is set when the order is reviewed'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'order_items_submitted_unchanged';
    END IF;
    IF TG_OP = 'INSERT' AND NEW.actual_unit_price IS NOT NULL THEN
      RAISE EXCEPTION 'The actual price is set when the order is reviewed'
        USING ERRCODE = 'check_violation', CONSTRAINT = 'order_items_submitted_unchanged';
    END IF;
    RETURN COALESCE(NEW, OLD);
  END IF;
  IF TG_OP = 'UPDATE' AND order_status IN ('SUBMITTED', 'UNDER_REVIEW') AND (
    NEW.order_id, NEW.line_number, NEW.product_id, NEW.unit_id, NEW.requested_quantity,
    NEW.base_quantity, NEW.expected_unit_price, NEW.maximum_unit_price, NEW.notes
  ) IS NOT DISTINCT FROM (
    OLD.order_id, OLD.line_number, OLD.product_id, OLD.unit_id, OLD.requested_quantity,
    OLD.base_quantity, OLD.expected_unit_price, OLD.maximum_unit_price, OLD.notes
  ) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'The lines of a submitted order cannot be changed'
    USING ERRCODE = 'check_violation', CONSTRAINT = 'order_items_submitted_unchanged';
END;
$$;

CREATE TRIGGER order_items_protect BEFORE INSERT OR UPDATE OR DELETE ON order_items
  FOR EACH ROW EXECUTE FUNCTION protect_order_items();

-- ------------------------------------------------------------------ Permissions

INSERT INTO permissions (code, description) VALUES
  ('order.view', 'See orders (a subsidiary: its own; the Head Office: all)'),
  ('order.create', 'Create, change, submit and cancel the own organisation''s orders'),
  ('order.price', 'Review submitted orders and set their actual selling prices'),
  ('order.approve', 'Approve or reject reviewed orders, with a comment'),
  ('price.exception.approve', 'Approve an order whose actual price is above the maximum');

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, grants.permission_code
FROM (VALUES
  ('subsidiary_manager', 'order.view'),
  ('subsidiary_manager', 'order.create'),
  ('hq_finance_officer', 'order.view'),
  ('hq_finance_officer', 'order.price'),
  ('hq_finance_officer', 'order.approve'),
  ('hq_finance_officer', 'price.exception.approve'),
  ('hq_sales_officer', 'order.view'),
  ('system_admin', 'order.view')
) AS grants (role_code, permission_code)
JOIN roles r ON r.code = grants.role_code;

UPDATE roles SET description = 'Sees the own organisation''s stock; places and follows orders.'
WHERE code = 'subsidiary_manager';

-- Down Migration

UPDATE roles SET description = 'Sees the own organisation''s stock; places orders (from Stage 5).'
WHERE code = 'subsidiary_manager';
DELETE FROM role_permissions
WHERE permission_code IN ('order.view', 'order.create', 'order.price', 'order.approve',
                          'price.exception.approve');
DELETE FROM permissions
WHERE code IN ('order.view', 'order.create', 'order.price', 'order.approve',
               'price.exception.approve');
DROP TRIGGER order_items_protect ON order_items;
DROP FUNCTION protect_order_items();
DROP TRIGGER orders_protect ON orders;
DROP FUNCTION protect_order();
DROP TABLE order_item_changes;
DROP TABLE order_status_history;
DROP TABLE order_items;
DROP TRIGGER orders_subsidiary_only ON orders;
DROP FUNCTION orders_subsidiary_only();
DROP TABLE orders;
DROP SEQUENCE order_number_seq;
