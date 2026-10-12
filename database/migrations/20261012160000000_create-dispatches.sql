-- Up Migration

-- Dispatch numbers D000001, D000002, ... Every dispatch keeps its number, including
-- cancelled ones, so the sequence has no unexplained gaps.
CREATE SEQUENCE dispatch_number_seq;

-- Dispatches (spec 6.6): goods sent to a customer.
-- draft -> confirmed (stock deducted) -> reversed (stock put back), or draft -> cancelled.
CREATE TABLE dispatches (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_number  text NOT NULL DEFAULT ('D' || lpad(nextval('dispatch_number_seq')::text, 6, '0')),
  customer_id      uuid NOT NULL REFERENCES customers (id),
  status           text NOT NULL DEFAULT 'draft',
  -- The business day the goods leave (Africa/Harare).
  dispatch_date    date NOT NULL,
  notes            text,
  created_by       uuid NOT NULL REFERENCES users (id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  confirmed_by     uuid REFERENCES users (id),
  confirmed_at     timestamptz,
  -- True when someone confirmed it although it took the customer over their credit limit.
  confirmed_over_credit_limit boolean NOT NULL DEFAULT false,
  cancelled_by     uuid REFERENCES users (id),
  cancelled_at     timestamptz,
  cancel_reason    text,
  reversed_by      uuid REFERENCES users (id),
  reversed_at      timestamptz,
  reversal_reason  text,

  CONSTRAINT dispatches_number_key UNIQUE (dispatch_number),
  CONSTRAINT dispatches_status_valid CHECK (status IN ('draft', 'confirmed', 'cancelled', 'reversed')),
  CONSTRAINT dispatches_notes_valid CHECK (notes = btrim(notes) AND length(notes) BETWEEN 1 AND 500),
  -- Each status must record who did it and when.
  CONSTRAINT dispatches_confirmation_recorded CHECK (
    status NOT IN ('confirmed', 'reversed') OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL)
  ),
  CONSTRAINT dispatches_cancellation_recorded CHECK (
    status <> 'cancelled'
    OR (cancelled_by IS NOT NULL AND cancelled_at IS NOT NULL AND length(btrim(cancel_reason)) >= 3)
  ),
  CONSTRAINT dispatches_reversal_recorded CHECK (
    status <> 'reversed'
    OR (reversed_by IS NOT NULL AND reversed_at IS NOT NULL AND length(btrim(reversal_reason)) >= 3)
  )
);

CREATE INDEX dispatches_customer_date_idx ON dispatches (customer_id, dispatch_date);
CREATE INDEX dispatches_status_date_idx ON dispatches (status, dispatch_date);

CREATE TRIGGER dispatches_set_updated_at
  BEFORE UPDATE ON dispatches
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- One line per product: quantity and the price agreed for this dispatch (a snapshot, so later
-- changes to the product's default price never rewrite history).
CREATE TABLE dispatch_items (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispatch_id uuid NOT NULL REFERENCES dispatches (id),
  product_id  uuid NOT NULL REFERENCES products (id),
  quantity    integer NOT NULL,
  unit_price  numeric(12, 2) NOT NULL,

  CONSTRAINT dispatch_items_one_line_per_product UNIQUE (dispatch_id, product_id),
  CONSTRAINT dispatch_items_quantity_positive CHECK (quantity > 0),
  CONSTRAINT dispatch_items_unit_price_not_negative CHECK (unit_price >= 0)
);

CREATE INDEX dispatch_items_product_idx ON dispatch_items (product_id);

-- Links each dispatch movement in the stock ledger to its dispatch line.
ALTER TABLE stock_movements ADD COLUMN dispatch_item_id uuid REFERENCES dispatch_items (id);
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_dispatch_has_item
  CHECK (movement_type <> 'dispatch' OR dispatch_item_id IS NOT NULL);
CREATE INDEX stock_movements_dispatch_item_idx ON stock_movements (dispatch_item_id);

-- A confirmed, cancelled or reversed dispatch can never be edited, and its lines can never
-- change; the only change allowed after confirmation is confirmed -> reversed.
-- (Spec 6.6: confirmed dispatches must not be silently deleted or edited.)
CREATE FUNCTION protect_finished_dispatch() RETURNS trigger
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

CREATE TRIGGER dispatches_protect_finished
  BEFORE UPDATE ON dispatches
  FOR EACH ROW EXECUTE FUNCTION protect_finished_dispatch();

CREATE FUNCTION protect_finished_dispatch_items() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  parent_status text;
BEGIN
  SELECT status INTO parent_status FROM dispatches
  WHERE id = COALESCE(NEW.dispatch_id, OLD.dispatch_id);
  IF parent_status <> 'draft' THEN
    RAISE EXCEPTION 'The lines of a % dispatch cannot be changed', parent_status
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER dispatch_items_protect_finished
  BEFORE INSERT OR UPDATE OR DELETE ON dispatch_items
  FOR EACH ROW EXECUTE FUNCTION protect_finished_dispatch_items();

-- Dispatches are cancelled or reversed, never deleted. Draft lines may be removed while
-- editing a draft, so DELETE stays allowed on dispatch_items (the trigger guards it).
REVOKE DELETE ON dispatches FROM snackify_app;

-- Down Migration

DROP TRIGGER dispatch_items_protect_finished ON dispatch_items;
DROP FUNCTION protect_finished_dispatch_items();
DROP TRIGGER dispatches_protect_finished ON dispatches;
DROP FUNCTION protect_finished_dispatch();
ALTER TABLE stock_movements DROP COLUMN dispatch_item_id;
DROP TABLE dispatch_items;
DROP TABLE dispatches;
DROP SEQUENCE dispatch_number_seq;
