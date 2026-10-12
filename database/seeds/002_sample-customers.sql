-- SAMPLE DATA for local development only: made-up customers.
-- Phone numbers use "+263 00 ...", which no real Zimbabwean number starts with, so a test
-- call or message can never reach a real person. Safe to run repeatedly.

INSERT INTO customers (code, name, phone, address, credit_limit) VALUES
  ('SAMPLE-01', 'Sample Tuckshop',      '+263 00 000 0001', '1 Example Road, Harare', 300.00),
  ('SAMPLE-02', 'Sample Grocers',       '+263 00 000 0002', '2 Example Avenue, Harare', NULL),
  ('SAMPLE-03', 'Sample School Canteen', NULL,              NULL,                     150.00)
ON CONFLICT (code) DO NOTHING;
