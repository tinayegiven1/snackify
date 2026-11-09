-- Up Migration

-- Supplier documents move to goods bought (owner's request, 2026-11-09): finance or an
-- administrator attaches the supplier's invoice or delivery note to the list of goods bought,
-- and only finance and administrators verify or reject it (recording the total printed on it).
-- Goods-received notes no longer take documents: the warehouse only checks what arrived, and
-- finance or an administrator approves the note. Documents already on goods-received notes stay
-- there as history.

CREATE TABLE purchase_attachments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_id         uuid NOT NULL REFERENCES purchases (id),
  original_filename   text NOT NULL,
  storage_key         text NOT NULL,
  mime_type           text NOT NULL,
  size_bytes          integer NOT NULL,
  sha256              text NOT NULL,
  uploaded_by         uuid NOT NULL REFERENCES users (id),
  uploaded_at         timestamptz NOT NULL DEFAULT now(),
  verification_status text NOT NULL DEFAULT 'PENDING',
  reviewed_by         uuid REFERENCES users (id),
  reviewed_at         timestamptz,
  review_notes        text,
  -- The total printed on the document, as the reviewer read it, to compare with the list.
  document_total      numeric(14, 2),

  CONSTRAINT purchase_attachments_storage_key_key UNIQUE (storage_key),
  CONSTRAINT purchase_attachments_storage_key_format CHECK (storage_key ~ '^[a-f0-9]{64}$'),
  CONSTRAINT purchase_attachments_filename_valid
    CHECK (length(original_filename) BETWEEN 1 AND 200),
  CONSTRAINT purchase_attachments_mime_valid
    CHECK (mime_type IN ('application/pdf', 'image/jpeg', 'image/png')),
  CONSTRAINT purchase_attachments_size_valid CHECK (size_bytes > 0),
  CONSTRAINT purchase_attachments_sha256_format CHECK (sha256 ~ '^[a-f0-9]{64}$'),
  CONSTRAINT purchase_attachments_status_valid
    CHECK (verification_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
  CONSTRAINT purchase_attachments_reviewed CHECK (
    (verification_status = 'PENDING') = (reviewed_at IS NULL)
    AND (verification_status <> 'REJECTED' OR length(btrim(review_notes)) BETWEEN 3 AND 500)
  ),
  CONSTRAINT purchase_attachments_document_total_valid CHECK (document_total >= 0)
);
CREATE INDEX purchase_attachments_purchase_idx ON purchase_attachments (purchase_id);
REVOKE DELETE ON purchase_attachments FROM snackify_app;

-- Down Migration

DROP TABLE purchase_attachments;
