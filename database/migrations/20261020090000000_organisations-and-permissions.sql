-- Up Migration

-- StockFlow Stage 3 (docs/STAGE_3_5_PLAN.md): organisations, permission-based roles,
-- organisation ownership of stock, and organisation + network address in the audit log.
-- Everything here is additive: existing users join the Head Office, existing stock becomes the
-- Head Office's, and existing roles are mapped to the new ones (owner's decision D2).

-- ------------------------------------------------------------------ Organisations

-- The Head Office (HQ) and the independent subsidiaries that order from it. Names, contacts and
-- billing details are data (seed files and the admin screens), never code.
CREATE TABLE organisations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code              text NOT NULL,
  name              text NOT NULL,
  organisation_type text NOT NULL,
  is_active         boolean NOT NULL DEFAULT true,
  contact_name      text,
  contact_phone     text,
  contact_email     text,
  address           text,
  billing_name      text,
  billing_address   text,
  tax_number        text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT organisations_code_key UNIQUE (code),
  CONSTRAINT organisations_code_format CHECK (code ~ '^[A-Z0-9][A-Z0-9_-]{1,19}$'),
  CONSTRAINT organisations_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 120),
  CONSTRAINT organisations_type_valid CHECK (organisation_type IN ('HQ', 'SUBSIDIARY')),
  -- The Head Office is never deactivated: its users run the system.
  CONSTRAINT organisations_hq_active CHECK (organisation_type <> 'HQ' OR is_active),
  CONSTRAINT organisations_contact_name_valid
    CHECK (contact_name = btrim(contact_name) AND length(contact_name) BETWEEN 1 AND 120),
  CONSTRAINT organisations_contact_phone_format CHECK (contact_phone ~ '^\+?[0-9][0-9 ()-]{5,22}$'),
  CONSTRAINT organisations_contact_email_format
    CHECK (contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' AND length(contact_email) <= 254),
  CONSTRAINT organisations_address_valid
    CHECK (address = btrim(address) AND length(address) BETWEEN 1 AND 300),
  CONSTRAINT organisations_billing_name_valid
    CHECK (billing_name = btrim(billing_name) AND length(billing_name) BETWEEN 1 AND 120),
  CONSTRAINT organisations_billing_address_valid
    CHECK (billing_address = btrim(billing_address) AND length(billing_address) BETWEEN 1 AND 300),
  CONSTRAINT organisations_tax_number_valid
    CHECK (tax_number = btrim(tax_number) AND length(tax_number) BETWEEN 1 AND 40)
);

-- Exactly one Head Office.
CREATE UNIQUE INDEX organisations_one_hq ON organisations ((true)) WHERE organisation_type = 'HQ';

CREATE TRIGGER organisations_set_updated_at
  BEFORE UPDATE ON organisations
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Organisations are deactivated, never deleted: their history must stay valid.
REVOKE DELETE ON organisations FROM snackify_app;

-- The Head Office has to exist before users and stock can belong to it. Its name is a
-- placeholder: admins rename it, and the development seed sets one.
INSERT INTO organisations (code, name, organisation_type) VALUES ('HQ', 'Head Office', 'HQ');

-- The Head Office's id, for column defaults: stock recorded by the existing screens (receipts,
-- dispatches, adjustments) is the Head Office's own stock.
CREATE FUNCTION hq_organisation_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT id FROM organisations WHERE organisation_type = 'HQ'
$$;

-- ------------------------------------------------------------------ Users belong to one organisation

ALTER TABLE users ADD COLUMN organisation_id uuid REFERENCES organisations (id);
UPDATE users SET organisation_id = hq_organisation_id();
ALTER TABLE users ALTER COLUMN organisation_id SET NOT NULL;
CREATE INDEX users_organisation_idx ON users (organisation_id);

-- Roles now come from user_roles. The old single-role column is kept for history and dropped
-- by a later migration, once nothing reads it.
ALTER TABLE users ALTER COLUMN role DROP NOT NULL;

-- ------------------------------------------------------------------ Permissions and roles

-- A permission is one thing the system lets someone do, named by a code the API checks
-- (for example stock.receive). The list is defined by the code, so the API cannot change it.
CREATE TABLE permissions (
  code        text PRIMARY KEY,
  description text NOT NULL,

  CONSTRAINT permissions_code_format CHECK (code ~ '^[a-z_]+(\.[a-z_]+)+$')
);
REVOKE INSERT, UPDATE, DELETE ON permissions FROM snackify_app;

