import { unlink } from 'node:fs/promises';
import { join } from 'node:path';
import type pg from 'pg';
import { withTransaction, type Queryable } from '../../database/transaction.js';
import { can } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { recordAudit } from '../audit/audit.js';
import type { PublicUser } from '../auth/roles.js';
import { canAccessOrganisation, type AccessScope } from '../organisations/access.js';
import { toBaseQuantity } from '../products/products.service.js';
import { insertMovement } from '../stock/ledger.js';
import {
  cleanFilename,
  detectDocumentType,
  readDocument,
  storeDocument,
} from './attachment-files.js';

// StockFlow Stage 4.4 and 4.5: goods-received notes (GRNs). See the migration
// 20261021110000000_goods-received-notes.sql for the statuses.

export type ReceiptStatus =
  'DRAFT' | 'PENDING_VERIFICATION' | 'VERIFIED' | 'REJECTED' | 'POSTED' | 'REVERSED';

export type DiscrepancyReason = 'shortage' | 'overage' | 'damaged' | 'rejected';

export interface ReceiptLineInput {
  productId: string;
  unitId: string;
  quantityPurchased: number;
  quantityReceived: number;
  /** Exact decimal string with up to 4 decimal places, in the receipt's currency. */
  unitCost: string;
  batchNumber: string | null;
  expiryDate: string | null;
  discrepancyReason: DiscrepancyReason | null;
  notes: string | null;
}

export interface ReceiptInput {
  /** Whose stock arrived: the Head Office or a subsidiary. Callers check the user's access. */
  ownerOrganisationId: string;
  warehouseId: string | null;
  supplierId: string | null;
  supplierInvoiceNumber: string | null;
  purchaseDate: string | null;
  receivedDate: string;
  notes: string | null;
  lines: ReceiptLineInput[];
}

interface Ref {
  id: string;
  code: string;
  name: string;
}

export interface ReceiptLine {
  id: string;
  lineNumber: number;
  product: { id: string; sku: string; description: string };
  unit: Ref;
  quantityPurchased: number;
  quantityReceived: number;
  /** quantityReceived in the product's base unit: what is added to stock. */
  baseQuantityReceived: number;
  unitCost: string;
  lineTotal: string;
  batchNumber: string | null;
  expiryDate: string | null;
  discrepancyReason: DiscrepancyReason | null;
  notes: string | null;
  batchId: string | null;
}

export interface ReceiptAttachment {
  id: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  uploadedBy: { id: string; fullName: string };
  uploadedAt: Date;
  verificationStatus: 'PENDING' | 'VERIFIED' | 'REJECTED';
  reviewedBy: { id: string; fullName: string } | null;
  reviewedAt: Date | null;
  reviewNotes: string | null;
  documentTotal: string | null;
}

export interface ReceiptSummary {
  id: string;
  grnNumber: string;
  status: ReceiptStatus;
  owner: Ref;
  warehouse: Ref;
  supplier: Ref | null;
  supplierInvoiceNumber: string | null;
  receivedDate: string;
  currency: string;
  total: string;
  lineCount: number;
  attachmentCount: number;
  /** True while the receipt's stock is counted (posted and not taken back). */
  stockAdded: boolean;
  flags: {
    /** Lines where what arrived differs from what was bought. */
    discrepancies: number;
    /** A document's total differs from the GRN total. */
    documentTotalMismatch: boolean;
    /** Documents not yet verified or rejected. */
    documentsPending: number;
  };
  createdAt: Date;
}

export interface Receipt extends ReceiptSummary {
  purchaseDate: string | null;
  notes: string | null;
  receivedBy: { id: string; fullName: string };
  submittedAt: Date | null;
  postedAt: Date | null;
  verifiedBy: { id: string; fullName: string } | null;
  verifiedAt: Date | null;
  verificationNotes: string | null;
  rejectedReason: string | null;
  reversedAt: Date | null;
  reversalReason: string | null;
  noDocumentReason: string | null;
  lines: ReceiptLine[];
  attachments: ReceiptAttachment[];
}

