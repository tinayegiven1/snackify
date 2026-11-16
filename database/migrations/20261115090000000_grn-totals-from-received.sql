-- Up Migration

-- Goods-received notes are valued at what arrived, not what was bought (owner's request,
-- 2026-11-15): each line's amount is quantity received x unit cost, so a short delivery is worth
-- less and an over-delivery more. What was bought stays on the goods-bought list. Notes already
-- recorded are recalculated the same way (the owner's choice), so every note follows one rule.
-- Nothing else changes: stock movements, invoices and payments never used these amounts.

ALTER TABLE stock_receipt_lines DROP CONSTRAINT stock_receipt_lines_total_matches;

-- Submitted lines are otherwise locked by this trigger; pause it for the recalculation only.
ALTER TABLE stock_receipt_lines DISABLE TRIGGER stock_receipt_lines_draft_only;
UPDATE stock_receipt_lines
SET line_total = round(quantity_received * unit_cost, 2)
WHERE line_total <> round(quantity_received * unit_cost, 2);
ALTER TABLE stock_receipt_lines ENABLE TRIGGER stock_receipt_lines_draft_only;

ALTER TABLE stock_receipt_lines ADD CONSTRAINT stock_receipt_lines_total_matches
  CHECK (line_total = round(quantity_received * unit_cost, 2));

-- Down Migration

ALTER TABLE stock_receipt_lines DROP CONSTRAINT stock_receipt_lines_total_matches;
ALTER TABLE stock_receipt_lines DISABLE TRIGGER stock_receipt_lines_draft_only;
UPDATE stock_receipt_lines
SET line_total = round(quantity_purchased * unit_cost, 2)
WHERE line_total <> round(quantity_purchased * unit_cost, 2);
ALTER TABLE stock_receipt_lines ENABLE TRIGGER stock_receipt_lines_draft_only;
ALTER TABLE stock_receipt_lines ADD CONSTRAINT stock_receipt_lines_total_matches
  CHECK (line_total = round(quantity_purchased * unit_cost, 2));
