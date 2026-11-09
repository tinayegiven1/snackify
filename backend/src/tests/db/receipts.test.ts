import { readdir } from 'node:fs/promises';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../../app.js';
import { storeDocument } from '../../modules/receipts/attachment-files.js';
import { businessToday } from '../../utils/dates.js';
import { WhatsAppError, type WhatsAppDocument } from '../../modules/whatsapp/whatsapp.js';
import { testConfig } from '../test-config.js';
import {
  auditEntries,
  createDbTestApp,
  createTestPools,
  createTestProduct,
  createTestSubsidiary,
  createTestUser,
  headOfficeId,
  resetDatabase,
  signIn,
} from './db-test-helpers.js';

// StockFlow Stage 4.4 and 4.5: goods-received notes and their stock. Supplier documents moved
// to goods bought (2026-11-09); documents already on older notes stay readable and reviewable.
const pools = createTestPools();
const PASSWORD = '4826';
let app: Express;
const tokens: Record<string, string> = {};
let hq: string;
let subA: string;
let subB: string;
let supplierId: string;
let bbq: string;
let cheese: string;
const units: Record<string, string> = {};

const T = (days = 0) => {
  const date = new Date(`${businessToday('Africa/Harare')}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
};

const auth = (who: string) => ({ Authorization: `Bearer ${tokens[who]}` });
const as = (who: string, target = () => app) => ({
  get: (path: string) => request(target()).get(path).set(auth(who)),
  post: (path: string, body: object = {}) => request(target()).post(path).set(auth(who)).send(body),
  put: (path: string, body: object) => request(target()).put(path).set(auth(who)).send(body),
});

// Small but genuine file headers.
const FILES = {
  pdf: Buffer.from('%PDF-1.4\n% supplier invoice INV-1042\n%%EOF\n'),
  png: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48]),
};

/** Tries to attach a document to a note: refused since documents moved to goods bought. */
const upload = (who: string, id: string, filename: string, content: Buffer) =>
  request(app)
    .post(`/api/v1/receipts/${id}/attachments?filename=${encodeURIComponent(filename)}`)
    .set(auth(who))
    .set('Content-Type', 'application/octet-stream')
    .send(content);

/**
 * A document on a note from before documents moved to goods bought: stored as the app used to
 * store it, and recorded directly in the database. Returns its id.
 */
async function oldDocument(
  receiptId: string,
  filename: string,
  content: Buffer,
  mimeType: 'application/pdf' | 'image/jpeg' | 'image/png',
): Promise<string> {
  const stored = await storeDocument(testConfig.attachments.storageDir, content);
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO stock_receipt_attachments
       (receipt_id, original_filename, storage_key, mime_type, size_bytes, sha256, uploaded_by)
     VALUES ($1, $2, $3, $4, $5, $6, (SELECT id FROM users WHERE username = 'storekeeper'))
     RETURNING id`,
    [receiptId, filename, stored.storageKey, mimeType, content.length, stored.sha256],
  );
  return (rows[0] as { id: string }).id;
}

const binary = (res: request.Response, done: (error: Error | null, body: Buffer) => void) => {
  const chunks: Buffer[] = [];
  res.on('data', (chunk: Buffer) => chunks.push(chunk));
  res.on('end', () => done(null, Buffer.concat(chunks)));
};
const download = (who: string | null, path: string) => {
  const call = request(app).get(path).buffer(true).parse(binary);
  return who ? call.set(auth(who)) : call;
};

interface Line {
  productId?: string;
  unitId?: string;
  quantityPurchased?: number;
  quantityReceived?: number;
  unitCost?: string;
  batchNumber?: string | null;
  expiryDate?: string | null;
  discrepancyReason?: string | null;
}

const line = (overrides: Line = {}) => ({
  productId: bbq,
  unitId: units.pack,
  quantityPurchased: 100,
  quantityReceived: 100,
  unitCost: '0.4250',
  batchNumber: 'L2026-10A',
  expiryDate: T(90),
  ...overrides,
});

const draftBody = (overrides: object = {}) => ({
  supplierId,
  supplierInvoiceNumber: 'INV-1042',
  purchaseDate: T(-1),
  receivedDate: T(0),
  lines: [line()],
  ...overrides,
});

/** Creates a draft as the storekeeper and returns it. */
async function createDraft(overrides: object = {}) {
  const response = await as('storekeeper').post('/api/v1/receipts', draftBody(overrides));
  expect(response.status, JSON.stringify(response.body)).toBe(201);
  return response.body.receipt;
}

