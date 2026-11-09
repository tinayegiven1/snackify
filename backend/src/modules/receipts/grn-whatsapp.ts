import type pg from 'pg';
import type { AppConfig } from '../../config/env.js';
import { logger } from '../../utils/logger.js';
import type { PublicUser } from '../auth/roles.js';
import { displayDate } from '../invoices/invoice-pdf.js';
import type { AccessScope } from '../organisations/access.js';
import { WhatsAppError, type WhatsAppSender } from '../whatsapp/whatsapp.js';
import { renderGrnPdf } from './grn-pdf.js';
import { readAttachment, type Receipt } from './receipts.service.js';

/** The goods-received note as a PDF, with photographed documents on pages of their own. */
export async function buildGrnPdf(
  db: pg.Pool,
  scope: AccessScope,
  receipt: Receipt,
  config: AppConfig,
): Promise<Buffer> {
  const pictures = [];
  for (const attachment of receipt.attachments) {
    if (attachment.mimeType !== 'image/jpeg' && attachment.mimeType !== 'image/png') continue;
    const document = await readAttachment(
      db,
      scope,
      receipt.id,
      attachment.id,
      config.attachments.storageDir,
    );
    pictures.push({
      filename: attachment.filename,
      verificationStatus: attachment.verificationStatus,
      content: document.content,
    });
  }
  return renderGrnPdf(receipt, config.business, pictures);
}

/**
 * Sends an approved note's PDF to the subsidiary that owns the stock, on its WhatsApp number,
 * and records the outcome (sent, failed with WhatsApp's reason, or skipped and why). Notes for
 * the Head Office's own stock are not sent anywhere. Never throws: the approval itself has
 * already been saved, and a failed message can be sent again from the note.
 */
export async function sendGrnOnWhatsApp(
  db: pg.Pool,
  receipt: Receipt,
  pdf: () => Promise<Buffer>,
  sender: WhatsAppSender | null,
  actor: PublicUser,
): Promise<void> {
  const { rows } = await db.query<{ type: string; name: string; whatsapp_number: string | null }>(
    `SELECT organisation_type AS type, name, whatsapp_number FROM organisations WHERE id = $1`,
    [receipt.owner.id],
  );
  const owner = rows[0];
  if (!owner || owner.type !== 'SUBSIDIARY') return;

  const record = (
    status: 'SENT' | 'FAILED' | 'SKIPPED',
    detail: string | null,
    messageId: string | null = null,
  ) =>
    db.query(
      `INSERT INTO grn_whatsapp_messages
         (receipt_id, organisation_id, to_number, status, detail, provider_message_id, sent_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [receipt.id, receipt.owner.id, owner.whatsapp_number, status, detail, messageId, actor.id],
    );

  try {
    if (!owner.whatsapp_number) {
      await record(
        'SKIPPED',
        `${owner.name} has no WhatsApp number. Add one under Organisations, then send again.`,
      );
      return;
    }
    if (!sender) {
      await record('SKIPPED', 'WhatsApp sending is not set up on the server yet.');
      return;
    }
    try {
      const { messageId } = await sender({
        to: owner.whatsapp_number,
        filename: `${receipt.grnNumber}.pdf`,
        content: await pdf(),
        bodyValues: [receipt.grnNumber, owner.name, displayDate(receipt.receivedDate)],
      });
      await record('SENT', null, messageId);
    } catch (error) {
      if (!(error instanceof WhatsAppError)) {
        logger.error('Sending a goods-received note on WhatsApp failed', {
          receiptId: receipt.id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      await record(
        'FAILED',
        error instanceof WhatsAppError ? error.message : 'Could not send it. Try again later.',
      );
    }
  } catch (error) {
    // Even recording the outcome failed: log it rather than undo an approval that was saved.
    logger.error('Could not record a WhatsApp message for a goods-received note', {
      receiptId: receipt.id,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}