const SUMMARY_SELECT = `
  SELECT r.id, r.grn_number, r.status, r.supplier_invoice_number, r.received_date, r.currency,
         r.created_at, r.posted_at,
         json_build_object('id', o.id, 'code', o.code, 'name', o.name) AS owner,
         json_build_object('id', w.id, 'code', w.code, 'name', w.name) AS warehouse,
         CASE WHEN s.id IS NULL THEN NULL
              ELSE json_build_object('id', s.id, 'code', s.code, 'name', s.name) END AS supplier,
         COALESCE((SELECT sum(l.line_total) FROM stock_receipt_lines l WHERE l.receipt_id = r.id),
                  0)::numeric(14, 2)::text AS total,
         (SELECT count(*)::int FROM stock_receipt_lines l WHERE l.receipt_id = r.id) AS line_count,
         (SELECT count(*)::int FROM stock_receipt_lines l
          WHERE l.receipt_id = r.id AND l.discrepancy_reason IS NOT NULL) AS discrepancies,
         (SELECT count(*)::int FROM stock_receipt_attachments a WHERE a.receipt_id = r.id)
           AS attachment_count,
         (SELECT count(*)::int FROM stock_receipt_attachments a
          WHERE a.receipt_id = r.id AND a.verification_status = 'PENDING') AS documents_pending,
         EXISTS (SELECT 1 FROM stock_receipt_attachments a
                 WHERE a.receipt_id = r.id AND a.verification_status <> 'REJECTED'
                   AND a.document_total IS NOT NULL
                   AND a.document_total <> COALESCE((SELECT sum(l.line_total)
                                                     FROM stock_receipt_lines l
                                                     WHERE l.receipt_id = r.id), 0))
           AS document_total_mismatch
  FROM stock_receipts r
  JOIN organisations o ON o.id = r.owner_organisation_id
  JOIN warehouses w ON w.id = r.warehouse_id
  LEFT JOIN suppliers s ON s.id = r.supplier_id`;

interface SummaryRow {
  id: string;
  grn_number: string;
  status: ReceiptStatus;
  supplier_invoice_number: string | null;
  received_date: string;
  currency: string;
  created_at: Date;
  posted_at: Date | null;
  owner: Ref;
  warehouse: Ref;
  supplier: Ref | null;
  total: string;
  line_count: number;
  discrepancies: number;
  attachment_count: number;
  documents_pending: number;
  document_total_mismatch: boolean;
}

function toSummary(row: SummaryRow): ReceiptSummary {
  return {
    id: row.id,
    grnNumber: row.grn_number,
    status: row.status,
    owner: row.owner,
    warehouse: row.warehouse,
    supplier: row.supplier,
    supplierInvoiceNumber: row.supplier_invoice_number,
    receivedDate: row.received_date,
    currency: row.currency,
    total: row.total,
    lineCount: row.line_count,
    attachmentCount: row.attachment_count,
    stockAdded: row.posted_at !== null && row.status !== 'REJECTED' && row.status !== 'REVERSED',
    flags: {
      discrepancies: row.discrepancies,
      documentTotalMismatch: row.document_total_mismatch,
      documentsPending: row.documents_pending,
    },
    createdAt: row.created_at,
  };
}

const receiptNotFound = () =>
  new AppError(404, 'RECEIPT_NOT_FOUND', 'No goods-received note has that id.');

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

function wrongStatus(status: ReceiptStatus, action: string): AppError {
  return new AppError(
    409,
    'RECEIPT_WRONG_STATUS',
    `This goods-received note is ${status.toLowerCase().replace('_', ' ')}, so it cannot be ${action}.`,
  );
}

export interface ReceiptFilter {
  status?: ReceiptStatus | undefined;
  /** Only one organisation's receipts (must be within the user's access). */
  ownerOrganisationId?: string | undefined;
  from?: string | undefined;
  to?: string | undefined;
  limit: number;
  offset: number;
}

