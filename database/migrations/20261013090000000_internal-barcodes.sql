-- Up Migration

-- Numbers for barcodes Snackify assigns itself to products without a manufacturer barcode
-- (spec 6.7). They become EAN-13 codes 20xxxxxxxxxxC: prefix 20 is reserved by GS1 for numbers
-- used only inside a business, so they never clash with a manufacturer's barcode.
CREATE SEQUENCE internal_barcode_seq;

-- Down Migration

DROP SEQUENCE internal_barcode_seq;
