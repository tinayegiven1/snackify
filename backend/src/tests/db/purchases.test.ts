import { readdir } from 'node:fs/promises';
import type { Express } from 'express';
import request from 'supertest';
import { afterAll, beforeEach, describe, expect, it } from 'vitest';
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

// Goods bought: finance enters what was bought; the warehouse receives against it.
const pools = createTestPools();
const PASSWORD = '4826';
let app: Express;
const tokens: Record<string, string> = {};
let hq: string;
let subA: string;
let supplierId: string;
let bbq: string;
let cheese: string;
let pack: string;

const today = () => businessToday('Africa/Harare');
const auth = (who: string) => ({ Authorization: `Bearer ${tokens[who]}` });
const as = (who: string) => ({
  get: (path: string) => request(app).get(path).set(auth(who)),
  post: (path: string, body: object = {}) => request(app).post(path).set(auth(who)).send(body),
  put: (path: string, body: object) => request(app).put(path).set(auth(who)).send(body),
});

// Small but genuine file headers: what the server checks.
const FILES = {
  pdf: Buffer.from('%PDF-1.4\n% supplier invoice INV-2040\n%%EOF\n'),
  png: Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48]),
  jpeg: Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 16, 0x4a, 0x46, 0x49, 0x46, 0]),
  exe: Buffer.from('MZ\x90\x00\x03\x00\x00\x00 This program cannot be run in DOS mode', 'latin1'),
};

const upload = (who: string, id: string, filename: string, content: Buffer) =>
  request(app)
    .post(`/api/v1/purchases/${id}/attachments?filename=${encodeURIComponent(filename)}`)
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

const purchaseBody = (overrides: object = {}) => ({
  supplierId,
  supplierInvoiceNumber: 'INV-2040',
  lines: [
    { productId: bbq, unitId: pack, quantity: 100, unitCost: '0.4250' },
    { productId: cheese, unitId: pack, quantity: 50, unitCost: '0.3000', notes: 'Promo packs' },
  ],
  ...overrides,
});

async function bought(overrides: object = {}) {
  const response = await as('accounts').post('/api/v1/purchases', purchaseBody(overrides));
  expect(response.status, JSON.stringify(response.body)).toBe(201);
  return response.body.purchase;
}

interface BoughtLine {
  id: string;
  product: { id: string };
  unit: { id: string };
  unitCost: string;
}

/** A goods-received note made from [purchase], receiving [received] of each line. */
async function receiveAgainst(
  purchase: { id: string; lines: BoughtLine[] },
  received: number[],
  submit = true,
) {
  const body = {
    supplierId,
    purchaseId: purchase.id,
    lines: purchase.lines.map((line, index) => ({
      productId: line.product.id,
      unitId: line.unit.id,
      quantityPurchased: received[index],
      quantityReceived: received[index],
      unitCost: line.unitCost,
      purchaseLineId: line.id,
    })),
  };
  const draft = await as('storekeeper').post('/api/v1/receipts', body);
  expect(draft.status, JSON.stringify(draft.body)).toBe(201);
  const id = draft.body.receipt.id as string;
  if (!submit) return draft.body.receipt;
  const submitted = await as('storekeeper').post(`/api/v1/receipts/${id}/submit`);
  expect(submitted.status, JSON.stringify(submitted.body)).toBe(200);
  return submitted.body.receipt;
}

beforeEach(async () => {
  await resetDatabase(pools.owner);
  await pools.owner.query(
    'ALTER SEQUENCE purchase_number_seq RESTART; ALTER SEQUENCE stock_receipt_number_seq RESTART',
  );
  app = createDbTestApp(pools.app);
  hq = await headOfficeId(pools.owner);
  subA = await createTestSubsidiary(pools.owner, 'SUB-A', 'Avondale Shop');
  for (const role of ['admin', 'storekeeper', 'accounts', 'salesperson'] as const) {
    await createTestUser(pools.app, { username: role, role, password: PASSWORD });
    tokens[role] = await signIn(app, role, PASSWORD);
  }
  const { rows } = await pools.owner.query<{ id: string }>(
    `INSERT INTO suppliers (code, name) VALUES ('SUP-01', 'Harare Potato Co-op') RETURNING id`,
  );
  supplierId = (rows[0] as { id: string }).id;
  bbq = await createTestProduct(pools.owner);
  cheese = await createTestProduct(pools.owner, { sku: 'PC-CH-S', flavour: 'Cheese' });
  const { rows: units } = await pools.owner.query<{ id: string }>(
    `SELECT id FROM units WHERE code = 'pack'`,
  );
  pack = (units[0] as { id: string }).id;
});
afterAll(() => pools.close());