/** A draft, submitted (its stock is added at once: decision D3). */
async function submitted(overrides: object = {}) {
  const draft = await createDraft(overrides);
  const response = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
  expect(response.status, JSON.stringify(response.body)).toBe(200);
  return response.body.receipt;
}

/** Stock owned by an organisation, from the balances table. */
async function owned(productId: string, organisationId: string): Promise<number> {
  const { rows } = await pools.owner.query<{ total: number }>(
    `SELECT COALESCE(sum(quantity_on_hand), 0)::int AS total FROM stock_balances
     WHERE product_id = $1 AND owner_organisation_id = $2`,
    [productId, organisationId],
  );
  return rows[0]?.total ?? NaN;
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  app = createDbTestApp(pools.app);
  hq = await headOfficeId(pools.owner);
  subA = await createTestSubsidiary(pools.owner, 'SUB-A', 'Avondale Shop');
  subB = await createTestSubsidiary(pools.owner, 'SUB-B', 'Borrowdale Shop');
  for (const role of ['admin', 'storekeeper', 'accounts', 'salesperson'] as const) {
    await createTestUser(pools.app, { username: role, role, password: PASSWORD });
    tokens[role] = await signIn(app, role, PASSWORD);
  }
  for (const [username, organisationId] of [
    ['manager-a', subA],
    ['manager-b', subB],
  ] as const) {
    await createTestUser(pools.app, {
      username,
      password: PASSWORD,
      roleCodes: ['subsidiary_manager'],
      organisationId,
    });
    tokens[username] = await signIn(app, username, PASSWORD);
  }
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO suppliers (code, name) VALUES ('SUP-01', 'Harare Potato Co-op') RETURNING id`,
  );
  supplierId = (rows[0] as { id: string }).id;
  bbq = await createTestProduct(pools.owner);
  cheese = await createTestProduct(pools.owner, { sku: 'PC-CH-S', flavour: 'Cheese' });
  const { rows: unitRows } = await pools.owner.query<{ id: string; code: string }>(
    'SELECT id, code FROM units',
  );
  for (const unit of unitRows) units[unit.code] = unit.id;
});
afterAll(() => pools.close());

describe('a Head Office receipt', () => {
  it('goes from draft to posted, adding the stock, with no supplier document', async () => {
    const draft = await createDraft({
      lines: [line(), line({ productId: cheese, quantityPurchased: 3, quantityReceived: 3 })],
    });
    expect(draft).toMatchObject({
      grnNumber: expect.stringMatching(/^GRN\d{6}$/),
      status: 'DRAFT',
      owner: { id: hq, code: 'HQ' },
      warehouse: { code: 'HQ-MAIN' },
      supplier: { code: 'SUP-01' },
      currency: 'USD',
      // Exact decimals: 100 x 0.4250 = 42.50 and 3 x 0.4250 = 1.275, rounded to 1.28.
      total: '43.78',
      stockAdded: false,
      receivedBy: { fullName: 'Test storekeeper' },
    });
    expect(draft.lines.map((l: { lineTotal: string }) => l.lineTotal)).toEqual(['42.50', '1.28']);
    expect(await owned(bbq, hq)).toBe(0);

    // Supplier documents belong to goods bought: the note submits without one.
    const submit = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(submit.status, JSON.stringify(submit.body)).toBe(200);
    expect(submit.body.receipt).toMatchObject({
      status: 'PENDING_VERIFICATION',
      stockAdded: true,
      noDocumentReason: null,
      attachments: [],
      flags: { discrepancies: 0, documentTotalMismatch: false, documentsPending: 0 },
    });
    // Available at once (decision D3), in the Head Office's balance, one batch per line.
    expect(await owned(bbq, hq)).toBe(100);
    expect(await owned(cheese, hq)).toBe(3);
    const { rows: movements } = await pools.owner.query(
      `SELECT m.movement_type, m.quantity_delta, m.reference, m.related_document_type,
              m.related_document_id, b.receipt_line_id, b.batch_number, b.owner_organisation_id
       FROM stock_movements m JOIN stock_batches b ON b.id = m.batch_id
       WHERE m.product_id = $1`,
      [bbq],
    );
    expect(movements).toEqual([
      {
        movement_type: 'receipt',
        quantity_delta: 100,
        reference: draft.grnNumber,
        related_document_type: 'stock_receipt',
        related_document_id: draft.id,
        receipt_line_id: draft.lines[0].id,
        batch_number: 'L2026-10A',
        owner_organisation_id: hq,
      },
    ]);

    // Verification: the warehouse cannot verify its own receipt; finance approves it.
    expect((await as('storekeeper').post(`/api/v1/receipts/${draft.id}/verify`)).status).toBe(403);
    const verified = await as('accounts').post(`/api/v1/receipts/${draft.id}/verify`, {
      notes: 'Matches the invoice',
    });
    expect(verified.status).toBe(200);
    expect(verified.body.receipt).toMatchObject({
      status: 'POSTED',
      verifiedBy: { fullName: 'Test accounts' },
      verificationNotes: 'Matches the invoice',
    });
    expect(await owned(bbq, hq)).toBe(100);

    for (const action of ['receipt.created', 'receipt.submitted', 'receipt.verified']) {
      expect(await auditEntries(pools.owner, action), action).toHaveLength(1);
    }
    for (const action of ['receipt.document_added', 'receipt.document_reviewed']) {
      expect(await auditEntries(pools.owner, action), action).toHaveLength(0);
    }

    const pdf = await download('salesperson', `/api/v1/receipts/${draft.id}/pdf`);
    expect(pdf.status).toBe(200);
    expect(pdf.headers['content-type']).toBe('application/pdf');
    expect(pdf.headers['content-disposition']).toBe(`inline; filename="${draft.grnNumber}.pdf"`);
    expect((pdf.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
  });

  it("still prints an older note's photographed documents on the GRN PDF", async () => {
    // A real 1x1 PNG (a camera photo), a PDF (not printed) and a damaged PNG (noted instead),
    // attached before documents moved to goods bought.
    const photo = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'base64',
    );
    const draft = await createDraft();
    await oldDocument(draft.id, 'photo-1.png', photo, 'image/png');
    await oldDocument(draft.id, 'invoice.pdf', FILES.pdf, 'application/pdf');
    await oldDocument(draft.id, 'damaged.png', FILES.png, 'image/png');

    const pdf = await download('storekeeper', `/api/v1/receipts/${draft.id}/pdf`);
    expect(pdf.status).toBe(200);
    const text = (pdf.body as Buffer).toString('latin1');
    // The note, then one page per picture; only the good photo is embedded as an image.
    const pages = (pdf: string) => pdf.match(new RegExp('/Type /Page[^s]', 'g'))?.length ?? 0;
    expect(pages(text)).toBe(3);
    // Only the good photo is embedded: its picture plus its transparency mask.
    expect(text.split('/Subtype /Image')).toHaveLength(3);

    const plain = await createDraft();
    const plainPdf = await download('storekeeper', `/api/v1/receipts/${plain.id}/pdf`);
    expect(pages((plainPdf.body as Buffer).toString('latin1'))).toBe(1);
  });

  it('checks the details before saving anything', async () => {
    const post = (body: object) => as('storekeeper').post('/api/v1/receipts', draftBody(body));
    const fields = async (body: object) =>
      (await post(body)).body.error.details.map((d: { field: string }) => d.field);

    expect(await fields({ receivedDate: T(1) })).toEqual(['receivedDate']);
    expect(await fields({ purchaseDate: T(1) })).toEqual(['purchaseDate']);
    expect(await fields({ lines: [line({ expiryDate: T(-1) })] })).toEqual(['lines.0.expiryDate']);
    // A difference between bought and received needs a reason, and only then.
    expect(await fields({ lines: [line({ quantityReceived: 96 })] })).toEqual([
      'lines.0.discrepancyReason',
    ]);
    expect(await fields({ lines: [line({ discrepancyReason: 'damaged' })] })).toEqual([
      'lines.0.discrepancyReason',
    ]);
    expect(await fields({ lines: [line({ unitCost: '0.12345' })] })).toEqual(['lines.0.unitCost']);
    expect(await fields({ lines: [line({ quantityPurchased: 0, quantityReceived: 0 })] })).toEqual([
      'lines.0.quantityReceived',
    ]);

    const unknownSupplier = await post({ supplierId: cheese });
    expect(unknownSupplier.body.error.details).toEqual([
      { field: 'supplierId', message: 'Choose an active supplier' },
    ]);
    expect((await as('salesperson').post('/api/v1/receipts', draftBody())).status).toBe(403);
    expect((await pools.owner.query('SELECT 1 FROM stock_receipts')).rowCount).toBe(0);

    // No supplier is needed, to save or to submit.
    const draft = await createDraft({ supplierId: null });
    const submit = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(submit.status).toBe(200);
    expect(submit.body.receipt).toMatchObject({ status: 'PENDING_VERIFICATION', supplier: null });
  });

  it('records discrepancies', async () => {
    const receipt = await submitted({
      lines: [line({ quantityReceived: 96, discrepancyReason: 'shortage' })],
    });
    expect(receipt.flags.discrepancies).toBe(1);
    expect(receipt.lines[0]).toMatchObject({ baseQuantityReceived: 96, lineTotal: '42.50' });
    expect(await owned(bbq, hq)).toBe(96);
  });
});

describe('a subsidiary-owned receipt', () => {
  it('adds stock to the subsidiary only, never to the Head Office', async () => {
    const receipt = await submitted({
      organisationId: subA,
      lines: [line({ quantityPurchased: 60, quantityReceived: 60 })],
    });
    expect(receipt.owner).toMatchObject({ id: subA, code: 'SUB-A' });
    expect(await owned(bbq, subA)).toBe(60);
    expect(await owned(bbq, hq)).toBe(0);
    const hqBalance = await as('storekeeper').get('/api/v1/stock/balance');
    expect(hqBalance.body.balances[0].quantityOnHand).toBe(0);
    const subBalance = await as('manager-a').get('/api/v1/stock/balance');
    expect(subBalance.body.balances[0].quantityOnHand).toBe(60);

    // The subsidiary sees its own receipt and (older) documents; another subsidiary sees nothing.
    const documentId = await oldDocument(receipt.id, 'invoice.pdf', FILES.pdf, 'application/pdf');
    expect((await as('manager-a').get('/api/v1/receipts')).body.total).toBe(1);
    expect((await as('manager-a').get(`/api/v1/receipts/${receipt.id}`)).status).toBe(200);
    expect((await as('manager-b').get('/api/v1/receipts')).body.total).toBe(0);
    expect((await as('manager-b').get(`/api/v1/receipts/${receipt.id}`)).status).toBe(404);
    expect((await as('manager-b').get(`/api/v1/receipts/${receipt.id}/pdf`)).status).toBe(404);
    const path = `/api/v1/receipts/${receipt.id}/attachments/${documentId}`;
    expect((await download('manager-b', path)).status).toBe(404);
    expect((await download('manager-a', path)).status).toBe(200);
    expect((await as('manager-b').get(`/api/v1/receipts?organisationId=${subA}`)).status).toBe(404);

    // Subsidiary staff do not receive goods (no stock.receive), even for themselves.
    expect((await as('manager-a').post('/api/v1/receipts', draftBody())).status).toBe(403);
  });
});

describe('supplier documents on goods-received notes', () => {
  it('are refused: they are attached to goods bought now', async () => {
    const dir = testConfig.attachments.storageDir;
    const before = await readdir(dir).catch(() => []);
    const draft = await createDraft();

    const refused = await upload('storekeeper', draft.id, 'invoice.pdf', FILES.pdf);
    expect(refused.status).toBe(409);
    expect(refused.body.error).toMatchObject({
      code: 'DOCUMENTS_ON_GOODS_BOUGHT',
      message:
        'Supplier documents are attached to the goods-bought list now, not to the goods-received note.',
    });
    // Administrators too, and on a submitted note.
    expect((await upload('admin', draft.id, 'invoice.pdf', FILES.pdf)).body.error.code).toBe(
      'DOCUMENTS_ON_GOODS_BOUGHT',
    );
    const receipt = await submitted();
    expect((await upload('storekeeper', receipt.id, 'invoice.pdf', FILES.pdf)).status).toBe(409);

    // Without stock.receive the answer is still "not allowed"; an unknown note is not found.
    expect((await upload('salesperson', draft.id, 'invoice.pdf', FILES.pdf)).status).toBe(403);
    expect((await upload('manager-b', draft.id, 'invoice.pdf', FILES.pdf)).status).toBe(403);
    const unknown = '00000000-0000-4000-8000-000000000000';
    expect((await upload('storekeeper', unknown, 'invoice.pdf', FILES.pdf)).status).toBe(404);

    // Nothing was stored or recorded.
    expect((await pools.owner.query('SELECT 1 FROM stock_receipt_attachments')).rowCount).toBe(0);
    expect((await readdir(dir).catch(() => [])).length).toBe(before.length);
    expect(await auditEntries(pools.owner, 'receipt.document_added')).toHaveLength(0);
  });

  it('are not needed: a note submits and is approved by finance without one', async () => {
    const draft = await createDraft();
    // Older apps may still send a reason for having no document: it is ignored.
    const submit = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`, {
      noDocumentReason: 'Supplier will email the invoice',
    });
    expect(submit.status, JSON.stringify(submit.body)).toBe(200);
    expect(submit.body.receipt).toMatchObject({
      status: 'PENDING_VERIFICATION',
      noDocumentReason: null,
      attachments: [],
    });
    expect(await auditEntries(pools.owner, 'receipt.no_document')).toHaveLength(0);

    // Only finance (or an administrator) approves, and never the person who entered it.
    expect((await as('storekeeper').post(`/api/v1/receipts/${draft.id}/verify`)).status).toBe(403);
    const verified = await as('accounts').post(`/api/v1/receipts/${draft.id}/verify`);
    expect(verified.status, JSON.stringify(verified.body)).toBe(200);
    expect(verified.body.receipt).toMatchObject({
      status: 'POSTED',
      verifiedBy: { fullName: 'Test accounts' },
      attachments: [],
      flags: { documentsPending: 0, documentTotalMismatch: false },
    });
    expect(await owned(bbq, hq)).toBe(100);
  });

  it('already on an older note are still listed, downloaded and reviewed', async () => {
    const receipt = await submitted();
    const first = await oldDocument(receipt.id, 'invoice.pdf', FILES.pdf, 'application/pdf');
    const second = await oldDocument(receipt.id, 'delivery note.png', FILES.png, 'image/png');

    const listed = (await as('accounts').get(`/api/v1/receipts/${receipt.id}`)).body.receipt;
    expect(listed.attachments).toMatchObject([
      {
        id: first,
        filename: 'invoice.pdf',
        mimeType: 'application/pdf',
        verificationStatus: 'PENDING',
      },
      { id: second, filename: 'delivery note.png', mimeType: 'image/png' },
    ]);
    expect(listed.flags.documentsPending).toBe(2);

    // Downloaded only through the API, as a download with the checked type.
    const path = `/api/v1/receipts/${receipt.id}/attachments/${first}`;
    const file = await download('salesperson', path);
    expect(file.status).toBe(200);
    expect(file.headers['content-type']).toBe('application/pdf');
    expect(file.headers['content-disposition']).toBe('attachment; filename="invoice.pdf"');
    expect(file.headers['x-content-type-options']).toBe('nosniff');
    expect(Buffer.compare(file.body as Buffer, FILES.pdf)).toBe(0);
    expect((await download(null, path)).status).toBe(401);
    expect(
      (await download('salesperson', `/api/v1/receipts/${receipt.id}/attachments/${receipt.id}`))
        .status,
    ).toBe(404);

    // Finance still reviews them; the warehouse does not.
    const review = (who: string, attachmentId: string, body: object) =>
      as(who).post(`/api/v1/receipts/${receipt.id}/attachments/${attachmentId}/review`, body);
    expect((await review('storekeeper', first, { status: 'VERIFIED' })).status).toBe(403);
    const noReason = await review('accounts', first, { status: 'REJECTED' });
    expect(noReason.status).toBe(400);
    expect(noReason.body.error.details).toEqual([
      { field: 'notes', message: 'Say why the document is rejected' },
    ]);
    const reviewed = await review('accounts', first, {
      status: 'VERIFIED',
      documentTotal: '40.80',
    });
    expect(reviewed.status).toBe(200);
    expect(reviewed.body.receipt.attachments[0]).toMatchObject({
      verificationStatus: 'VERIFIED',
      documentTotal: '40.80',
      reviewedBy: { fullName: 'Test accounts' },
    });
    // The note is for 42.50, the document says 40.80.
    expect(reviewed.body.receipt.flags).toMatchObject({
      documentTotalMismatch: true,
      documentsPending: 1,
    });
    expect((await review('accounts', first, { status: 'VERIFIED' })).body.error.code).toBe(
      'DOCUMENT_ALREADY_REVIEWED',
    );
    expect(await auditEntries(pools.owner, 'receipt.document_reviewed')).toHaveLength(1);

    // Verifying the note verifies the document still waiting.
    const verified = await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`);
    expect(verified.status, JSON.stringify(verified.body)).toBe(200);
    expect(verified.body.receipt.status).toBe('POSTED');
    expect(verified.body.receipt.attachments).toMatchObject([
      { id: first, verificationStatus: 'VERIFIED' },
      { id: second, verificationStatus: 'VERIFIED', reviewedBy: { fullName: 'Test accounts' } },
    ]);
    expect(verified.body.receipt.flags.documentsPending).toBe(0);

    // Documents are never deleted by the app.
    await expect(pools.app.query('DELETE FROM stock_receipt_attachments')).rejects.toThrow();
  });
});

describe('submitted receipts', () => {
  it('cannot be changed, even directly in the database', async () => {
    const receipt = await submitted();
    const edit = await as('storekeeper').put(`/api/v1/receipts/${receipt.id}`, draftBody());
    expect(edit.status).toBe(409);
    expect(edit.body.error.code).toBe('RECEIPT_WRONG_STATUS');
    for (const sql of [
      'UPDATE stock_receipt_lines SET quantity_received = 1000, base_quantity_received = 1000',
      'DELETE FROM stock_receipt_lines',
      `UPDATE stock_receipts SET supplier_invoice_number = 'CHANGED'`,
      `UPDATE stock_receipts SET status = 'DRAFT'`,
      'DELETE FROM stock_receipts',
    ]) {
      await expect(pools.app.query(sql), sql).rejects.toThrow();
    }
    expect(await owned(bbq, hq)).toBe(100);
  });

  it('are reversed with a reason, taking the stock back out', async () => {
    const receipt = await submitted();
    expect((await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`)).status).toBe(200);

    const reverse = (who: string, reason = 'Delivered to the wrong company') =>
      as(who).post(`/api/v1/receipts/${receipt.id}/reverse`, { reason });
    expect((await reverse('storekeeper')).status).toBe(403);
    expect((await as('admin').post(`/api/v1/receipts/${receipt.id}/reverse`, {})).status).toBe(400);

    // Some of the delivery has been written off: it cannot simply be taken back.
    await as('admin').post('/api/v1/stock/adjustments', {
      productId: bbq,
      type: 'damage',
      quantityDelta: -10,
      reason: 'Crushed in the store',
    });
    const used = await reverse('admin');
    expect(used.status).toBe(409);
    expect(used.body.error.code).toBe('RECEIPT_STOCK_USED');
    expect(await owned(bbq, hq)).toBe(90);

    await as('admin').post('/api/v1/stock/adjustments', {
      productId: bbq,
      type: 'adjustment',
      quantityDelta: 10,
      reason: 'Damage was a counting mistake',
      batchId: receipt.lines[0].batchId, // back into the delivery's own batch
    });
    const reversed = await reverse('admin');
    expect(reversed.status).toBe(200);
    expect(reversed.body.receipt).toMatchObject({
      status: 'REVERSED',
      reversalReason: 'Delivered to the wrong company',
      stockAdded: false,
    });
    expect(await owned(bbq, hq)).toBe(0);
    const { rows } = await pools.owner.query(
      `SELECT quantity_delta, reverses_movement_id IS NOT NULL AS reverses FROM stock_movements
       WHERE movement_type = 'reversal'`,
    );
    expect(rows).toEqual([{ quantity_delta: -100, reverses: true }]);
    expect((await reverse('admin')).body.error.code).toBe('RECEIPT_WRONG_STATUS');
  });

  it('when rejected, have their stock taken back out', async () => {
    const receipt = await submitted();
    expect(await owned(bbq, hq)).toBe(100);
    const rejected = await as('accounts').post(`/api/v1/receipts/${receipt.id}/reject`, {
      reason: 'Not our order',
    });
    expect(rejected.status).toBe(200);
    expect(rejected.body.receipt).toMatchObject({
      status: 'REJECTED',
      rejectedReason: 'Not our order',
      stockAdded: false,
    });
    expect(await owned(bbq, hq)).toBe(0);
    const [entry] = await auditEntries(pools.owner, 'receipt.rejected');
    expect(entry?.details).toMatchObject({ stockTakenBack: true });
  });
});

