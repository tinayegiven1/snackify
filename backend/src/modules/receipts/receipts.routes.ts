import express, { Router, type Response } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import type { AppConfig } from '../../config/env.js';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { businessToday } from '../../utils/dates.js';
import { optionalText, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { organisationFor, scopeOf } from '../organisations/access.js';
import { renderGrnPdf } from './grn-pdf.js';
import {
  createReceipt,
  getReceipt,
  listReceipts,
  postReceipt,
  readAttachment,
  rejectReceipt,
  reverseReceipt,
  reviewAttachment,
  submitReceipt,
  updateDraft,
  uploadAttachment,
  verifyReceipt,
  type ReceiptInput,
} from './receipts.service.js';

const MAX_QUANTITY = 1_000_000;
const MAX_LINES = 200;

const dateSchema = z.iso.date({ error: 'Use a date like 2026-10-12' });
const quantity = z
  .number({ error: 'Must be a whole number' })
  .int('Must be a whole number')
  .min(0, 'Must be 0 or more')
  .max(MAX_QUANTITY, `Must be at most ${MAX_QUANTITY.toLocaleString('en')}`);
/** A cost per unit: exact, 0 or more, up to 4 decimal places (supplier prices can be fractional). */
const unitCostSchema = z
  .union([z.string(), z.number()], { error: 'Required' })
  .transform((value) => String(value).trim())
  .refine((value) => /^\d{1,10}(\.\d{1,4})?$/.test(value), {
    message: 'Use an amount of 0 or more with up to 4 decimal places, e.g. 0.4250',
  });
const documentTotalSchema = z
  .union([z.string(), z.number()])
  .transform((value) => String(value).trim())
  .refine((value) => /^\d{1,12}(\.\d{1,2})?$/.test(value), {
    message: 'Use an amount with up to 2 decimal places, e.g. 125.50',
  })
  .nullish()
  .transform((value) => value ?? null);

const lineSchema = z
  .object({
    productId: z.uuid({ error: 'Must be a product id' }),
    unitId: z.uuid({ error: 'Must be a unit id' }),
    quantityPurchased: quantity,
    quantityReceived: quantity,
    unitCost: unitCostSchema,
    batchNumber: optionalText(60),
    expiryDate: dateSchema.nullish().transform((value) => value ?? null),
    discrepancyReason: z
      .enum(['shortage', 'overage', 'damaged', 'rejected'], {
        error: 'Must be shortage, overage, damaged or rejected',
      })
      .nullish()
      .transform((value) => value ?? null),
    notes: optionalText(500),
  })
  .refine((line) => line.quantityPurchased > 0 || line.quantityReceived > 0, {
    path: ['quantityReceived'],
    message: 'Enter what was bought or received',
  })
  .refine(
    (line) => line.quantityPurchased === line.quantityReceived || line.discrepancyReason !== null,
    {
      path: ['discrepancyReason'],
      message: 'Say why the quantity received differs from the quantity bought',
    },
  )
  .refine(
    (line) => line.quantityPurchased !== line.quantityReceived || line.discrepancyReason === null,
    { path: ['discrepancyReason'], message: 'Leave empty when the quantities match' },
  );

const receiptSchema = z.object({
  /** Whose stock arrived. Defaults to the user's own organisation. */
  organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
  warehouseId: z
    .uuid({ error: 'Must be a warehouse id' })
    .nullish()
    .transform((value) => value ?? null),
  supplierId: z
    .uuid({ error: 'Must be a supplier id' })
    .nullish()
    .transform((value) => value ?? null),
  supplierInvoiceNumber: optionalText(60),
  purchaseDate: dateSchema.nullish().transform((value) => value ?? null),
  receivedDate: dateSchema.optional(),
  notes: optionalText(1000),
  lines: z
    .array(lineSchema, { error: 'Must be a list of lines' })
    .max(MAX_LINES, `Use at most ${MAX_LINES} lines`),
});

const reasonSchema = z.object({
  reason: z
    .string({ error: 'Required' })
    .trim()
    .min(3, 'Explain the reason in a few words')
    .max(500, 'Use at most 500 characters'),
});

const submitSchema = z.object({
  noDocumentReason: optionalText(500).refine((value) => value === null || value.length >= 3, {
    message: 'Explain the reason in a few words',
  }),
});
const verifySchema = z.object({ notes: optionalText(500) });
const reviewSchema = z
  .object({
    status: z.enum(['VERIFIED', 'REJECTED'], { error: 'Must be VERIFIED or REJECTED' }),
    notes: optionalText(500),
    documentTotal: documentTotalSchema,
  })
  .refine((review) => review.status !== 'REJECTED' || (review.notes?.length ?? 0) >= 3, {
    path: ['notes'],
    message: 'Say why the document is rejected',
  });

const listSchema = z.object({
  status: z
    .enum(['DRAFT', 'PENDING_VERIFICATION', 'VERIFIED', 'REJECTED', 'POSTED', 'REVERSED'])
    .optional(),
  organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
  from: dateSchema.optional(),
  to: dateSchema.optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const receiptNotFound = () =>
  new AppError(404, 'RECEIPT_NOT_FOUND', 'No goods-received note has that id.');
const documentNotFound = () => new AppError(404, 'DOCUMENT_NOT_FOUND', 'No document has that id.');

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

/**
 * Goods-received notes (StockFlow Stage 4.4 and 4.5). A receipt belongs to the organisation
 * whose stock arrived; users see only receipts within their access (others answer 404).
 */
export function receiptsRouter(db: pg.Pool, config: AppConfig): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('stock.view'));
  const today = () => businessToday(config.businessTimezone);
  const scope = (res: Response) => scopeOf(getAuth(res).user);
  const receiptId = (value: unknown) => parseIdParam(value, receiptNotFound);

  function toInput(res: Response, body: unknown): ReceiptInput {
    const { organisationId, receivedDate, ...input } = parseBody(receiptSchema, body);
    const received = receivedDate ?? today();
    if (received > today()) throw fieldError('receivedDate', 'Cannot be in the future');
    if (input.purchaseDate && input.purchaseDate > received) {
      throw fieldError('purchaseDate', 'Cannot be after the date the goods were received');
    }
    input.lines.forEach((line, index) => {
      if (line.expiryDate !== null && line.expiryDate < received) {
        throw fieldError(`lines.${index}.expiryDate`, 'Cannot be before the date received');
      }
    });
    return {
      ...input,
      receivedDate: received,
      ownerOrganisationId: organisationFor(scope(res), organisationId),
    };
  }

  router.get('/', async (req, res) => {
    const { organisationId, ...filter } = parseBody(listSchema, req.query);
    const ownerOrganisationId =
      organisationId === undefined ? undefined : organisationFor(scope(res), organisationId);
    res.json(await listReceipts(db, scope(res), { ...filter, ownerOrganisationId }));
  });

  router.get('/:id', async (req, res) => {
    res.json({ receipt: await getReceipt(db, scope(res), receiptId(req.params.id)) });
  });

  router.get('/:id/pdf', async (req, res) => {
    const receipt = await getReceipt(db, scope(res), receiptId(req.params.id));
    const pdf = await renderGrnPdf(receipt, config.business);
    res
      .type('application/pdf')
      .set('Content-Disposition', `inline; filename="${receipt.grnNumber}.pdf"`)
      .set('Cache-Control', 'no-store')
      .send(pdf);
  });

  router.get('/:id/attachments/:attachmentId', async (req, res) => {
    const document = await readAttachment(
      db,
      scope(res),
      receiptId(req.params.id),
      parseIdParam(req.params.attachmentId, documentNotFound),
      config.attachments.storageDir,
    );
    // Always a download with the checked type, never shown as a web page.
    res
      .type(document.mimeType)
      .set(
        'Content-Disposition',
        `attachment; filename="${document.filename.replace(/[^\x20-\x7e]/g, '_')}"`,
      )
      .set('X-Content-Type-Options', 'nosniff')
      .set('Cache-Control', 'no-store')
      .send(document.content);
  });

  router.post('/', requirePermission('stock.receive'), async (req, res) => {
    const input = toInput(res, req.body);
    const receipt = await createReceipt(db, input, getAuth(res).user, config.baseCurrency);
    res.status(201).json({ receipt });
  });

  router.put('/:id', requirePermission('stock.receive'), async (req, res) => {
    const id = receiptId(req.params.id);
    const input = toInput(res, req.body);
    res.json({ receipt: await updateDraft(db, scope(res), id, input, getAuth(res).user) });
  });

  router.post('/:id/submit', requirePermission('stock.receive'), async (req, res) => {
    const { noDocumentReason } = parseBody(submitSchema, req.body ?? {});
    const receipt = await submitReceipt(
      db,
      scope(res),
      receiptId(req.params.id),
      { noDocumentReason },
      getAuth(res).user,
      config.receipts,
    );
    res.json({ receipt });
  });

  router.post('/:id/post', requirePermission('stock.receive'), async (req, res) => {
    const receipt = await postReceipt(db, scope(res), receiptId(req.params.id), getAuth(res).user);
    res.json({ receipt });
  });

  router.post('/:id/verify', requirePermission('receipt.verify'), async (req, res) => {
    const { notes } = parseBody(verifySchema, req.body ?? {});
    const receipt = await verifyReceipt(
      db,
      scope(res),
      receiptId(req.params.id),
      notes,
      getAuth(res).user,
    );
    res.json({ receipt });
  });

  router.post('/:id/reject', requirePermission('receipt.verify'), async (req, res) => {
    const { reason } = parseBody(reasonSchema, req.body);
    const receipt = await rejectReceipt(
      db,
      scope(res),
      receiptId(req.params.id),
      reason,
      getAuth(res).user,
      today(),
    );
    res.json({ receipt });
  });

  router.post('/:id/reverse', requirePermission('receipt.reverse'), async (req, res) => {
    const { reason } = parseBody(reasonSchema, req.body);
    const receipt = await reverseReceipt(
      db,
      scope(res),
      receiptId(req.params.id),
      reason,
      getAuth(res).user,
      today(),
    );
    res.json({ receipt });
  });

  // The file is the raw request body (any content type); its name comes in ?filename=.
  // The content, not the name or the declared type, decides whether it is accepted.
  router.post(
    '/:id/attachments',
    requirePermission('stock.receive'),
    express.raw({ type: () => true, limit: config.attachments.maxBytes }),
    async (req, res) => {
      const id = receiptId(req.params.id);
      const { filename } = parseBody(
        z.object({ filename: z.string({ error: 'Required' }).min(1, 'Required') }),
        req.query,
      );
      const content = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
      const receipt = await uploadAttachment(
        db,
        scope(res),
        id,
        { filename, content },
        getAuth(res).user,
        config.attachments,
      );
      res.status(201).json({ receipt });
    },
  );

  router.post(
    '/:id/attachments/:attachmentId/review',
    requirePermission('receipt.verify'),
    async (req, res) => {
      const review = parseBody(reviewSchema, req.body);
      const receipt = await reviewAttachment(
        db,
        scope(res),
        receiptId(req.params.id),
        parseIdParam(req.params.attachmentId, documentNotFound),
        review,
        getAuth(res).user,
      );
      res.json({ receipt });
    },
  );

  return router;
}