-- A role is a named set of permissions. Which permissions a role has is data (role_permissions),
-- so it can be changed without changing code.
CREATE TABLE roles (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code              text NOT NULL,
  name              text NOT NULL,
  description       text NOT NULL,
  -- Which kind of organisation's users may hold it.
  organisation_type text NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT roles_code_key UNIQUE (code),
  CONSTRAINT roles_code_format CHECK (code ~ '^[a-z][a-z_]{1,39}$'),
  CONSTRAINT roles_name_valid CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 60),
  CONSTRAINT roles_organisation_type_valid CHECK (organisation_type IN ('HQ', 'SUBSIDIARY'))
);
REVOKE DELETE ON roles FROM snackify_app;

CREATE TABLE role_permissions (
  role_id         uuid NOT NULL REFERENCES roles (id),
  permission_code text NOT NULL REFERENCES permissions (code),
  PRIMARY KEY (role_id, permission_code)
);

CREATE TABLE user_roles (
  user_id    uuid NOT NULL REFERENCES users (id),
  role_id    uuid NOT NULL REFERENCES roles (id),
  granted_by uuid REFERENCES users (id),
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, role_id)
);
CREATE INDEX user_roles_role_idx ON user_roles (role_id);

-- A user may only hold roles meant for their kind of organisation (a subsidiary's staff can
-- never be given a Head Office role). Checked whenever roles or organisations change.
CREATE FUNCTION assert_roles_match_organisation(target_user uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM user_roles ur
    JOIN users u ON u.id = ur.user_id
    JOIN organisations o ON o.id = u.organisation_id
    JOIN roles r ON r.id = ur.role_id
    WHERE ur.user_id = target_user AND r.organisation_type <> o.organisation_type
  ) THEN
    RAISE EXCEPTION 'A role does not match the user''s organisation type'
      USING ERRCODE = 'check_violation', CONSTRAINT = 'user_roles_organisation_type';
  END IF;
END;
$$;

CREATE FUNCTION check_user_role_organisation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM assert_roles_match_organisation(NEW.user_id);
  RETURN NEW;
END;
$$;

CREATE FUNCTION check_user_organisation_roles() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM assert_roles_match_organisation(NEW.id);
  RETURN NEW;
END;
$$;

CREATE TRIGGER user_roles_organisation_type
  AFTER INSERT OR UPDATE ON user_roles
  FOR EACH ROW EXECUTE FUNCTION check_user_role_organisation();
CREATE TRIGGER users_roles_organisation_type
  AFTER UPDATE OF organisation_id ON users
  FOR EACH ROW EXECUTE FUNCTION check_user_organisation_roles();

INSERT INTO permissions (code, description) VALUES
  ('organisation.manage', 'Add organisations and change their details'),
  ('user.manage', 'Add staff accounts, give roles, deactivate accounts and set new passwords'),
  ('role.manage', 'Change which permissions each role has'),
  ('audit.view', 'Read the audit log'),
  ('product.manage', 'Add products and change them, including prices and barcodes'),
  ('label.print', 'Print barcode labels'),
  ('stock.view', 'See stock and its history (the own organisation''s, or all for the Head Office)'),
  ('stock.receive', 'Record stock received'),
  ('stock.opening_balance', 'Record a product''s opening stock'),
  ('stock.adjust', 'Correct stock by hand, with a reason'),
  ('customer.view', 'See customers'),
  ('customer.edit_details', 'Change customer names, codes, phones and addresses'),
  ('customer.edit_credit_limit', 'Change customer credit limits'),
  ('customer.change_active', 'Deactivate and reactivate customers'),
  ('dispatch.view', 'See dispatches'),
  ('dispatch.draft', 'Prepare, change and cancel draft dispatches'),
  ('dispatch.confirm', 'Confirm dispatches (stock leaves)'),
  ('dispatch.reverse', 'Reverse confirmed dispatches'),
  ('invoice.manage', 'Prepare, issue and void invoices'),
  ('payment.manage', 'Record and allocate payments; see balances and statements'),
  ('payment.void', 'Void payments'),
  ('report.dashboard', 'See the dashboard'),
  ('report.financial', 'See sales and customer reports with money values'),
  ('report.stock', 'See stock-received and expiring-stock reports'),
  ('forecast.use', 'See and make sales forecasts');

