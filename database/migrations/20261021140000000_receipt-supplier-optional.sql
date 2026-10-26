-- Up Migration

-- The supplier is no longer asked for on goods-received notes (owner's request, 2026-10-21): a
-- receipt may be submitted without one. The supplier invoice number and the supplier's
-- documents are still recorded. An existing supplier on older receipts is kept.

ALTER TABLE stock_receipts DROP CONSTRAINT stock_receipts_submitted;
ALTER TABLE stock_receipts ADD CONSTRAINT stock_receipts_submitted CHECK (
  status = 'DRAFT' OR (submitted_at IS NOT NULL AND submitted_by IS NOT NULL)
);

-- Down Migration

-- Fails if a submitted receipt has no supplier; give those receipts a supplier first.
ALTER TABLE stock_receipts DROP CONSTRAINT stock_receipts_submitted;
ALTER TABLE stock_receipts ADD CONSTRAINT stock_receipts_submitted CHECK (
  status = 'DRAFT' OR (submitted_at IS NOT NULL AND submitted_by IS NOT NULL AND supplier_id IS NOT NULL)
);
