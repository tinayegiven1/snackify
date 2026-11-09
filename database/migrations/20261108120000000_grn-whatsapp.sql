-- Up Migration

-- Approved goods-received notes are sent to the subsidiary on WhatsApp (owner's request,
-- 2026-11-08). Each subsidiary gets its own WhatsApp number, separate from its contact phone,
-- and every attempt to send a note is kept: sent, failed (with the reason) or skipped (no
-- number, or WhatsApp not set up on the server).

ALTER TABLE organisations ADD COLUMN whatsapp_number text;
ALTER TABLE organisations ADD CONSTRAINT organisations_whatsapp_number_format
  CHECK (whatsapp_number ~ '^\+?[0-9][0-9 ()-]{5,22}$');
COMMENT ON COLUMN organisations.whatsapp_number IS
  'Where approved goods-received notes are sent on WhatsApp, with the country code.';

CREATE TABLE grn_whatsapp_messages (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id          uuid NOT NULL REFERENCES stock_receipts (id),
  organisation_id     uuid NOT NULL REFERENCES organisations (id),
  -- The number as it was when sending; NULL when the organisation had none.
  to_number           text,
  status              text NOT NULL,
  -- Why it failed or was skipped.
  detail              text,
  -- WhatsApp's id for the message, when it was accepted.
  provider_message_id text,
  sent_by             uuid NOT NULL REFERENCES users (id),
  created_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT grn_whatsapp_messages_status_valid CHECK (status IN ('SENT', 'FAILED', 'SKIPPED')),
  CONSTRAINT grn_whatsapp_messages_detail_given CHECK (status = 'SENT' OR detail IS NOT NULL)
);
CREATE INDEX grn_whatsapp_messages_receipt_idx ON grn_whatsapp_messages (receipt_id, created_at);
-- A record of what was sent: the API may only add to it.
REVOKE UPDATE, DELETE ON grn_whatsapp_messages FROM snackify_app;

-- Down Migration

DROP TABLE grn_whatsapp_messages;
ALTER TABLE organisations DROP CONSTRAINT organisations_whatsapp_number_format;
ALTER TABLE organisations DROP COLUMN whatsapp_number;
