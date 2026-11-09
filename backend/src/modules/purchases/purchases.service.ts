import { unlink } from 'node:fs/promises';
import { join } from 'node:path';
import type pg from 'pg';
import { escapeLike } from '../../database/sql.js';
import { withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { recordAudit } from '../audit/audit.js';
import type { PublicUser } from '../auth/roles.js';
import { canAccessOrganisation, type AccessScope } from '../organisations/access.js';
import { toBaseQuantity } from '../products/products.service.js';
import {
  cleanFilename,
  detectDocumentType,
  readDocument,
  storeDocument,
} from '../receipts/attachment-files.js';

/**
 * Goods bought: what finance bought from a supplier, before it arrives. The warehouse receives
 * against it with a goods-received note (stock_receipts.purchase_id), so each line shows how much
 * has arrived. Receipts waiting for verification, verified or posted count as arrived; drafts,
 * rejected and reversed ones do not.
 */

export type PurchaseStatus = 'OPEN' | 'CANCELLED';
export type ReceivingStatus = 'NOT_RECEIVED' | 'PARTLY_RECEIVED' | 'RECEIVED';

interface Ref {
  id: string;
  code: string;
  name: string;
}
interface Person {
  id: string;
  fullName: string;
}

export interface PurchaseSummary {
  id: string;
  purchaseNumber: string;
  status: PurchaseStatus;
  receivingStatus: ReceivingStatus;
  owner: Ref;
  supplier: Ref | null;
  supplierInvoiceNumber: string | null;
  purchaseDate: string;
  currency: string;
  total: string;
  lineCount: number;
  /** Supplier documents attached, and how many still wait for finance to review. */
  documentCount: number;
  documentsPending: number;
  createdBy: Person;
  createdAt: Date;
}

/** A supplier document (invoice or delivery note) attached to the list. */
export interface PurchaseAttachment {
  id: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  uploadedBy: Person;
  uploadedAt: Date;
  verificationStatus: 'PENDING' | 'VERIFIED' | 'REJECTED';
  reviewedBy: Person | null;
  reviewedAt: Date | null;
  reviewNotes: string | null;
  /** The total printed on the document, as the reviewer read it. */
  documentTotal: string | null;
}

export interface PurchaseLine {
  id: string;
  lineNumber: number;
  product: { id: string; sku: string; description: string };
  unit: Ref;
  quantity: number;
  unitCost: string;
  lineTotal: string;
  /** Received so far on goods-received notes waiting for verification, verified or posted. */
  quantityReceived: number;
  /** Still to arrive (never below zero). */
  quantityOutstanding: number;
  notes: string | null;
}

export interface Purchase extends PurchaseSummary {
  notes: string | null;
  cancelledBy: Person | null;
  cancelledAt: Date | null;
  cancelReason: string | null;
  /** False once any goods-received note has been made from the list. */
  canChange: boolean;
  /** False while a goods-received note from it stands (anything but rejected or reversed). */
  canCancel: boolean;
  lines: PurchaseLine[];
  /** Goods-received notes made from the list, oldest first. */
  receipts: { id: string; grnNumber: string; status: string; receivedDate: string }[];
  /** Supplier documents, oldest first. */
  attachments: PurchaseAttachment[];
}

export interface PurchaseLineInput {
  productId: string;
  unitId: string;
  quantity: number;
  unitCost: string;
  notes: string | null;
}

export interface PurchaseInput {
  ownerOrganisationId: string;
  supplierId: string | null;
  supplierInvoiceNumber: string | null;
  purchaseDate: string;
  notes: string | null;
  lines: PurchaseLineInput[];
}

export const purchaseNotFound = () =>
  new AppError(404, 'PURCHASE_NOT_FOUND', 'No goods-bought list has that id.');

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

/** Receipts that count: anything submitted and not undone. */
const COUNTED = `('PENDING_VERIFICATION', 'VERIFIED', 'POSTED')`;
/** Receipts that hold the list: anything not rejected or reversed (drafts too). */
const HOLDING = `('DRAFT', 'PENDING_VERIFICATION', 'VERIFIED', 'POSTED')`;
/** Every receipt, undone or not. */
const ANY_RECEIPT = `('DRAFT', 'PENDING_VERIFICATION', 'VERIFIED', 'POSTED', 'REJECTED', 'REVERSED')`;

const SUMMARY_SELECT = `
  SELECT p.id, p.purchase_number, p.status, p.supplier_invoice_number, p.purchase_date::text,
         p.currency, p.created_at, p.notes, p.cancelled_at, p.cancel_reason,
         json_build_object('id', o.id, 'code', o.code, 'name', o.name) AS owner,
         CASE WHEN s.id IS NULL THEN NULL
              ELSE json_build_object('id', s.id, 'code', s.code, 'name', s.name) END AS supplier,
         json_build_object('id', cb.id, 'fullName', cb.full_name) AS created_by,
         CASE WHEN xb.id IS NULL THEN NULL
              ELSE json_build_object('id', xb.id, 'fullName', xb.full_name) END AS cancelled_by,
         (SELECT COALESCE(sum(l.line_total), 0)::numeric(14, 2)::text
          FROM purchase_lines l WHERE l.purchase_id = p.id) AS total,
         (SELECT count(*)::int FROM purchase_lines l WHERE l.purchase_id = p.id) AS line_count,
         (SELECT count(*)::int FROM purchase_attachments a WHERE a.purchase_id = p.id)
           AS document_count,
         (SELECT count(*)::int FROM purchase_attachments a
          WHERE a.purchase_id = p.id AND a.verification_status = 'PENDING') AS documents_pending,
         (SELECT CASE
                   WHEN bool_and(received >= quantity) THEN 'RECEIVED'
                   WHEN bool_or(received > 0) THEN 'PARTLY_RECEIVED'
                   ELSE 'NOT_RECEIVED' END
          FROM (SELECT l.quantity,
                       COALESCE(sum(rl.quantity_received) FILTER (WHERE r.status IN ${COUNTED}), 0)
                         AS received
                FROM purchase_lines l
                LEFT JOIN stock_receipt_lines rl ON rl.purchase_line_id = l.id
                LEFT JOIN stock_receipts r ON r.id = rl.receipt_id
                WHERE l.purchase_id = p.id
                GROUP BY l.id) per_line) AS receiving_status,
         NOT EXISTS (SELECT 1 FROM stock_receipts r WHERE r.purchase_id = p.id) AS can_change,
         NOT EXISTS (SELECT 1 FROM stock_receipts r
                     WHERE r.purchase_id = p.id AND r.status IN ${HOLDING}) AS can_cancel
  FROM purchases p
  JOIN organisations o ON o.id = p.owner_organisation_id
  LEFT JOIN suppliers s ON s.id = p.supplier_id
  JOIN users cb ON cb.id = p.created_by
  LEFT JOIN users xb ON xb.id = p.cancelled_by`;

interface SummaryRow {
  id: string;
  purchase_number: string;
  status: PurchaseStatus;
  supplier_invoice_number: string | null;
  purchase_date: string;
  currency: string;
  created_at: Date;
  notes: string | null;
  cancelled_at: Date | null;
  cancel_reason: string | null;
  owner: Ref;
  supplier: Ref | null;
  created_by: Person;
  cancelled_by: Person | null;
  total: string;
  line_count: number;
  document_count: number;
  documents_pending: number;
  receiving_status: ReceivingStatus;
  can_change: boolean;
  can_cancel: boolean;
}

const toSummary = (row: SummaryRow): PurchaseSummary => ({
  id: row.id,
  purchaseNumber: row.purchase_number,
  status: row.status,
  receivingStatus: row.receiving_status,
  owner: row.owner,
  supplier: row.supplier,
  supplierInvoiceNumber: row.supplier_invoice_number,
  purchaseDate: row.purchase_date,
  currency: row.currency,
  total: row.total,
  lineCount: row.line_count,
  documentCount: row.document_count,
  documentsPending: row.documents_pending,
  createdBy: row.created_by,
  createdAt: row.created_at,
});

export interface PurchaseSearch {
  /** Part of the list number, supplier invoice number or supplier name. */
  q?: string | undefined;
  /** OPEN and CANCELLED, or a receiving status for open lists. */
  status?: PurchaseStatus | ReceivingStatus | undefined;
  limit: number;
  offset: number;
}

export async function listPurchases(
  db: Queryable,
  scope: AccessScope,
  search: PurchaseSearch,
): Promise<{ purchases: PurchaseSummary[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    params.push(value);
    conditions.push(condition.replaceAll('?', `$${params.length}`));
  };
  if (!scope.allOrganisations) add('x.owner_id = ?', scope.organisationId);
  if (search.q) {
    add(
      '(x.purchase_number ILIKE ? OR x.supplier_invoice_number ILIKE ? OR x.supplier_name ILIKE ?)',
      `%${escapeLike(search.q)}%`,
    );
  }
  if (search.status === 'OPEN' || search.status === 'CANCELLED') add('x.status = ?', search.status);
  else if (search.status) {
    add(`x.status = 'OPEN' AND x.receiving_status = ?`, search.status);
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const { rows } = await db.query<SummaryRow & { full_count: number }>(
    `SELECT x.*, count(*) OVER ()::int AS full_count
     FROM (${SUMMARY_SELECT.replace(
       'FROM purchases p',
       `, p.owner_organisation_id AS owner_id, s.name AS supplier_name
       FROM purchases p`,
     )}) x
     ${where}
     ORDER BY x.purchase_date DESC, x.created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, search.limit, search.offset],
  );
  return { purchases: rows.map(toSummary), total: rows[0]?.full_count ?? 0 };
}

export async function getPurchase(
  db: Queryable,
  scope: AccessScope,
  id: string,
): Promise<Purchase> {
  const { rows } = await db.query<SummaryRow>(`${SUMMARY_SELECT} WHERE p.id = $1`, [id]);
  const row = rows[0];
  if (!row || !canAccessOrganisation(scope, row.owner.id)) throw purchaseNotFound();

  const { rows: lines } = await db.query<{
    id: string;
    line_number: number;
    product: { id: string; sku: string; description: string };
    unit: Ref;
    quantity: number;
    unit_cost: string;
    line_total: string;
    received: number;
    notes: string | null;
  }>(
    `SELECT l.id, l.line_number, l.quantity, l.unit_cost::text, l.line_total::text, l.notes,
            json_build_object('id', pr.id, 'sku', pr.sku,
              'description', pr.name || ' — ' || pr.flavour || ' — ' || pr.size) AS product,
            json_build_object('id', u.id, 'code', u.code, 'name', u.name) AS unit,
            (SELECT COALESCE(sum(rl.quantity_received), 0)::int
             FROM stock_receipt_lines rl JOIN stock_receipts r ON r.id = rl.receipt_id
             WHERE rl.purchase_line_id = l.id AND r.status IN ${COUNTED}) AS received
     FROM purchase_lines l
     JOIN products pr ON pr.id = l.product_id
     JOIN units u ON u.id = l.unit_id
     WHERE l.purchase_id = $1
     ORDER BY l.line_number`,
    [id],
  );
  const { rows: receipts } = await db.query<{
    id: string;
    grn_number: string;
    status: string;
    received_date: string;
  }>(
    `SELECT id, grn_number, status, received_date::text FROM stock_receipts
     WHERE purchase_id = $1 ORDER BY created_at, grn_number`,
    [id],
  );
  const { rows: attachments } = await db.query<{
    id: string;
    original_filename: string;
    mime_type: string;
    size_bytes: number;
    uploaded_by: Person;
    uploaded_at: Date;
    verification_status: PurchaseAttachment['verificationStatus'];
    reviewed_by: Person | null;
    reviewed_at: Date | null;
    review_notes: string | null;
    document_total: string | null;
  }>(
    `SELECT a.id, a.original_filename, a.mime_type, a.size_bytes, a.uploaded_at,
            a.verification_status, a.reviewed_at, a.review_notes, a.document_total::text,
            json_build_object('id', ub.id, 'fullName', ub.full_name) AS uploaded_by,
            CASE WHEN rv.id IS NULL THEN NULL
                 ELSE json_build_object('id', rv.id, 'fullName', rv.full_name) END AS reviewed_by
     FROM purchase_attachments a
     JOIN users ub ON ub.id = a.uploaded_by
     LEFT JOIN users rv ON rv.id = a.reviewed_by
     WHERE a.purchase_id = $1
     ORDER BY a.uploaded_at, a.id`,
    [id],
  );

  return {
    ...toSummary(row),
    notes: row.notes,
    cancelledBy: row.cancelled_by,
    cancelledAt: row.cancelled_at,
    cancelReason: row.cancel_reason,
    canChange: row.status === 'OPEN' && row.can_change,
    canCancel: row.status === 'OPEN' && row.can_cancel,
    lines: lines.map((line) => ({
      id: line.id,
      lineNumber: line.line_number,
      product: line.product,
      unit: line.unit,
      quantity: line.quantity,
      unitCost: line.unit_cost,
      lineTotal: line.line_total,
      quantityReceived: line.received,
      quantityOutstanding: Math.max(line.quantity - line.received, 0),
      notes: line.notes,
    })),
    receipts: receipts.map((r) => ({
      id: r.id,
      grnNumber: r.grn_number,
      status: r.status,
      receivedDate: r.received_date,
    })),
    attachments: attachments.map((a) => ({
      id: a.id,
      filename: a.original_filename,
      mimeType: a.mime_type,
      sizeBytes: a.size_bytes,
      uploadedBy: a.uploaded_by,
      uploadedAt: a.uploaded_at,
      verificationStatus: a.verification_status,
      reviewedBy: a.reviewed_by,
      reviewedAt: a.reviewed_at,
      reviewNotes: a.review_notes,
      documentTotal: a.document_total,
    })),
  };
}

/** Checks the owner and supplier are active, and every line's product and unit. */
async function checkInput(client: pg.PoolClient, input: PurchaseInput): Promise<void> {
  const { rows } = await client.query<{ active: boolean }>(
    'SELECT is_active AS active FROM organisations WHERE id = $1',
    [input.ownerOrganisationId],
  );
  if (!rows[0]?.active) throw fieldError('organisationId', 'Choose an active organisation');
  if (input.supplierId) {
    const { rowCount } = await client.query('SELECT 1 FROM suppliers WHERE id = $1 AND is_active', [
      input.supplierId,
    ]);
    if (!rowCount) throw fieldError('supplierId', 'Choose an active supplier');
  }
  if (input.lines.length === 0) throw fieldError('lines', 'Add at least one product');
  for (const [index, line] of input.lines.entries()) {
    const { rows: products } = await client.query<{ is_active: boolean }>(
      'SELECT is_active FROM products WHERE id = $1',
      [line.productId],
    );
    if (!products[0]) throw fieldError(`lines.${index}.productId`, 'No product has that id');
    if (!products[0].is_active) {
      throw fieldError(`lines.${index}.productId`, 'This product is inactive');
    }
    // Refuses a unit the product cannot be counted in.
    await toBaseQuantity(
      client,
      line.productId,
      line.unitId,
      line.quantity,
      `lines.${index}.unitId`,
    );
  }
}

async function writeLines(client: pg.PoolClient, purchaseId: string, lines: PurchaseLineInput[]) {
  for (const [index, line] of lines.entries()) {
    await client.query(
      `INSERT INTO purchase_lines (purchase_id, line_number, product_id, unit_id, quantity,
                                   unit_cost, notes)
       VALUES ($1, $2, $3, $4, $5, $6::numeric, $7)`,
      [
        purchaseId,
        index + 1,
        line.productId,
        line.unitId,
        line.quantity,
        line.unitCost,
        line.notes,
      ],
    );
  }
}

export async function createPurchase(
  pool: pg.Pool,
  input: PurchaseInput,
  actor: PublicUser,
  currency: string,
): Promise<Purchase> {
  const id = await withTransaction(pool, async (client) => {
    await checkInput(client, input);
    const { rows } = await client.query<{ id: string; purchase_number: string }>(
      `INSERT INTO purchases (owner_organisation_id, supplier_id, supplier_invoice_number,
                              purchase_date, currency, notes, created_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       RETURNING id, purchase_number`,
      [
        input.ownerOrganisationId,
        input.supplierId,
        input.supplierInvoiceNumber,
        input.purchaseDate,
        currency,
        input.notes,
        actor.id,
      ],
    );
    const created = rows[0] as { id: string; purchase_number: string };
    await writeLines(client, created.id, input.lines);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'purchase.created',
      entityType: 'purchase',
      entityId: created.id,
      organisationId: input.ownerOrganisationId,
      details: { purchaseNumber: created.purchase_number, lines: input.lines.length },
    });
    return created.id;
  });
  return getPurchase(pool, { allOrganisations: true, organisationId: '' }, id);
}

/**
 * Locks an open list that nothing has been received against yet. [statuses] are the receipt
 * statuses that block it: any receipt at all blocks changing the lines (they keep pointing at
 * them); only receipts still standing block cancelling.
 */
async function lockChangeable(
  client: pg.PoolClient,
  scope: AccessScope,
  id: string,
  action: string,
  statuses: string,
) {
  const { rows } = await client.query<{
    status: PurchaseStatus;
    purchase_number: string;
    owner_organisation_id: string;
  }>(
    'SELECT status, purchase_number, owner_organisation_id FROM purchases WHERE id = $1 FOR UPDATE',
    [id],
  );
  const row = rows[0];
  if (!row || !canAccessOrganisation(scope, row.owner_organisation_id)) throw purchaseNotFound();
  if (row.status !== 'OPEN') {
    throw new AppError(409, 'PURCHASE_CANCELLED', 'This goods-bought list was cancelled.');
  }
  const { rowCount } = await client.query(
    `SELECT 1 FROM stock_receipts WHERE purchase_id = $1 AND status IN ${statuses}`,
    [id],
  );
  if (rowCount) {
    throw new AppError(
      409,
      'PURCHASE_HAS_RECEIPTS',
      `Goods have been received against this list, so it can no longer be ${action}.`,
    );
  }
  return row;
}

/** Replaces an open list's details and lines while nothing has been received against it. */
export async function updatePurchase(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  input: PurchaseInput,
  actor: PublicUser,
): Promise<Purchase> {
  await withTransaction(pool, async (client) => {
    const current = await lockChangeable(client, scope, id, 'changed', ANY_RECEIPT);
    await checkInput(client, input);
    await client.query(
      `UPDATE purchases
       SET owner_organisation_id = $2, supplier_id = $3, supplier_invoice_number = $4,
           purchase_date = $5, notes = $6
       WHERE id = $1`,
      [
        id,
        input.ownerOrganisationId,
        input.supplierId,
        input.supplierInvoiceNumber,
        input.purchaseDate,
        input.notes,
      ],
    );
    await client.query('DELETE FROM purchase_lines WHERE purchase_id = $1', [id]);
    await writeLines(client, id, input.lines);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'purchase.updated',
      entityType: 'purchase',
      entityId: id,
      organisationId: input.ownerOrganisationId,
      details: { purchaseNumber: current.purchase_number, lines: input.lines.length },
    });
  });
  return getPurchase(pool, scope, id);
}

export async function cancelPurchase(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  reason: string,
  actor: PublicUser,
): Promise<Purchase> {
  await withTransaction(pool, async (client) => {
    const current = await lockChangeable(client, scope, id, 'cancelled', HOLDING);
    await client.query(
      `UPDATE purchases
       SET status = 'CANCELLED', cancelled_by = $2, cancelled_at = now(), cancel_reason = $3
       WHERE id = $1`,
      [id, actor.id, reason],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'purchase.cancelled',
      entityType: 'purchase',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: { purchaseNumber: current.purchase_number, reason },
    });
  });
  return getPurchase(pool, scope, id);
}

// ------------------------------------------------------------------ Supplier documents

/** Locks the list and checks it is open (documents are not added to a cancelled list). */
async function lockOpen(client: pg.PoolClient, scope: AccessScope, id: string, action: string) {
  const { rows } = await client.query<{
    status: PurchaseStatus;
    purchase_number: string;
    owner_organisation_id: string;
  }>(
    'SELECT status, purchase_number, owner_organisation_id FROM purchases WHERE id = $1 FOR UPDATE',
    [id],
  );
  const row = rows[0];
  if (!row || !canAccessOrganisation(scope, row.owner_organisation_id)) throw purchaseNotFound();
  if (row.status !== 'OPEN') {
    throw new AppError(
      409,
      'PURCHASE_CANCELLED',
      `This goods-bought list was cancelled, so its documents can no longer be ${action}.`,
    );
  }
  return row;
}

/**
 * Attaches a supplier document (PDF, JPEG or PNG, checked from its content) to an open list. It
 * waits for finance or an administrator to verify or reject it.
 */
export async function uploadPurchaseDocument(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  file: { filename: string; content: Buffer },
  actor: PublicUser,
  settings: { storageDir: string; maxBytes: number },
): Promise<Purchase> {
  const filename = cleanFilename(file.filename);
  if (file.content.length === 0) throw fieldError('file', 'The file is empty');
  if (file.content.length > settings.maxBytes) {
    throw new AppError(413, 'PAYLOAD_TOO_LARGE', 'The file is too large.');
  }
  const mimeType = detectDocumentType(file.content, filename);

  let storedKey: string | null = null;
  try {
    await withTransaction(pool, async (client) => {
      const current = await lockOpen(client, scope, id, 'added');
      const stored = await storeDocument(settings.storageDir, file.content);
      storedKey = stored.storageKey;
      await client.query(
        `INSERT INTO purchase_attachments
           (purchase_id, original_filename, storage_key, mime_type, size_bytes, sha256, uploaded_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [id, filename, stored.storageKey, mimeType, file.content.length, stored.sha256, actor.id],
      );
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'purchase.document_added',
        entityType: 'purchase',
        entityId: id,
        organisationId: current.owner_organisation_id,
        details: {
          purchaseNumber: current.purchase_number,
          filename,
          mimeType,
          sizeBytes: file.content.length,
        },
      });
    });
  } catch (error) {
    // Nothing was recorded, so the stored copy is not needed.
    if (storedKey) await unlink(join(settings.storageDir, storedKey)).catch(() => {});
    throw error;
  }
  return getPurchase(pool, scope, id);
}