describe('goods bought', () => {
  it('are entered by finance, seen by the warehouse, and kept from everyone else', async () => {
    const purchase = await bought();
    expect(purchase).toMatchObject({
      purchaseNumber: 'GB000001',
      status: 'OPEN',
      receivingStatus: 'NOT_RECEIVED',
      owner: { id: hq, code: 'HQ' },
      supplier: { code: 'SUP-01' },
      supplierInvoiceNumber: 'INV-2040',
      purchaseDate: today(),
      currency: 'USD',
      total: '57.50', // 100 x 0.4250 + 50 x 0.3000
      lineCount: 2,
      createdBy: { fullName: 'Test accounts' },
      canChange: true,
      canCancel: true,
      receipts: [],
    });
    expect(purchase.lines[0]).toMatchObject({
      lineNumber: 1,
      quantity: 100,
      unitCost: '0.4250',
      lineTotal: '42.50',
      quantityReceived: 0,
      quantityOutstanding: 100,
    });
    expect(purchase.lines[1].notes).toBe('Promo packs');
    expect(await auditEntries(pools.owner, 'purchase.created')).toHaveLength(1);

    // The warehouse sees it but cannot enter one; sales staff see nothing.
    expect((await as('storekeeper').get(`/api/v1/purchases/${purchase.id}`)).status).toBe(200);
    expect((await as('storekeeper').post('/api/v1/purchases', purchaseBody())).status).toBe(403);
    expect((await as('salesperson').get('/api/v1/purchases')).status).toBe(403);
    expect((await as('admin').post('/api/v1/purchases', purchaseBody())).status).toBe(201);
  });

  it('print as a PDF', async () => {
    const purchase = await bought();
    const pdf = await download('storekeeper', `/api/v1/purchases/${purchase.id}/pdf`);
    expect(pdf.status).toBe(200);
    expect(pdf.headers['content-type']).toBe('application/pdf');
    expect(pdf.headers['content-disposition']).toBe('inline; filename="GB000001.pdf"');
    expect((pdf.body as Buffer).subarray(0, 5).toString()).toBe('%PDF-');
  });

  it('check what is entered', async () => {
    const fields = async (body: object) =>
      ((await as('accounts').post('/api/v1/purchases', body)).body.error?.details ?? []).map(
        (d: { field: string }) => d.field,
      );
    expect(await fields(purchaseBody({ lines: [] }))).toEqual(['lines']);
    expect(
      await fields(
        purchaseBody({ lines: [{ productId: bbq, unitId: pack, quantity: 0, unitCost: '1' }] }),
      ),
    ).toEqual(['lines.0.quantity']);
    expect(await fields(purchaseBody({ purchaseDate: '2999-01-01' }))).toEqual(['purchaseDate']);
  });

  it('show what has arrived as the warehouse receives against them', async () => {
    const purchase = await bought();

    // A draft does not count as arrived, but it already stops the list being changed.
    const draft = await receiveAgainst(purchase, [60, 50], false);
    expect(draft.purchase).toEqual({ id: purchase.id, purchaseNumber: 'GB000001' });
    let now = (await as('accounts').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(now).toMatchObject({
      receivingStatus: 'NOT_RECEIVED',
      canChange: false,
      canCancel: false,
    });
    const changed = await as('accounts').put(`/api/v1/purchases/${purchase.id}`, purchaseBody());
    expect(changed.status).toBe(409);
    expect(changed.body.error.code).toBe('PURCHASE_HAS_RECEIPTS');
    expect(
      (await as('accounts').post(`/api/v1/purchases/${purchase.id}/cancel`, { reason: 'Wrong' }))
        .status,
    ).toBe(409);

    // Submitted: 60 of 100 BBQ and all 50 Cheese have arrived.
    expect((await as('storekeeper').post(`/api/v1/receipts/${draft.id}/submit`)).status).toBe(200);
    now = (await as('accounts').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(now.receivingStatus).toBe('PARTLY_RECEIVED');
    expect(
      now.lines.map((l: { quantityReceived: number; quantityOutstanding: number }) => [
        l.quantityReceived,
        l.quantityOutstanding,
      ]),
    ).toEqual([
      [60, 40],
      [50, 0],
    ]);
    expect(now.receipts).toEqual([
      expect.objectContaining({ grnNumber: 'GRN000001', status: 'PENDING_VERIFICATION' }),
    ]);

    // The rest arrives on a second note; finance approves it (a different person).
    const second = await receiveAgainst({ ...purchase, lines: [purchase.lines[0]] }, [40]);
    expect((await as('accounts').post(`/api/v1/receipts/${second.id}/verify`)).status).toBe(200);
    now = (await as('accounts').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(now.receivingStatus).toBe('RECEIVED');
    const filtered = await as('accounts').get('/api/v1/purchases?status=RECEIVED');
    expect(filtered.body.purchases.map((p: { id: string }) => p.id)).toEqual([purchase.id]);
  });

  it('only take deliveries that match them', async () => {
    const purchase = await bought();
    const line = (overrides: object = {}) => ({
      productId: bbq,
      unitId: pack,
      quantityPurchased: 10,
      quantityReceived: 10,
      unitCost: '0.4250',
      purchaseLineId: purchase.lines[0].id,
      ...overrides,
    });
    const field = async (body: object) => {
      const response = await as('storekeeper').post('/api/v1/receipts', body);
      expect(response.status, JSON.stringify(response.body)).toBe(400);
      return response.body.error.details[0].field;
    };
    // A line from a list, without the list.
    expect(await field({ lines: [line()] })).toBe('lines.0.purchaseLineId');
    // The wrong product for that line.
    expect(await field({ purchaseId: purchase.id, lines: [line({ productId: cheese })] })).toBe(
      'lines.0.productId',
    );
    // Another organisation's stock.
    expect(await field({ purchaseId: purchase.id, organisationId: subA, lines: [line()] })).toBe(
      'organisationId',
    );
    // A list that was cancelled.
    const cancelled = await bought();
    await as('accounts').post(`/api/v1/purchases/${cancelled.id}/cancel`, { reason: 'Duplicate' });
    expect(
      await field({
        purchaseId: cancelled.id,
        lines: [line({ purchaseLineId: cancelled.lines[0].id })],
      }),
    ).toBe('purchaseId');
    // Receiving without a list is still fine.
    const loose = await as('storekeeper').post('/api/v1/receipts', {
      lines: [line({ purchaseLineId: null })],
    });
    expect(loose.status).toBe(201);
    expect(loose.body.receipt.purchase).toBeNull();
  });

  it('can be changed, or cancelled with a reason, until goods arrive against them', async () => {
    const purchase = await bought();
    const changed = await as('accounts').put(
      `/api/v1/purchases/${purchase.id}`,
      purchaseBody({ lines: [{ productId: bbq, unitId: pack, quantity: 12, unitCost: '1.25' }] }),
    );
    expect(changed.status).toBe(200);
    expect(changed.body.purchase).toMatchObject({ total: '15.00', lineCount: 1 });

    // A note started from the list as it was before the change points at lines that are gone:
    // refused, saying what to do.
    const stale = await as('storekeeper').post('/api/v1/receipts', {
      purchaseId: purchase.id,
      lines: [
        {
          productId: bbq,
          unitId: pack,
          quantityPurchased: 100,
          quantityReceived: 100,
          unitCost: '0.4250',
          purchaseLineId: purchase.lines[0].id,
        },
      ],
    });
    expect(stale.status).toBe(400);
    expect(stale.body.error.details).toEqual([
      {
        field: 'lines.0.purchaseLineId',
        message:
          'The goods-bought list was changed after this note was started. Go back to the list ' +
          'and press Receive again.',
      },
    ]);

    const noReason = await as('accounts').post(`/api/v1/purchases/${purchase.id}/cancel`, {});
    expect(noReason.status).toBe(400);
    const cancelled = await as('accounts').post(`/api/v1/purchases/${purchase.id}/cancel`, {
      reason: 'Supplier could not deliver',
    });
    expect(cancelled.status).toBe(200);
    expect(cancelled.body.purchase).toMatchObject({
      status: 'CANCELLED',
      cancelReason: 'Supplier could not deliver',
      cancelledBy: { fullName: 'Test accounts' },
      canChange: false,
      canCancel: false,
    });
    const again = await as('accounts').put(`/api/v1/purchases/${purchase.id}`, purchaseBody());
    expect(again.body.error.code).toBe('PURCHASE_CANCELLED');
    expect(await auditEntries(pools.owner, 'purchase.cancelled')).toHaveLength(1);
    const open = await as('accounts').get('/api/v1/purchases?status=OPEN');
    expect(open.body.total).toBe(0);
  });
});

describe('supplier documents on goods bought', () => {
  it('accept PDF, JPEG and PNG files from finance and administrators, checked by content', async () => {
    const purchase = await bought();
    const dir = testConfig.attachments.storageDir;
    for (const [who, name, content] of [
      ['accounts', 'invoice.pdf', FILES.pdf],
      ['admin', 'delivery note.PNG', FILES.png],
      ['accounts', '../../photo.jpeg', FILES.jpeg],
    ] as const) {
      const uploaded = await upload(who, purchase.id, name, content);
      expect(uploaded.status, JSON.stringify(uploaded.body)).toBe(201);
    }
    const before = (await readdir(dir)).length;

    // A program renamed "invoice.pdf", a PDF claiming to be a photo, empty and oversized files.
    const exe = await upload('accounts', purchase.id, 'invoice.pdf', FILES.exe);
    expect(exe.status).toBe(415);
    expect(exe.body.error.code).toBe('UNSUPPORTED_DOCUMENT');
    const mismatch = await upload('accounts', purchase.id, 'photo.png', FILES.pdf);
    expect(mismatch.status).toBe(415);
    expect(mismatch.body.error.code).toBe('UNSUPPORTED_DOCUMENT');
    expect((await upload('accounts', purchase.id, 'invoice.exe', FILES.pdf)).status).toBe(415);
    expect((await upload('accounts', purchase.id, 'empty.pdf', Buffer.alloc(0))).status).toBe(400);
    const huge = Buffer.concat([FILES.pdf, Buffer.alloc(testConfig.attachments.maxBytes)]);
    expect((await upload('accounts', purchase.id, 'huge.pdf', huge)).status).toBe(413);
    // The warehouse and sales staff do not attach them.
    expect((await upload('storekeeper', purchase.id, 'invoice.pdf', FILES.pdf)).status).toBe(403);
    expect((await upload('salesperson', purchase.id, 'invoice.pdf', FILES.pdf)).status).toBe(403);
    const unknown = '00000000-0000-4000-8000-000000000000';
    expect((await upload('accounts', unknown, 'invoice.pdf', FILES.pdf)).status).toBe(404);
    expect((await readdir(dir)).length).toBe(before);

    // Listed oldest first, waiting for review.
    const detail = (await as('storekeeper').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(detail).toMatchObject({ documentCount: 3, documentsPending: 3 });
    expect(detail.attachments).toHaveLength(3);
    expect(detail.attachments[0]).toEqual({
      id: expect.any(String),
      filename: 'invoice.pdf',
      mimeType: 'application/pdf',
      sizeBytes: FILES.pdf.length,
      uploadedBy: { id: expect.any(String), fullName: 'Test accounts' },
      uploadedAt: expect.any(String),
      verificationStatus: 'PENDING',
      reviewedBy: null,
      reviewedAt: null,
      reviewNotes: null,
      documentTotal: null,
    });
    expect(
      detail.attachments.map((a: { filename: string; mimeType: string; uploadedBy: object }) => [
        a.filename,
        a.mimeType,
        a.uploadedBy,
      ]),
    ).toEqual([
      ['invoice.pdf', 'application/pdf', expect.objectContaining({ fullName: 'Test accounts' })],
      ['delivery note.PNG', 'image/png', expect.objectContaining({ fullName: 'Test admin' })],
      ['photo.jpeg', 'image/jpeg', expect.objectContaining({ fullName: 'Test accounts' })],
    ]);
    const list = (await as('accounts').get('/api/v1/purchases')).body.purchases;
    expect(list).toEqual([
      expect.objectContaining({ id: purchase.id, documentCount: 3, documentsPending: 3 }),
    ]);
    const [entry] = await auditEntries(pools.owner, 'purchase.document_added');
    expect(entry?.details).toMatchObject({
      purchaseNumber: 'GB000001',
      filename: 'invoice.pdf',
      mimeType: 'application/pdf',
    });
    expect(await auditEntries(pools.owner, 'purchase.document_added')).toHaveLength(3);

    // Stored under random names, outside the web app; downloaded only through the API.
    const { rows } = await pools.owner.query<{ storage_key: string }>(
      'SELECT storage_key FROM purchase_attachments',
    );
    expect(rows.every((row) => /^[a-f0-9]{64}$/.test(row.storage_key))).toBe(true);
    const path = `/api/v1/purchases/${purchase.id}/attachments/${detail.attachments[0].id}`;
    const file = await download('storekeeper', path);
    expect(file.status).toBe(200);
    expect(file.headers['content-type']).toBe('application/pdf');
    expect(file.headers['content-disposition']).toBe('attachment; filename="invoice.pdf"');
    expect(file.headers['x-content-type-options']).toBe('nosniff');
    expect(Buffer.compare(file.body as Buffer, FILES.pdf)).toBe(0);
    expect((await download('accounts', path)).status).toBe(200);
    expect((await download(null, path)).status).toBe(401);
    expect((await download('salesperson', path)).status).toBe(403);
    expect(
      (await download('accounts', `/api/v1/purchases/${purchase.id}/attachments/${purchase.id}`))
        .status,
    ).toBe(404);

    // Documents are never deleted by the app.
    await expect(pools.app.query('DELETE FROM purchase_attachments')).rejects.toThrow();
  });

  it('are verified or rejected with a reason by finance or an administrator only', async () => {
    const purchase = await bought();
    await upload('accounts', purchase.id, 'invoice.pdf', FILES.pdf);
    const uploaded = await upload('accounts', purchase.id, 'invoice-scan.pdf', FILES.pdf);
    const [first, second] = uploaded.body.purchase.attachments.map((a: { id: string }) => a.id);
    const review = (who: string, attachmentId: string, body: object) =>
      as(who).post(`/api/v1/purchases/${purchase.id}/attachments/${attachmentId}/review`, body);

    // The warehouse may look at documents but not decide on them.
    expect((await review('storekeeper', first, { status: 'VERIFIED' })).status).toBe(403);
    expect((await review('salesperson', first, { status: 'VERIFIED' })).status).toBe(403);

    const noReason = await review('accounts', first, { status: 'REJECTED' });
    expect(noReason.status).toBe(400);
    expect(noReason.body.error.details).toEqual([
      { field: 'notes', message: 'Say why the document is rejected' },
    ]);
    const rejected = await review('accounts', first, {
      status: 'REJECTED',
      notes: 'Photo too blurry',
    });
    expect(rejected.status).toBe(200);
    expect(rejected.body.purchase.attachments[0]).toMatchObject({
      verificationStatus: 'REJECTED',
      reviewNotes: 'Photo too blurry',
      reviewedBy: { fullName: 'Test accounts' },
      reviewedAt: expect.any(String),
    });
    const twice = await review('admin', first, { status: 'VERIFIED' });
    expect(twice.status).toBe(409);
    expect(twice.body.error.code).toBe('DOCUMENT_ALREADY_REVIEWED');

    const verified = await review('admin', second, { status: 'VERIFIED', documentTotal: 57.5 });
    expect(verified.status, JSON.stringify(verified.body)).toBe(200);
    expect(verified.body.purchase).toMatchObject({ documentCount: 2, documentsPending: 0 });
    expect(verified.body.purchase.attachments[1]).toMatchObject({
      verificationStatus: 'VERIFIED',
      documentTotal: '57.50',
      reviewedBy: { fullName: 'Test admin' },
    });
    const badTotal = await review('admin', first, { status: 'VERIFIED', documentTotal: '1.234' });
    expect(badTotal.status).toBe(400);

    const entries = await auditEntries(pools.owner, 'purchase.document_reviewed');
    expect(entries).toHaveLength(2);
    expect(entries.map((e) => e.details)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ status: 'REJECTED', notes: 'Photo too blurry' }),
        expect.objectContaining({ status: 'VERIFIED', documentTotal: '57.5' }),
      ]),
    );
  });

  it('are kept on a cancelled list, but not added to or reviewed', async () => {
    const purchase = await bought();
    const uploaded = await upload('accounts', purchase.id, 'invoice.pdf', FILES.pdf);
    const attachmentId = uploaded.body.purchase.attachments[0].id;
    await as('accounts').post(`/api/v1/purchases/${purchase.id}/cancel`, { reason: 'Duplicate' });

    const added = await upload('accounts', purchase.id, 'invoice-2.pdf', FILES.pdf);
    expect(added.status).toBe(409);
    expect(added.body.error.code).toBe('PURCHASE_CANCELLED');
    const reviewed = await as('accounts').post(
      `/api/v1/purchases/${purchase.id}/attachments/${attachmentId}/review`,
      { status: 'VERIFIED' },
    );
    expect(reviewed.status).toBe(409);
    expect(reviewed.body.error.code).toBe('PURCHASE_CANCELLED');

    const file = await download(
      'storekeeper',
      `/api/v1/purchases/${purchase.id}/attachments/${attachmentId}`,
    );
    expect(file.status).toBe(200);
    const now = (await as('accounts').get(`/api/v1/purchases/${purchase.id}`)).body.purchase;
    expect(now).toMatchObject({ status: 'CANCELLED', documentCount: 1, documentsPending: 1 });
  });

  it('print on the goods-bought PDF when photographed, each on its own page', async () => {
    const pages = (pdf: string) => pdf.match(new RegExp('/Type /Page[^s]', 'g'))?.length ?? 0;
    const plain = await bought();
    const plainPdf = await download('storekeeper', `/api/v1/purchases/${plain.id}/pdf`);
    const plainPages = pages((plainPdf.body as Buffer).toString('latin1'));
    expect(plainPages).toBeGreaterThanOrEqual(1);
    expect((plainPdf.body as Buffer).toString('latin1')).not.toContain('/Subtype /Image');

    // A real 1x1 PNG (a camera photo), a PDF (not printed) and a damaged PNG (noted instead).
    const photo = Buffer.from(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      'base64',
    );
    const purchase = await bought();
    expect((await upload('accounts', purchase.id, 'photo-1.png', photo)).status).toBe(201);
    expect((await upload('accounts', purchase.id, 'invoice.pdf', FILES.pdf)).status).toBe(201);
    expect((await upload('accounts', purchase.id, 'damaged.png', FILES.png)).status).toBe(201);

    const pdf = await download('storekeeper', `/api/v1/purchases/${purchase.id}/pdf`);
    expect(pdf.status).toBe(200);
    expect(pdf.headers['content-type']).toBe('application/pdf');
    const text = (pdf.body as Buffer).toString('latin1');
    // The list, then one page per picture (the damaged one gets a note instead).
    expect(pages(text)).toBe(plainPages + 2);
    // Only the good photo is embedded: its picture plus its transparency mask.
    expect(text.split('/Subtype /Image')).toHaveLength(3);
  });
});
