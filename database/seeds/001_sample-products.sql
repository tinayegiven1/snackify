-- SAMPLE DATA for local development only: made-up products, no real business data.
-- Barcodes start with "200", a GS1 range reserved for in-store use, so they cannot clash
-- with real retail products. Safe to run repeatedly.

INSERT INTO products (sku, name, flavour, size, barcode, default_price) VALUES
  ('PC-BBQ-S', 'Potato Crisps', 'BBQ',            'Small', '2000000000015', 0.50),
  ('PC-BBQ-L', 'Potato Crisps', 'BBQ',            'Large', '2000000000022', 1.00),
  ('PC-SV-S',  'Potato Crisps', 'Salt & Vinegar', 'Small', '2000000000039', 0.50),
  ('PC-SV-L',  'Potato Crisps', 'Salt & Vinegar', 'Large', '2000000000046', 1.00),
  ('MP-CH-S',  'Maize Puffs',   'Cheese',         'Small', '2000000000053', 0.30),
  ('MP-CH-L',  'Maize Puffs',   'Cheese',         'Large', NULL,            0.80)
ON CONFLICT (sku) DO NOTHING;