INSERT INTO roles (code, name, description, organisation_type) VALUES
  ('system_admin', 'System Administrator',
   'Organisations, users, roles, settings and the product catalogue; stock corrections.', 'HQ'),
  ('hq_warehouse_officer', 'HQ Warehouse Officer',
   'Receives stock, confirms dispatches, prints labels; sees stock and its history.', 'HQ'),
  ('hq_finance_officer', 'HQ Finance Officer',
   'Invoices, payments, credit limits, financial reports and forecasts.', 'HQ'),
  ('hq_sales_officer', 'HQ Sales Officer',
   'Customer details and draft dispatches.', 'HQ'),
  ('subsidiary_manager', 'Subsidiary Manager',
   'Sees the own organisation''s stock; places orders (from Stage 5).', 'SUBSIDIARY'),
  ('subsidiary_storekeeper', 'Subsidiary Storekeeper',
   'Sees the own organisation''s stock and its history.', 'SUBSIDIARY');

-- What each role may do. These rows reproduce what each of the old roles could do, so nobody
-- gains or loses anything by the switch.
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, p.code
FROM (VALUES
  ('system_admin', 'organisation.manage'),
  ('system_admin', 'user.manage'),
  ('system_admin', 'role.manage'),
  ('system_admin', 'audit.view'),
  ('system_admin', 'product.manage'),
  ('system_admin', 'stock.view'),
  ('system_admin', 'stock.opening_balance'),
  ('system_admin', 'stock.adjust'),
  ('system_admin', 'customer.view'),
  ('system_admin', 'customer.edit_details'),
  ('system_admin', 'customer.change_active'),
  ('system_admin', 'dispatch.view'),
  ('system_admin', 'dispatch.reverse'),
  ('system_admin', 'payment.void'),
  ('system_admin', 'report.dashboard'),
  ('hq_warehouse_officer', 'label.print'),
  ('hq_warehouse_officer', 'stock.view'),
  ('hq_warehouse_officer', 'stock.receive'),
  ('hq_warehouse_officer', 'customer.view'),
  ('hq_warehouse_officer', 'dispatch.view'),
  ('hq_warehouse_officer', 'dispatch.draft'),
  ('hq_warehouse_officer', 'dispatch.confirm'),
  ('hq_warehouse_officer', 'report.dashboard'),
  ('hq_warehouse_officer', 'report.stock'),
  ('hq_warehouse_officer', 'forecast.use'),
  ('hq_finance_officer', 'stock.view'),
  ('hq_finance_officer', 'customer.view'),
  ('hq_finance_officer', 'customer.edit_credit_limit'),
  ('hq_finance_officer', 'dispatch.view'),
  ('hq_finance_officer', 'invoice.manage'),
  ('hq_finance_officer', 'payment.manage'),
  ('hq_finance_officer', 'report.dashboard'),
  ('hq_finance_officer', 'report.financial'),
  ('hq_finance_officer', 'report.stock'),
  ('hq_finance_officer', 'forecast.use'),
  ('hq_sales_officer', 'stock.view'),
  ('hq_sales_officer', 'customer.view'),
  ('hq_sales_officer', 'customer.edit_details'),
  ('hq_sales_officer', 'dispatch.view'),
  ('hq_sales_officer', 'dispatch.draft'),
  ('hq_sales_officer', 'report.dashboard'),
  ('subsidiary_manager', 'stock.view'),
  ('subsidiary_storekeeper', 'stock.view')
) AS grants (role_code, permission_code)
JOIN roles r ON r.code = grants.role_code
JOIN permissions p ON p.code = grants.permission_code;

-- Existing accounts keep exactly what they could do (decision D2). An old admin could do
-- everything, so it receives all four Head Office roles.
INSERT INTO user_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u
JOIN (VALUES
  ('admin', 'system_admin'),
  ('admin', 'hq_finance_officer'),
  ('admin', 'hq_warehouse_officer'),
  ('admin', 'hq_sales_officer'),
  ('storekeeper', 'hq_warehouse_officer'),
  ('accounts', 'hq_finance_officer'),
  ('salesperson', 'hq_sales_officer')
) AS mapping (old_role, role_code) ON mapping.old_role = u.role
JOIN roles r ON r.code = mapping.role_code;

-- ------------------------------------------------------------------ Stock belongs to an organisation

-- Where stock is kept is not who owns it. Every batch and ledger entry records its owner;
-- everything recorded so far is the Head Office's.
ALTER TABLE stock_batches
  ADD COLUMN owner_organisation_id uuid NOT NULL DEFAULT hq_organisation_id()
    REFERENCES organisations (id);