describe('posting', () => {
  it('is all or nothing: a failure part-way leaves no stock and the receipt a draft', async () => {
    const draft = await createDraft({
      lines: [
        line({ quantityPurchased: 5, quantityReceived: 5 }),
        line({ quantityPurchased: 13, quantityReceived: 13 }),
      ],
    });
    // Make the second line's batch fail, after the first line's stock has been written.
    await pools.owner.query(`
      CREATE FUNCTION test_fail_posting() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.quantity_received = 13 THEN RAISE EXCEPTION 'simulated failure'; END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER test_fail_posting BEFORE INSERT ON stock_batches
        FOR EACH ROW EXECUTE FUNCTION test_fail_posting();`);
    try {
      const submit = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
      expect(submit.status).toBe(500);
    } finally {
      await pools.owner.query(`
        DROP TRIGGER test_fail_posting ON stock_batches;
        DROP FUNCTION test_fail_posting();`);
    }

    expect(await owned(bbq, hq)).toBe(0);
    for (const table of ['stock_movements', 'stock_batches']) {
      expect((await pools.owner.query(`SELECT 1 FROM ${table}`)).rowCount, table).toBe(0);
    }
    const after = (await as('storekeeper').get(`/api/v1/receipts/${draft.id}`)).body.receipt;
    expect(after).toMatchObject({ status: 'DRAFT', submittedAt: null, stockAdded: false });
    expect(await auditEntries(pools.owner, 'receipt.submitted')).toHaveLength(0);

    // Once the cause is gone, the same receipt posts normally.
    const retry = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(retry.status).toBe(200);
    expect(await owned(bbq, hq)).toBe(18);
  });

  it('converts each line to the base unit, keeping what was entered', async () => {
    await as('admin').put(`/api/v1/products/${bbq}/conversions`, {
      conversions: [{ unitId: units.carton, baseQuantity: 24 }],
    });
    const receipt = await submitted({
      lines: [
        line({
          unitId: units.carton,
          quantityPurchased: 3,
          quantityReceived: 3,
          unitCost: '10.20',
        }),
      ],
    });
    expect(receipt.lines[0]).toMatchObject({
      unit: { code: 'carton' },
      quantityReceived: 3,
      baseQuantityReceived: 72,
      lineTotal: '30.60',
    });
    expect(await owned(bbq, hq)).toBe(72);
    const { rows } = await pools.owner.query(
      'SELECT quantity_delta, entered_quantity, unit_id FROM stock_movements',
    );
    expect(rows).toEqual([{ quantity_delta: 72, entered_quantity: 3, unit_id: units.carton }]);

    const noConversion = await as('storekeeper').post(
      '/api/v1/receipts',
      draftBody({
        lines: [line({ unitId: units.case, quantityPurchased: 1, quantityReceived: 1 })],
      }),
    );
    expect(noConversion.body.error.details).toEqual([
      { field: 'lines.0.unitId', message: 'This product has no conversion for that unit' },
    ]);
  });

  it('can wait for verification when the business chooses so', async () => {
    const strict = createApp(
      {
        ...testConfig,
        receipts: { stockAvailableBeforeVerification: false },
      },
      { db: pools.app, checkDatabase: async () => true },
    );
    const onStrict = (who: string) => as(who, () => strict);
    const draft = (await onStrict('storekeeper').post('/api/v1/receipts', draftBody())).body
      .receipt;
    const submit = await onStrict('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(submit.body.receipt).toMatchObject({
      status: 'PENDING_VERIFICATION',
      stockAdded: false,
    });
    expect(await owned(bbq, hq)).toBe(0);

    const verified = await onStrict('accounts').post(`/api/v1/receipts/${draft.id}/verify`);
    expect(verified.body.receipt).toMatchObject({ status: 'VERIFIED', stockAdded: false });
    expect(await owned(bbq, hq)).toBe(0);

    const posted = await onStrict('storekeeper').post(`/api/v1/receipts/${draft.id}/post`);
    expect(posted.body.receipt).toMatchObject({ status: 'POSTED', stockAdded: true });
    expect(await owned(bbq, hq)).toBe(100);
    expect(await auditEntries(pools.owner, 'receipt.posted')).toHaveLength(1);
  });
});

