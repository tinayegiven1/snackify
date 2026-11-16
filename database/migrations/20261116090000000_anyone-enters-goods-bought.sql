-- Up Migration

-- Every user may enter goods bought, and change or cancel the lists they entered themselves.
-- purchase.manage (finance and administrators) still changes or cancels anyone's list and is
-- the only one that verifies or rejects supplier documents.
INSERT INTO permissions (code, description) VALUES
  ('purchase.enter', 'Enter goods bought, and change or cancel own lists');
INSERT INTO role_permissions (role_id, permission_code)
SELECT id, 'purchase.enter' FROM roles;
UPDATE permissions SET description = 'Change or cancel any goods-bought list; verify supplier documents'
WHERE code = 'purchase.manage';

-- Down Migration

UPDATE permissions SET description = 'Enter, change and cancel lists of goods bought'
WHERE code = 'purchase.manage';
DELETE FROM role_permissions WHERE permission_code = 'purchase.enter';
DELETE FROM permissions WHERE code = 'purchase.enter';