ALTER TABLE stock_movements
  ADD COLUMN owner_organisation_id uuid NOT NULL DEFAULT hq_organisation_id()
    REFERENCES organisations (id);
CREATE INDEX stock_movements_owner_product_idx
  ON stock_movements (owner_organisation_id, product_id);
CREATE INDEX stock_batches_owner_idx ON stock_batches (owner_organisation_id, received_date);

-- A batch's ledger entries belong to the batch's owner.
ALTER TABLE stock_batches ADD CONSTRAINT stock_batches_id_owner_key UNIQUE (id, owner_organisation_id);
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_batch_owner_fkey
  FOREIGN KEY (batch_id, owner_organisation_id)
  REFERENCES stock_batches (id, owner_organisation_id);

-- stock_balances is the Head Office's own stock: what dispatches, forecasts and reports use.
-- The Head Office can never dispatch or sell stock that belongs to a subsidiary.
CREATE OR REPLACE VIEW stock_balances AS
SELECT p.id AS product_id, COALESCE(sum(m.quantity_delta), 0)::integer AS quantity_on_hand
FROM products p
LEFT JOIN stock_movements m
  ON m.product_id = p.id AND m.owner_organisation_id = hq_organisation_id()
GROUP BY p.id;

-- ------------------------------------------------------------------ Subsidiaries replace customers

-- Decision D1: the subsidiaries are the buyers. Each subsidiary is linked to the customer record
-- that today's dispatch and invoice screens use, until Stage 6 moves those onto organisations.
ALTER TABLE customers ADD COLUMN organisation_id uuid REFERENCES organisations (id);
ALTER TABLE customers ADD CONSTRAINT customers_organisation_key UNIQUE (organisation_id);

-- ------------------------------------------------------------------ Audit log

ALTER TABLE audit_logs ADD COLUMN organisation_id uuid REFERENCES organisations (id);
ALTER TABLE audit_logs ADD COLUMN ip_address inet;
-- Everyone who acted so far worked for the Head Office.
UPDATE audit_logs SET organisation_id = hq_organisation_id() WHERE actor_user_id IS NOT NULL;
CREATE INDEX audit_logs_organisation_idx ON audit_logs (organisation_id, occurred_at);

-- Down Migration

DROP INDEX audit_logs_organisation_idx;
ALTER TABLE audit_logs DROP COLUMN ip_address;
ALTER TABLE audit_logs DROP COLUMN organisation_id;

ALTER TABLE customers DROP CONSTRAINT customers_organisation_key;
ALTER TABLE customers DROP COLUMN organisation_id;

CREATE OR REPLACE VIEW stock_balances AS
SELECT p.id AS product_id, COALESCE(sum(m.quantity_delta), 0)::integer AS quantity_on_hand
FROM products p
LEFT JOIN stock_movements m ON m.product_id = p.id
GROUP BY p.id;

ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_batch_owner_fkey;
ALTER TABLE stock_batches DROP CONSTRAINT stock_batches_id_owner_key;
DROP INDEX stock_batches_owner_idx;
DROP INDEX stock_movements_owner_product_idx;
ALTER TABLE stock_movements DROP COLUMN owner_organisation_id;
ALTER TABLE stock_batches DROP COLUMN owner_organisation_id;

-- Accounts created after this migration have no old role; give them the nearest one.
UPDATE users u SET role = CASE
    WHEN EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE ur.user_id = u.id AND r.code = 'system_admin') THEN 'admin'
    WHEN EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE ur.user_id = u.id AND r.code = 'hq_finance_officer') THEN 'accounts'
    WHEN EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE ur.user_id = u.id AND r.code = 'hq_warehouse_officer') THEN 'storekeeper'
    ELSE 'salesperson'
  END
WHERE u.role IS NULL;
ALTER TABLE users ALTER COLUMN role SET NOT NULL;

DROP TRIGGER users_roles_organisation_type ON users;
DROP TRIGGER user_roles_organisation_type ON user_roles;
DROP FUNCTION check_user_organisation_roles();
DROP FUNCTION check_user_role_organisation();
DROP FUNCTION assert_roles_match_organisation(uuid);
DROP TABLE user_roles;
DROP TABLE role_permissions;
DROP TABLE roles;
DROP TABLE permissions;

DROP INDEX users_organisation_idx;
ALTER TABLE users DROP COLUMN organisation_id;
DROP FUNCTION hq_organisation_id();
DROP TABLE organisations;
