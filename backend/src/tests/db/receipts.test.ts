import { readdir } from 'node:fs/promises';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../../app.js';
import { businessToday } from '../../utils/dates.js';
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

// StockFlow Stage 4.4 and 4.5: goods-received notes, their documents and their stock.
const pools = createTestPools();
const PASSWORD = 'correct horse battery';
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

// Small but genuine file headers: what the server checks.
const FILES = {
  pdf: Buffer.from('%PDF-1.4\n% supplier invoice INV-1042\n%%EOF\n'),
  png: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48]),
  jpeg: Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0]),
  exe: Buffer.from('MZ\x90\x00\x03\x00\x00\x00 This program cannot be run in DOS mode', 'latin1'),
};

const upload = (who: string, id: string, filename: string, content: Buffer) =>
  request(app)
    .post(`/api/v1/receipts/${id}/attachments?filename=${encodeURIComponent(filename)}`)
    .set(auth(who))
    .set('Content-Type', 'application/octet-stream')
    .send(content);

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

/** A draft with a supplier document, submitted (its stock is added at once: decision D3). */
async function submitted(overrides: object = {}) {
  const draft = await createDraft(overrides);
  expect((await upload('storekeeper', draft.id, 'invoice.pdf', FILES.pdf)).status).toBe(201);
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
  it('goes from draft to posted, adding the stock with its documents checked', async () => {
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

    // A supplier document is required before submitting.
    const noDocument = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(noDocument.status).toBe(409);
    expect(noDocument.body.error.code).toBe('DOCUMENT_REQUIRED');

    const uploaded = await upload('storekeeper', draft.id, 'invoice.pdf', FILES.pdf);
    expect(uploaded.status).toBe(201);
    expect(uploaded.body.receipt.attachments).toMatchObject([
      { filename: 'invoice.pdf', mimeType: 'application/pdf', verificationStatus: 'PENDING' },
    ]);

    const submit = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(submit.status).toBe(200);
    expect(submit.body.receipt).toMatchObject({
      status: 'PENDING_VERIFICATION',
      stockAdded: true,
      flags: { discrepancies: 0, documentTotalMismatch: false, documentsPending: 1 },
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

    // Verification: the warehouse cannot verify its own receipt; finance reviews each document.
    expect((await as('storekeeper').post(`/api/v1/receipts/${draft.id}/verify`)).status).toBe(403);
    const early = await as('accounts').post(`/api/v1/receipts/${draft.id}/verify`);
    expect(early.body.error.code).toBe('DOCUMENTS_NOT_REVIEWED');
    const attachmentId = uploaded.body.receipt.attachments[0].id;
    const reviewed = await as('accounts').post(
      `/api/v1/receipts/${draft.id}/attachments/${attachmentId}/review`,
      { status: 'VERIFIED', documentTotal: '43.78' },
    );
    expect(reviewed.status).toBe(200);
    expect(reviewed.body.receipt.flags).toMatchObject({
      documentTotalMismatch: false,
      documentsPending: 0,
    });
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

    for (const action of [
      'receipt.created',
      'receipt.document_added',
      'receipt.submitted',
      'receipt.document_reviewed',
      'receipt.verified',
    ]) {
      expect(await auditEntries(pools.owner, action), action).toHaveLength(1);
    }

    const pdf = await download('salesperson', `/api/v1/receipts/${draft.id}/pdf`);
    expect(pdf.status).toBe(200);
    expect(pdf.headers['content-type']).toBe('application/pdf');
    expect(pdf.headers['content-disposition']).toBe(`inline; filename="${draft.grnNumber}.pdf"`);
    expect((pdf.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
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

    // A draft may be saved without a supplier, but not submitted.
    const draft = await createDraft({ supplierId: null });
    await upload('storekeeper', draft.id, 'invoice.pdf', FILES.pdf);
    const submit = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(submit.body.error.details).toEqual([
      { field: 'supplierId', message: 'Choose the supplier before submitting' },
    ]);
  });

  it('records discrepancies and a document total that does not match', async () => {
    const receipt = await submitted({
      lines: [line({ quantityReceived: 96, discrepancyReason: 'shortage' })],
    });
    expect(receipt.flags.discrepancies).toBe(1);
    expect(receipt.lines[0]).toMatchObject({ baseQuantityReceived: 96, lineTotal: '42.50' });
    expect(await owned(bbq, hq)).toBe(96);

    const reviewed = await as('accounts').post(
      `/api/v1/receipts/${receipt.id}/attachments/${receipt.attachments[0].id}/review`,
      { status: 'VERIFIED', documentTotal: '40.80' },
    );
    expect(reviewed.body.receipt.flags.documentTotalMismatch).toBe(true);
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

    // The subsidiary sees its own receipt and documents; another subsidiary sees nothing.
    expect((await as('manager-a').get('/api/v1/receipts')).body.total).toBe(1);
    expect((await as('manager-a').get(`/api/v1/receipts/${receipt.id}`)).status).toBe(200);
    expect((await as('manager-b').get('/api/v1/receipts')).body.total).toBe(0);
    expect((await as('manager-b').get(`/api/v1/receipts/${receipt.id}`)).status).toBe(404);
    expect((await as('manager-b').get(`/api/v1/receipts/${receipt.id}/pdf`)).status).toBe(404);
    const path = `/api/v1/receipts/${receipt.id}/attachments/${receipt.attachments[0].id}`;
    expect((await download('manager-b', path)).status).toBe(404);
    expect((await download('manager-a', path)).status).toBe(200);
    expect((await as('manager-b').get(`/api/v1/receipts?organisationId=${subA}`)).status).toBe(404);

    // Subsidiary staff do not receive goods (no stock.receive), even for themselves.
    expect((await as('manager-a').post('/api/v1/receipts', draftBody())).status).toBe(403);
  });
});

describe('receipt documents', () => {
  it('accept several PDF, JPEG and PNG files, recognised by their content', async () => {
    const draft = await createDraft();
    const dir = testConfig.attachments.storageDir;
    for (const [name, content] of [
      ['invoice.pdf', FILES.pdf],
      ['delivery note.PNG', FILES.png],
      ['../../photo.jpeg', FILES.jpeg],
    ] as const) {
      expect((await upload('storekeeper', draft.id, name, content)).status).toBe(201);
    }
    const before = (await readdir(dir)).length;

    // A program renamed "invoice.pdf", a PDF claiming to be a photo, empty and oversized files.
    const exe = await upload('storekeeper', draft.id, 'invoice.pdf', FILES.exe);
    expect(exe.status).toBe(415);
    expect(exe.body.error.code).toBe('UNSUPPORTED_DOCUMENT');
    expect((await upload('storekeeper', draft.id, 'photo.png', FILES.pdf)).status).toBe(415);
    expect((await upload('storekeeper', draft.id, 'invoice.exe', FILES.pdf)).status).toBe(415);
    expect((await upload('storekeeper', draft.id, 'empty.pdf', Buffer.alloc(0))).status).toBe(400);
    const huge = Buffer.concat([FILES.pdf, Buffer.alloc(testConfig.attachments.maxBytes)]);
    expect((await upload('storekeeper', draft.id, 'huge.pdf', huge)).status).toBe(413);
    expect((await upload('salesperson', draft.id, 'invoice.pdf', FILES.pdf)).status).toBe(403);
    expect((await readdir(dir)).length).toBe(before);

    const receipt = (await as('storekeeper').get(`/api/v1/receipts/${draft.id}`)).body.receipt;
    expect(
      receipt.attachments.map((a: { filename: string; mimeType: string }) => [
        a.filename,
        a.mimeType,
      ]),
    ).toEqual([
      ['invoice.pdf', 'application/pdf'],
      ['delivery note.PNG', 'image/png'],
      ['photo.jpeg', 'image/jpeg'],
    ]);

    // Stored under random names, outside the web app; downloaded only through the API.
    const { rows } = await pools.owner.query<{ storage_key: string; sha256: string }>(
      'SELECT storage_key, sha256 FROM stock_receipt_attachments ORDER BY uploaded_at',
    );
    expect(rows.every((row) => /^[a-f0-9]{64}$/.test(row.storage_key))).toBe(true);
    const path = `/api/v1/receipts/${draft.id}/attachments/${receipt.attachments[0].id}`;
    const file = await download('salesperson', path);
    expect(file.status).toBe(200);
    expect(file.headers['content-type']).toBe('application/pdf');
    expect(file.headers['content-disposition']).toBe('attachment; filename="invoice.pdf"');
    expect(file.headers['x-content-type-options']).toBe('nosniff');
    expect(Buffer.compare(file.body as Buffer, FILES.pdf)).toBe(0);
    expect((await download(null, path)).status).toBe(401);
    expect(
      (await download('salesperson', `/api/v1/receipts/${draft.id}/attachments/${draft.id}`))
        .status,
    ).toBe(404);

    // Documents are never deleted by the app.
    await expect(pools.app.query('DELETE FROM stock_receipt_attachments')).rejects.toThrow();
  });

  it('are verified or rejected with a reason, and a rejected one can be replaced', async () => {
    const receipt = await submitted();
    const review = (attachmentId: string, body: object) =>
      as('accounts').post(
        `/api/v1/receipts/${receipt.id}/attachments/${attachmentId}/review`,
        body,
      );
    const first = receipt.attachments[0].id;

    const noReason = await review(first, { status: 'REJECTED' });
    expect(noReason.body.error.details).toEqual([
      { field: 'notes', message: 'Say why the document is rejected' },
    ]);
    expect((await review(first, { status: 'REJECTED', notes: 'Photo too blurry' })).status).toBe(
      200,
    );
    expect((await review(first, { status: 'VERIFIED' })).body.error.code).toBe(
      'DOCUMENT_ALREADY_REVIEWED',
    );
    const unverified = await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`);
    expect(unverified.body.error.code).toBe('NO_VERIFIED_DOCUMENT');

    // The uploader adds a replacement while the receipt waits for verification.
    const replaced = await upload('storekeeper', receipt.id, 'invoice-scan.pdf', FILES.pdf);
    expect(replaced.status).toBe(201);
    const second = replaced.body.receipt.attachments[1].id;
    expect((await review(second, { status: 'VERIFIED', documentTotal: 42.5 })).status).toBe(200);
    const verified = await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`);
    expect(verified.body.receipt.status).toBe('POSTED');
    expect(
      verified.body.receipt.attachments.map(
        (a: { verificationStatus: string }) => a.verificationStatus,
      ),
    ).toEqual(['REJECTED', 'VERIFIED']);
  });

  it('may be missing only with an authorised user and a reason', async () => {
    const draft = await createDraft();
    const byStorekeeper = await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`, {
      noDocumentReason: 'Supplier will email the invoice',
    });
    expect(byStorekeeper.status).toBe(403);
    const tooShort = await as('admin').post(`/api/v1/receipts/${draft.id}/submit`, {
      noDocumentReason: 'no',
    });
    expect(tooShort.status).toBe(400);

    const byAdmin = await as('admin').post(`/api/v1/receipts/${draft.id}/submit`, {
      noDocumentReason: 'Supplier will email the invoice',
    });
    expect(byAdmin.status).toBe(200);
    expect(byAdmin.body.receipt.noDocumentReason).toBe('Supplier will email the invoice');
    const [entry] = await auditEntries(pools.owner, 'receipt.no_document');
    expect(entry?.details).toMatchObject({ reason: 'Supplier will email the invoice' });
    const verified = await as('accounts').post(`/api/v1/receipts/${draft.id}/verify`);
    expect(verified.body.receipt.status).toBe('POSTED');
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
    await as('accounts').post(
      `/api/v1/receipts/${receipt.id}/attachments/${receipt.attachments[0].id}/review`,
      { status: 'VERIFIED' },
    );
    await as('accounts').post(`/api/v1/receipts/${receipt.id}/verify`);

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
    await upload('storekeeper', draft.id, 'invoice.pdf', FILES.pdf);
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
        receipts: { stockAvailableBeforeVerification: false, documentRequired: true },
      },
      { db: pools.app, checkDatabase: async () => true },
    );
    const onStrict = (who: string) => as(who, () => strict);
    const draft = (await onStrict('storekeeper').post('/api/v1/receipts', draftBody())).body
      .receipt;
    await upload('storekeeper', draft.id, 'invoice.pdf', FILES.pdf);
    const submit = await onStrict('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`);
    expect(submit.body.receipt).toMatchObject({
      status: 'PENDING_VERIFICATION',
      stockAdded: false,
    });
    expect(await owned(bbq, hq)).toBe(0);

    await onStrict('accounts').post(
      `/api/v1/receipts/${draft.id}/attachments/${submit.body.receipt.attachments[0].id}/review`,
      { status: 'VERIFIED' },
    );
    const verified = await onStrict('accounts').post(`/api/v1/receipts/${draft.id}/verify`);
    expect(verified.body.receipt).toMatchObject({ status: 'VERIFIED', stockAdded: false });
    expect(await owned(bbq, hq)).toBe(0);

    const posted = await onStrict('storekeeper').post(`/api/v1/receipts/${draft.id}/post`);
    expect(posted.body.receipt).toMatchObject({ status: 'POSTED', stockAdded: true });
    expect(await owned(bbq, hq)).toBe(100);
    expect(await auditEntries(pools.owner, 'receipt.posted')).toHaveLength(1);
  });
});