describe('approval by a second person', () => {
  it('lets nobody approve or reject a note they entered themselves', async () => {
    // An administrator holds every Head Office role, so could otherwise do both.
    const draft = await as('admin').post('/api/v1/receipts', draftBody());
    expect(draft.status).toBe(201);
    const id = draft.body.receipt.id as string;
    expect((await as('admin').post(`/api/v1/receipts/${id}/submit`)).status).toBe(200);

    for (const action of ['verify', 'reject']) {
      const own = await as('admin').post(`/api/v1/receipts/${id}/${action}`, {
        reason: 'Wrong supplier',
      });
      expect(own.status, action).toBe(409);
      expect(own.body.error.code).toBe('SAME_PERSON');
    }
    const other = await as('accounts').post(`/api/v1/receipts/${id}/verify`);
    expect(other.status).toBe(200);
    expect(other.body.receipt.verifiedBy.fullName).toBe('Test accounts');
  });
});

describe('sending approved notes on WhatsApp', () => {
  let sent: WhatsAppDocument[];
  let failNext: string | null;

  beforeEach(async () => {
    sent = [];
    failNext = null;
    app = createApp(testConfig, {
      db: pools.app,
      checkDatabase: async () => true,
      sendWhatsApp: async (document) => {
        if (failNext) {
          const reason = failNext;
          failNext = null;
          throw new WhatsAppError(reason);
        }
        sent.push(document);
        return { messageId: `wamid.${sent.length}` };
      },
    });
    const patched = await request(app)
      .patch(`/api/v1/organisations/${subA}`)
      .set(auth('admin'))
      .send({ whatsappNumber: '+263 77 123 4567' });
    expect(patched.status, JSON.stringify(patched.body)).toBe(200);
    expect(patched.body.organisation.whatsappNumber).toBe('+263 77 123 4567');
  });

  it("sends the PDF to the subsidiary's WhatsApp number when the note is approved", async () => {
    const receipt = await submitted({ organisationId: subA });
    const approved = await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`);
    expect(approved.status).toBe(200);

    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({
      to: '+263 77 123 4567',
      filename: `${receipt.grnNumber}.pdf`,
      bodyValues: [receipt.grnNumber, 'Avondale Shop', expect.any(String)],
    });
    expect(sent[0]?.content.subarray(0, 5).toString()).toBe('%PDF-');
    expect(approved.body.receipt.whatsappMessages).toEqual([
      {
        status: 'SENT',
        toNumber: '+263 77 123 4567',
        detail: null,
        sentBy: { id: expect.any(String), fullName: 'Test accounts' },
        createdAt: expect.any(String),
      },
    ]);
  });

  it("does not send notes for the Head Office's own stock", async () => {
    const receipt = await submitted();
    const approved = await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`);
    expect(approved.status).toBe(200);
    expect(sent).toEqual([]);
    expect(approved.body.receipt.whatsappMessages).toEqual([]);
  });

  it('records a failure with the reason, and can send again', async () => {
    const receipt = await submitted({ organisationId: subA });
    failNext = 'WhatsApp refused the message (code 131026): Message undeliverable';
    const approved = await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`);
    // The approval stands even though sending failed.
    expect(approved.status).toBe(200);
    expect(approved.body.receipt.status).toBe('POSTED');
    expect(approved.body.receipt.whatsappMessages).toMatchObject([
      { status: 'FAILED', detail: failNextWas('Message undeliverable') },
    ]);

    const again = await as('accounts').post(`/api/v1/receipts/${receipt.id}/whatsapp`);
    expect(again.status).toBe(200);
    expect(again.body.receipt.whatsappMessages.map((m: { status: string }) => m.status)).toEqual([
      'SENT',
      'FAILED',
    ]);
    expect(sent).toHaveLength(1);

    // Only finance sends; only approved notes are sent.
    expect((await as('storekeeper').post(`/api/v1/receipts/${receipt.id}/whatsapp`)).status).toBe(
      403,
    );
    const pending = await submitted({ organisationId: subA });
    const early = await as('accounts').post(`/api/v1/receipts/${pending.id}/whatsapp`);
    expect(early.status).toBe(409);
    expect(early.body.error.code).toBe('RECEIPT_NOT_APPROVED');
  });

  it('says why nothing was sent: no number, or WhatsApp not set up', async () => {
    const noNumber = await submitted({ organisationId: subB });
    const approved = await as('accounts').post(`/api/v1/receipts/${noNumber.id}/verify`);
    expect(approved.body.receipt.whatsappMessages).toMatchObject([
      {
        status: 'SKIPPED',
        toNumber: null,
        detail:
          'Borrowdale Shop has no WhatsApp number. Add one under Organisations, then send again.',
      },
    ]);

    app = createDbTestApp(pools.app); // no sender: WhatsApp is not configured
    const notSetUp = await submitted({ organisationId: subA });
    const verified = await as('accounts').post(`/api/v1/receipts/${notSetUp.id}/verify`);
    expect(verified.body.receipt.whatsappMessages).toMatchObject([
      { status: 'SKIPPED', detail: 'WhatsApp sending is not set up on the server yet.' },
    ]);
    expect(sent).toEqual([]);
  });
});

/** Matches a stored failure that mentions [text]. */
function failNextWas(text: string) {
  return expect.stringContaining(text);
}