/** Receipts the user may see (the Head Office: all; a subsidiary: its own), newest first. */
export async function listReceipts(
  db: Queryable,
  scope: AccessScope,
  filter: ReceiptFilter,
): Promise<{ receipts: ReceiptSummary[]; total: number }> {
  const conditions: string[] = [];
  const params: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    params.push(value);
    conditions.push(condition.replaceAll('?', `$${params.length}`));
  };
  if (!scope.allOrganisations) add('r.owner_organisation_id = ?', scope.organisationId);
  if (filter.ownerOrganisationId) add('r.owner_organisation_id = ?', filter.ownerOrganisationId);
  if (filter.status) add('r.status = ?', filter.status);
  if (filter.from) add('r.received_date >= ?', filter.from);
  if (filter.to) add('r.received_date <= ?', filter.to);
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const { rows } = await db.query<SummaryRow & { full_count: number }>(
    `SELECT *, count(*) OVER ()::int AS full_count FROM (${SUMMARY_SELECT} ${where}) receipts
     ORDER BY received_date DESC, created_at DESC
     LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
    [...params, filter.limit, filter.offset],
  );
  return { receipts: rows.map(toSummary), total: rows[0]?.full_count ?? 0 };
}

/** One receipt with its lines and documents, or 404 (also outside the user's access). */
export async function getReceipt(db: Queryable, scope: AccessScope, id: string): Promise<Receipt> {
  const { rows } = await db.query<
    SummaryRow & {
      owner_organisation_id: string;
      purchase_date: string | null;
      notes: string | null;
      received_by: { id: string; fullName: string };
      submitted_at: Date | null;
      verified_by: { id: string; fullName: string } | null;
      verified_at: Date | null;
      verification_notes: string | null;
      rejected_reason: string | null;
      reversed_at: Date | null;
      reversal_reason: string | null;
      no_document_reason: string | null;
    }
  >(
    `SELECT summary.*, r.owner_organisation_id, r.purchase_date, r.notes, r.submitted_at,
            r.verified_at, r.verification_notes, r.rejected_reason, r.reversed_at,
            r.reversal_reason, r.no_document_reason,
            json_build_object('id', rb.id, 'fullName', rb.full_name) AS received_by,
            CASE WHEN vb.id IS NULL THEN NULL
                 ELSE json_build_object('id', vb.id, 'fullName', vb.full_name) END AS verified_by
     FROM (${SUMMARY_SELECT} WHERE r.id = $1) summary
     JOIN stock_receipts r ON r.id = summary.id
     JOIN users rb ON rb.id = r.received_by
     LEFT JOIN users vb ON vb.id = r.verified_by`,
    [id],
  );
  const row = rows[0];
  if (!row || !canAccessOrganisation(scope, row.owner_organisation_id)) throw receiptNotFound();

  const { rows: lines } = await db.query<{
    id: string;
    line_number: number;
    product: { id: string; sku: string; description: string };
    unit: Ref;
    quantity_purchased: number;
    quantity_received: number;
    base_quantity_received: number;
    unit_cost: string;
    line_total: string;
    batch_number: string | null;
    expiry_date: string | null;
    discrepancy_reason: DiscrepancyReason | null;
    notes: string | null;
    batch_id: string | null;
  }>(
    `SELECT l.id, l.line_number,
            json_build_object('id', p.id, 'sku', p.sku,
                              'description', p.name || ' — ' || p.flavour || ' — ' || p.size)
              AS product,
            json_build_object('id', u.id, 'code', u.code, 'name', u.name) AS unit,
            l.quantity_purchased, l.quantity_received, l.base_quantity_received,
            l.unit_cost::text, l.line_total::text, l.batch_number, l.expiry_date,
            l.discrepancy_reason, l.notes, l.batch_id
     FROM stock_receipt_lines l
     JOIN products p ON p.id = l.product_id
     JOIN units u ON u.id = l.unit_id
     WHERE l.receipt_id = $1
     ORDER BY l.line_number`,
    [id],
  );
  const { rows: attachments } = await db.query<{
    id: string;
    original_filename: string;
    mime_type: string;
    size_bytes: number;
    uploaded_by: { id: string; fullName: string };
    uploaded_at: Date;
    verification_status: 'PENDING' | 'VERIFIED' | 'REJECTED';
    reviewed_by: { id: string; fullName: string } | null;
    reviewed_at: Date | null;
    review_notes: string | null;
    document_total: string | null;
  }>(
    `SELECT a.id, a.original_filename, a.mime_type, a.size_bytes, a.uploaded_at,
            a.verification_status, a.reviewed_at, a.review_notes, a.document_total::text,
            json_build_object('id', ub.id, 'fullName', ub.full_name) AS uploaded_by,
            CASE WHEN rv.id IS NULL THEN NULL
                 ELSE json_build_object('id', rv.id, 'fullName', rv.full_name) END AS reviewed_by
     FROM stock_receipt_attachments a
     JOIN users ub ON ub.id = a.uploaded_by
     LEFT JOIN users rv ON rv.id = a.reviewed_by
     WHERE a.receipt_id = $1
     ORDER BY a.uploaded_at, a.id`,
    [id],
  );

  return {
    ...toSummary(row),
    purchaseDate: row.purchase_date,
    notes: row.notes,
    receivedBy: row.received_by,
    submittedAt: row.submitted_at,
    postedAt: row.posted_at,
    verifiedBy: row.verified_by,
    verifiedAt: row.verified_at,
    verificationNotes: row.verification_notes,
    rejectedReason: row.rejected_reason,
    reversedAt: row.reversed_at,
    reversalReason: row.reversal_reason,
    noDocumentReason: row.no_document_reason,
    lines: lines.map((line) => ({
      id: line.id,
      lineNumber: line.line_number,
      product: line.product,
      unit: line.unit,
      quantityPurchased: line.quantity_purchased,
      quantityReceived: line.quantity_received,
      baseQuantityReceived: line.base_quantity_received,
      unitCost: line.unit_cost,
      lineTotal: line.line_total,
      batchNumber: line.batch_number,
      expiryDate: line.expiry_date,
      discrepancyReason: line.discrepancy_reason,
      notes: line.notes,
      batchId: line.batch_id,
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

const ALL: AccessScope = { allOrganisations: true, organisationId: '' };

/** Locks the receipt row and returns its status, owner and posting state. */
async function lockReceipt(client: pg.PoolClient, scope: AccessScope, id: string) {
  const { rows } = await client.query<{
    status: ReceiptStatus;
    owner_organisation_id: string;
    warehouse_id: string;
    received_date: string;
    grn_number: string;
    posted_at: Date | null;
    received_by: string;
    no_document_reason: string | null;
  }>(
    `SELECT status, owner_organisation_id, warehouse_id, received_date, grn_number, posted_at,
            received_by, no_document_reason
     FROM stock_receipts WHERE id = $1 FOR UPDATE`,
    [id],
  );
  const row = rows[0];
  if (!row || !canAccessOrganisation(scope, row.owner_organisation_id)) throw receiptNotFound();
  return row;
}

/** Checks the header's references: an active owner, warehouse and supplier. */
async function checkHeader(client: pg.PoolClient, input: ReceiptInput): Promise<string> {
  const { rows } = await client.query<{ active: boolean }>(
    'SELECT is_active AS active FROM organisations WHERE id = $1',
    [input.ownerOrganisationId],
  );
  if (!rows[0]?.active) throw fieldError('ownerOrganisationId', 'Choose an active organisation');
  const { rows: warehouses } = await client.query<{ id: string }>(
    'SELECT id FROM warehouses WHERE id = COALESCE($1, default_warehouse_id()) AND is_active',
    [input.warehouseId],
  );
  const warehouseId = warehouses[0]?.id;
  if (!warehouseId) throw fieldError('warehouseId', 'Choose an active warehouse');
  if (input.supplierId) {
    const { rowCount } = await client.query('SELECT 1 FROM suppliers WHERE id = $1 AND is_active', [
      input.supplierId,
    ]);
    if (!rowCount) throw fieldError('supplierId', 'Choose an active supplier');
  }
  return warehouseId;
}

/** Saves the lines (in a draft), converting each received quantity to the base unit. */
async function writeLines(
  client: pg.PoolClient,
  receiptId: string,
  lines: ReceiptLineInput[],
): Promise<void> {
  for (const [index, line] of lines.entries()) {
    const { rows } = await client.query<{ is_active: boolean }>(
      'SELECT is_active FROM products WHERE id = $1',
      [line.productId],
    );
    if (!rows[0]) throw fieldError(`lines.${index}.productId`, 'No product has that id');
    if (!rows[0].is_active)
      throw fieldError(`lines.${index}.productId`, 'This product is inactive');
    const base = await toBaseQuantity(
      client,
      line.productId,
      line.unitId,
      line.quantityReceived,
      `lines.${index}.unitId`,
    );
    // The line total is worked out by the database, exactly (numeric), never in floating point.
    await client.query(
      `INSERT INTO stock_receipt_lines
         (receipt_id, line_number, product_id, unit_id, quantity_purchased, quantity_received,
          base_quantity_received, unit_cost, line_total, batch_number, expiry_date,
          discrepancy_reason, notes)
       VALUES ($1, $2, $3, $4, $5::int, $6, $7, $8::numeric, round($5::int * $8::numeric, 2), $9, $10, $11, $12)`,
      [
        receiptId,
        index + 1,
        line.productId,
        line.unitId,
        line.quantityPurchased,
        line.quantityReceived,
        base,
        line.unitCost,
        line.batchNumber,
        line.expiryDate,
        line.discrepancyReason,
        line.notes,
      ],
    );
  }
}

/** Starts a goods-received note (a draft: no stock changes yet). */
export async function createReceipt(
  pool: pg.Pool,
  input: ReceiptInput,
  actor: PublicUser,
  currency: string,
): Promise<Receipt> {
  const id = await withTransaction(pool, async (client) => {
    const warehouseId = await checkHeader(client, input);
    const { rows } = await client.query<{ id: string; grn_number: string }>(
      `INSERT INTO stock_receipts
         (owner_organisation_id, warehouse_id, supplier_id, supplier_invoice_number, purchase_date,
          received_date, currency, notes, received_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
       RETURNING id, grn_number`,
      [
        input.ownerOrganisationId,
        warehouseId,
        input.supplierId,
        input.supplierInvoiceNumber,
        input.purchaseDate,
        input.receivedDate,
        currency,
        input.notes,
        actor.id,
      ],
    );
    const created = rows[0] as { id: string; grn_number: string };
    await writeLines(client, created.id, input.lines);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.created',
      entityType: 'receipt',
      entityId: created.id,
      organisationId: input.ownerOrganisationId,
      details: { grnNumber: created.grn_number, lines: input.lines.length },
    });
    return created.id;
  });
  return getReceipt(pool, ALL, id);
}

/** Replaces a draft's details and lines. */
export async function updateDraft(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  input: ReceiptInput,
  actor: PublicUser,
): Promise<Receipt> {
  await withTransaction(pool, async (client) => {
    const current = await lockReceipt(client, scope, id);
    if (current.status !== 'DRAFT') throw wrongStatus(current.status, 'changed');
    const warehouseId = await checkHeader(client, input);
    await client.query(
      `UPDATE stock_receipts
       SET owner_organisation_id = $2, warehouse_id = $3, supplier_id = $4,
           supplier_invoice_number = $5, purchase_date = $6, received_date = $7, notes = $8
       WHERE id = $1`,
      [
        id,
        input.ownerOrganisationId,
        warehouseId,
        input.supplierId,
        input.supplierInvoiceNumber,
        input.purchaseDate,
        input.receivedDate,
        input.notes,
      ],
    );
    await client.query('DELETE FROM stock_receipt_lines WHERE receipt_id = $1', [id]);
    await writeLines(client, id, input.lines);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.updated',
      entityType: 'receipt',
      entityId: id,
      organisationId: input.ownerOrganisationId,
      details: { grnNumber: current.grn_number, lines: input.lines.length },
    });
  });
  return getReceipt(pool, scope, id);
}

/**
 * Adds the receipt's stock: one delivery batch and one ledger entry per line, owned by the
 * receipt's organisation (a subsidiary's goods never become the Head Office's), all in the
 * caller's transaction. Product rows are locked first, like every stock change.
 */
async function postStock(
  client: pg.PoolClient,
  id: string,
  receipt: Awaited<ReturnType<typeof lockReceipt>>,
  actor: PublicUser,
): Promise<void> {
  const { rows: lines } = await client.query<{
    id: string;
    product_id: string;
    unit_id: string;
    base_unit_id: string;
    quantity_received: number;
    base_quantity_received: number;
    batch_number: string | null;
    expiry_date: string | null;
  }>(
    `SELECT l.id, l.product_id, l.unit_id, p.base_unit_id, l.quantity_received,
            l.base_quantity_received, l.batch_number, l.expiry_date
     FROM stock_receipt_lines l JOIN products p ON p.id = l.product_id
     WHERE l.receipt_id = $1
     ORDER BY l.product_id, l.line_number`,
    [id],
  );
  await client.query('SELECT 1 FROM products WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE', [
    lines.map((line) => line.product_id),
  ]);
  const { rows: header } = await client.query<{ reference: string | null }>(
    `SELECT COALESCE(r.supplier_invoice_number, s.name) AS reference
     FROM stock_receipts r LEFT JOIN suppliers s ON s.id = r.supplier_id WHERE r.id = $1`,
    [id],
  );
  const supplierReference = header[0]?.reference?.slice(0, 120) ?? null;

  for (const line of lines) {
    if (line.base_quantity_received === 0) continue;
    const { rows: batches } = await client.query<{ id: string }>(
      `INSERT INTO stock_batches (product_id, quantity_received, received_date, batch_number,
                                  expiry_date, supplier_reference, received_by,
                                  owner_organisation_id, warehouse_id, receipt_line_id)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
       RETURNING id`,
      [
        line.product_id,
        line.base_quantity_received,
        receipt.received_date,
        line.batch_number,
        line.expiry_date,
        supplierReference,
        receipt.received_by,
        receipt.owner_organisation_id,
        receipt.warehouse_id,
        line.id,
      ],
    );
    const batchId = (batches[0] as { id: string }).id;
    await insertMovement(client, {
      productId: line.product_id,
      ownerOrganisationId: receipt.owner_organisation_id,
      warehouseId: receipt.warehouse_id,
      batchId,
      type: 'receipt',
      quantityDelta: line.base_quantity_received,
      businessDate: receipt.received_date,
      createdBy: actor.id,
      reference: receipt.grn_number,
      entered:
        line.unit_id === line.base_unit_id
          ? null
          : { unitId: line.unit_id, quantity: line.quantity_received },
      relatedDocument: { type: 'stock_receipt', id },
    });
    await client.query('UPDATE stock_receipt_lines SET batch_id = $2 WHERE id = $1', [
      line.id,
      batchId,
    ]);
  }
  await client.query('UPDATE stock_receipts SET posted_by = $2, posted_at = now() WHERE id = $1', [
    id,
    actor.id,
  ]);
}

/**
 * Takes a receipt's stock back out (rejection after posting, or reversal): one reversal entry
 * per batch, pointing at the receipt entry it cancels. Refused if any of the delivery has
 * already left (dispatched, damaged, ...): that needs a stock adjustment instead.
 */
async function takeStockBack(
  client: pg.PoolClient,
  id: string,
  reason: string,
  actor: PublicUser,
  today: string,
  grnNumber: string,
): Promise<void> {
  const { rows: movements } = await client.query<{
    id: string;
    product_id: string;
    owner_organisation_id: string;
    warehouse_id: string;
    batch_id: string;
    quantity_delta: number;
  }>(
    `SELECT m.id, m.product_id, m.owner_organisation_id, m.warehouse_id, m.batch_id,
            m.quantity_delta
     FROM stock_movements m
     WHERE m.related_document_type = 'stock_receipt' AND m.related_document_id = $1
       AND m.movement_type = 'receipt'
     ORDER BY m.product_id`,
    [id],
  );
  await client.query('SELECT 1 FROM products WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE', [
    movements.map((m) => m.product_id),
  ]);
  for (const movement of movements) {
    try {
      await insertMovement(client, {
        productId: movement.product_id,
        ownerOrganisationId: movement.owner_organisation_id,
        warehouseId: movement.warehouse_id,
        batchId: movement.batch_id,
        type: 'reversal',
        quantityDelta: -movement.quantity_delta,
        businessDate: today,
        createdBy: actor.id,
        reference: grnNumber,
        reason,
        reversesMovementId: movement.id,
        relatedDocument: { type: 'stock_receipt', id },
      });
    } catch (error) {
      if ((error as AppError).code === 'INSUFFICIENT_STOCK') {
        throw new AppError(
          409,
          'RECEIPT_STOCK_USED',
          'Some of this delivery has already been dispatched or used, so it cannot be taken back ' +
            'automatically. Correct the stock with an adjustment instead.',
        );
      }
      throw error;
    }
  }
}

/**
 * Submits a draft for verification. It needs a supplier and at least one document, unless
 * documents are not required or a user allowed to (receipt.no_document) gives a reason. When
 * stock is available before verification (decision D3), it is added now.
 */
export async function submitReceipt(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  options: { noDocumentReason: string | null },
  actor: PublicUser,
  settings: { stockAvailableBeforeVerification: boolean; documentRequired: boolean },
): Promise<Receipt> {
  await withTransaction(pool, async (client) => {
    const current = await lockReceipt(client, scope, id);
    if (current.status !== 'DRAFT') throw wrongStatus(current.status, 'submitted');
    const { rows } = await client.query<{ lines: number; documents: number }>(
      `SELECT (SELECT count(*)::int FROM stock_receipt_lines l WHERE l.receipt_id = r.id) AS lines,
              (SELECT count(*)::int FROM stock_receipt_attachments a
               WHERE a.receipt_id = r.id AND a.verification_status <> 'REJECTED') AS documents
       FROM stock_receipts r WHERE r.id = $1`,
      [id],
    );
    // No supplier is needed (the owner's choice, 2026-10-21); the documents show who sold it.
    const facts = rows[0] as { lines: number; documents: number };
    if (facts.lines === 0) throw fieldError('lines', 'Add at least one product');

    let noDocumentReason: string | null = null;
    if (settings.documentRequired && facts.documents === 0) {
      if (!options.noDocumentReason) {
        throw new AppError(
          409,
          'DOCUMENT_REQUIRED',
          'Attach the supplier invoice or delivery note before submitting.',
        );
      }
      if (!can(actor, 'receipt.no_document')) {
        throw new AppError(
          403,
          'FORBIDDEN',
          'Only an authorised user can submit a receipt without a document.',
        );
      }
      noDocumentReason = options.noDocumentReason;
    }

    await client.query(
      `UPDATE stock_receipts
       SET status = 'PENDING_VERIFICATION', submitted_by = $2, submitted_at = now(),
           no_document_reason = $3
       WHERE id = $1`,
      [id, actor.id, noDocumentReason],
    );
    if (noDocumentReason) {
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'receipt.no_document',
        entityType: 'receipt',
        entityId: id,
        organisationId: current.owner_organisation_id,
        details: { grnNumber: current.grn_number, reason: noDocumentReason },
      });
    }
    if (settings.stockAvailableBeforeVerification) {
      await postStock(client, id, current, actor);
    }
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.submitted',
      entityType: 'receipt',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: {
        grnNumber: current.grn_number,
        stockAdded: settings.stockAvailableBeforeVerification,
      },
    });
  });
  return getReceipt(pool, scope, id);
}

/**
 * The reviewer accepts the receipt: every document has been verified or rejected (at least
 * one verified, unless it was submitted without one). If its stock is already in, it is now
 * POSTED; otherwise VERIFIED and waiting to be posted.
 */
export async function verifyReceipt(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  notes: string | null,
  actor: PublicUser,
): Promise<Receipt> {
  await withTransaction(pool, async (client) => {
    const current = await lockReceipt(client, scope, id);
    if (current.status !== 'PENDING_VERIFICATION') throw wrongStatus(current.status, 'verified');
    const { rows } = await client.query<{ pending: number; verified: number }>(
      `SELECT count(*) FILTER (WHERE verification_status = 'PENDING')::int AS pending,
              count(*) FILTER (WHERE verification_status = 'VERIFIED')::int AS verified
       FROM stock_receipt_attachments WHERE receipt_id = $1`,
      [id],
    );
    const documents = rows[0] as { pending: number; verified: number };
    if (documents.pending > 0) {
      throw new AppError(
        409,
        'DOCUMENTS_NOT_REVIEWED',
        'Verify or reject every document before verifying the receipt.',
      );
    }
    if (documents.verified === 0 && !current.no_document_reason) {
      throw new AppError(
        409,
        'NO_VERIFIED_DOCUMENT',
        'No document has been verified. Ask for a replacement document, or reject the receipt.',
      );
    }
    const next: ReceiptStatus = current.posted_at ? 'POSTED' : 'VERIFIED';
    await client.query(
      `UPDATE stock_receipts
       SET status = $2, verified_by = $3, verified_at = now(), verification_notes = $4
       WHERE id = $1`,
      [id, next, actor.id, notes],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.verified',
      entityType: 'receipt',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: { grnNumber: current.grn_number, status: next, notes },
    });
  });
  return getReceipt(pool, scope, id);
}

/** Adds a verified receipt's stock (when stock waits for verification). */
export async function postReceipt(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  actor: PublicUser,
): Promise<Receipt> {
  await withTransaction(pool, async (client) => {
    const current = await lockReceipt(client, scope, id);
    if (current.status !== 'VERIFIED') throw wrongStatus(current.status, 'posted');
    await postStock(client, id, current, actor);
    await client.query(`UPDATE stock_receipts SET status = 'POSTED' WHERE id = $1`, [id]);
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.posted',
      entityType: 'receipt',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: { grnNumber: current.grn_number },
    });
  });
  return getReceipt(pool, scope, id);
}

/** The reviewer refuses the receipt; any stock it added is taken back out. */
export async function rejectReceipt(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  reason: string,
  actor: PublicUser,
  today: string,
): Promise<Receipt> {
  await withTransaction(pool, async (client) => {
    const current = await lockReceipt(client, scope, id);
    if (current.status !== 'PENDING_VERIFICATION') throw wrongStatus(current.status, 'rejected');
    if (current.posted_at) {
      await takeStockBack(client, id, reason, actor, today, current.grn_number);
    }
    await client.query(
      `UPDATE stock_receipts SET status = 'REJECTED', rejected_reason = $2,
              verified_by = $3, verified_at = now()
       WHERE id = $1`,
      [id, reason, actor.id],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.rejected',
      entityType: 'receipt',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: {
        grnNumber: current.grn_number,
        reason,
        stockTakenBack: current.posted_at !== null,
      },
    });
  });
  return getReceipt(pool, scope, id);
}

/** Cancels a posted receipt with a reason: its stock is taken back out, the history kept. */
export async function reverseReceipt(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  reason: string,
  actor: PublicUser,
  today: string,
): Promise<Receipt> {
  await withTransaction(pool, async (client) => {
    const current = await lockReceipt(client, scope, id);
    if (current.status !== 'POSTED') throw wrongStatus(current.status, 'reversed');
    await takeStockBack(client, id, reason, actor, today, current.grn_number);
    await client.query(
      `UPDATE stock_receipts SET status = 'REVERSED', reversal_reason = $2, reversed_by = $3,
              reversed_at = now()
       WHERE id = $1`,
      [id, reason, actor.id],
    );
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.reversed',
      entityType: 'receipt',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: { grnNumber: current.grn_number, reason },
    });
  });
  return getReceipt(pool, scope, id);
}

// ---------------------------------------------------------------- Documents

/**
 * Adds a document to a draft or a receipt waiting for verification (for example a replacement
 * for a rejected one). The content decides the type, not the name. Uploading a document does
 * not confirm that the goods arrived.
 */
export async function uploadAttachment(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  file: { filename: string; content: Buffer },
  actor: PublicUser,
  settings: { storageDir: string; maxBytes: number },
): Promise<Receipt> {
  const filename = cleanFilename(file.filename);
  if (file.content.length === 0) throw fieldError('file', 'The file is empty');
  if (file.content.length > settings.maxBytes) {
    throw new AppError(413, 'PAYLOAD_TOO_LARGE', 'The file is too large.');
  }
  const mimeType = detectDocumentType(file.content, filename);

  let storedKey: string | null = null;
  try {
    await withTransaction(pool, async (client) => {
      const current = await lockReceipt(client, scope, id);
      if (current.status !== 'DRAFT' && current.status !== 'PENDING_VERIFICATION') {
        throw wrongStatus(current.status, 'given more documents');
      }
      const stored = await storeDocument(settings.storageDir, file.content);
      storedKey = stored.storageKey;
      await client.query(
        `INSERT INTO stock_receipt_attachments
           (receipt_id, original_filename, storage_key, mime_type, size_bytes, sha256, uploaded_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [id, filename, stored.storageKey, mimeType, file.content.length, stored.sha256, actor.id],
      );
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'receipt.document_added',
        entityType: 'receipt',
        entityId: id,
        organisationId: current.owner_organisation_id,
        details: {
          grnNumber: current.grn_number,
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
  return getReceipt(pool, scope, id);
}

/** The reviewer verifies or rejects one document (rejection needs a reason). */
export async function reviewAttachment(
  pool: pg.Pool,
  scope: AccessScope,
  id: string,
  attachmentId: string,
  review: { status: 'VERIFIED' | 'REJECTED'; notes: string | null; documentTotal: string | null },
  actor: PublicUser,
): Promise<Receipt> {
  await withTransaction(pool, async (client) => {
    const current = await lockReceipt(client, scope, id);
    if (current.status !== 'PENDING_VERIFICATION' && current.status !== 'DRAFT') {
      throw wrongStatus(current.status, 'reviewed');
    }
    if (review.status === 'REJECTED' && !review.notes) {
      throw fieldError('notes', 'Say why the document is rejected');
    }
    const { rowCount } = await client.query(
      `UPDATE stock_receipt_attachments
       SET verification_status = $3, review_notes = $4, document_total = $5::numeric,
           reviewed_by = $6, reviewed_at = now()
       WHERE id = $2 AND receipt_id = $1 AND verification_status = 'PENDING'`,
      [id, attachmentId, review.status, review.notes, review.documentTotal, actor.id],
    );
    if (!rowCount) {
      throw new AppError(
        409,
        'DOCUMENT_ALREADY_REVIEWED',
        'This document has already been reviewed, or does not belong to this receipt.',
      );
    }
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'receipt.document_reviewed',
      entityType: 'receipt',
      entityId: id,
      organisationId: current.owner_organisation_id,
      details: {
        grnNumber: current.grn_number,
        attachmentId,
        status: review.status,
        notes: review.notes,
        documentTotal: review.documentTotal,
      },
    });
  });
  return getReceipt(pool, scope, id);
}

/** A document's content, for someone allowed to see its receipt. */
export async function readAttachment(
  db: Queryable,
  scope: AccessScope,
  id: string,
  attachmentId: string,
  storageDir: string,
): Promise<{ filename: string; mimeType: string; content: Buffer }> {
  await getReceipt(db, scope, id);
  const { rows } = await db.query<{
    original_filename: string;
    mime_type: string;
    storage_key: string;
  }>(
    `SELECT original_filename, mime_type, storage_key FROM stock_receipt_attachments
     WHERE id = $1 AND receipt_id = $2`,
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
