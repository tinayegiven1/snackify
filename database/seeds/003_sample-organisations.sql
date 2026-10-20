-- SAMPLE DATA for local development only: the Head Office and five made-up subsidiaries
-- (StockFlow Stage 3). Replace the names with the real ones before production, by editing this
-- file or under Organisations in the app; never in code.
-- Phone numbers use "+263 00 ...", which no real Zimbabwean number starts with. Safe to run
-- repeatedly: existing organisations keep any details changed since.

UPDATE organisations
SET name = 'Snackify Head Office (sample)'
WHERE organisation_type = 'HQ' AND name = 'Head Office';

INSERT INTO organisations (code, name, organisation_type, contact_name, contact_phone, address)
VALUES
  ('SUB-01', 'Sample Subsidiary One', 'SUBSIDIARY', 'Sample Manager One', '+263 00 100 0001',
   '1 Sample Street, Harare'),
  ('SUB-02', 'Sample Subsidiary Two', 'SUBSIDIARY', 'Sample Manager Two', '+263 00 100 0002',
   '2 Sample Street, Bulawayo'),
  ('SUB-03', 'Sample Subsidiary Three', 'SUBSIDIARY', 'Sample Manager Three', '+263 00 100 0003',
   '3 Sample Street, Mutare'),
  ('SUB-04', 'Sample Subsidiary Four', 'SUBSIDIARY', 'Sample Manager Four', '+263 00 100 0004',
   '4 Sample Street, Gweru'),
  ('SUB-05', 'Sample Subsidiary Five', 'SUBSIDIARY', 'Sample Manager Five', '+263 00 100 0005',
   '5 Sample Street, Masvingo')
ON CONFLICT (code) DO NOTHING;

-- Each subsidiary is a buyer (decision D1): it gets the customer record that dispatches and
-- invoices use, with the same code.
INSERT INTO customers (code, name, phone, address, organisation_id)
SELECT o.code, o.name, o.contact_phone, o.address, o.id
FROM organisations o
WHERE o.organisation_type = 'SUBSIDIARY'
  AND o.code LIKE 'SUB-0_'
  AND NOT EXISTS (SELECT 1 FROM customers c WHERE c.organisation_id = o.id)
  AND NOT EXISTS (SELECT 1 FROM customers c WHERE c.code = o.code);