/** Finance or an administrator verifies or rejects a document (a rejection needs a reason). */
export async function reviewPurchaseDocument(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  attachmentId: string,
  review: { status: 'VERIFIED' | 'REJECTED'; notes: string | null; documentTotal: string | null },
  actor: PublicUser,
): Promise<Purchase> {
  await withTransaction(pool, async (client) => {
    const current = await lockOpen(client, scope, id, 'reviewed');
    if (review.status === 'REJECTED' && !review.notes) {
      throw fieldError('notes', 'Say why the document is rejected');
    }
    const { rowCount } = await client.query(
      `UPDATE purchase_attachments
       SET verification_status = $3, review_notes = $4, document_total = $5::numeric,
           reviewed_by = $6, reviewed_at = now()
       WHERE id = $2 AND purchase_id = $1 AND verification_status = 'PENDING'`,
      [id, attachmentId, review.status, review.notes, review.documentTotal, actor.id],
    );
    if (!rowCount) {
      throw new AppError(
        409,
        'DOCUMENT_ALREADY_REVIEWED',
        'This document has already been reviewed, or does not belong to this list.',
      );
    }
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'purchase.document_reviewed',
      entityType: 'purchase',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: {
        purchaseNumber: current.purchase_number,
        attachmentId,
        status: review.status,
        notes: review.notes,
        documentTotal: review.documentTotal,
      },
    });
  });
  return getPurchase(pool, scope, id);
}

/** A document's content, for someone allowed to see its list. */
export async function readPurchaseDocument(
  db: Queryable,
  scope: AccessScope,
  id: string,
  attachmentId: string,
  storageDir: string,
): Promise<{ filename: string; mimeType: string; content: Buffer }> {
  await getPurchase(db, scope, id);
  const { rows } = await db.query<{
    original_filename: string;
    mime_type: string;
    storage_key: string;
  }>(
    `SELECT original_filename, mime_type, storage_key FROM purchase_attachments
     WHERE id = $1 AND purchase_id = $2`,
    [attachmentId, id],
  );
  const row = rows[0];
  if (!row) throw new AppError(404, 'DOCUMENT_NOT_FOUND', 'No document has that id.');
  return {
    filename: row.original_filename,
    mimeType: row.mime_type,
    content: await readDocument(storageDir, row.storage_key),
  };
}
