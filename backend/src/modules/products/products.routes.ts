import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { moneySchema, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { asEan13 } from '../../utils/ean13.js';
import { LABEL_SHEET, renderLabelsPdf } from './labels-pdf.js';
import {
  assignInternalBarcode,
  createProduct,
  findProductByBarcode,
  getProduct,
  listProducts,
  updateProduct,
} from './products.service.js';

// These rules match the database constraints, so most mistakes get a clear field message.
const text = (max: number) =>
  z
    .string({ error: 'Required' })
    .trim()
    .min(1, 'Required')
    .max(max, `Use at most ${max} characters`);

const skuSchema = z
  .string({ error: 'Required' })
  .trim()
  .toUpperCase()
  .regex(
    /^[A-Z0-9][A-Z0-9._-]{0,39}$/,
    'Use up to 40 letters, digits, dots, dashes or underscores, e.g. PC-BBQ-S',
  );

/** A barcode, or null / empty text for "no barcode". */
const barcodeSchema = z
  .string({ error: 'Must be text or null' })
  .trim()
  .nullable()
  .transform((value) => value || null)
  .refine(
    (value) => value === null || /^[A-Za-z0-9-]{4,48}$/.test(value),
    'Use 4–48 letters, digits or dashes',
  );

/** Low-stock alert level in packs, or null for no alert. */
const reorderLevelSchema = z
  .number({ error: 'Must be a whole number or null' })
  .int('Must be a whole number')
  .min(0, 'Must be 0 or more')
  .max(1_000_000, 'Must be at most 1,000,000')
  .nullable();

/** Packs to keep on top of forecast demand (spec 6.11). */
const safetyStockSchema = z
  .number({ error: 'Must be a whole number' })
  .int('Must be a whole number')
  .min(0, 'Must be 0 or more')
  .max(1_000_000, 'Must be at most 1,000,000');

const createProductSchema = z.object({
  sku: skuSchema,
  name: text(100),
  flavour: text(60),
  size: text(40),
  barcode: barcodeSchema.optional().transform((value) => value ?? null),
  defaultPrice: moneySchema,
  reorderLevel: reorderLevelSchema.optional().transform((value) => value ?? null),
  safetyStock: safetyStockSchema.default(0),
});

const updateProductSchema = z
  .strictObject(
    {
      sku: skuSchema.optional(),
      name: text(100).optional(),
      flavour: text(60).optional(),
      size: text(40).optional(),
      barcode: barcodeSchema.optional(),
      defaultPrice: moneySchema.optional(),
      reorderLevel: reorderLevelSchema.optional(),
      safetyStock: safetyStockSchema.optional(),
      isActive: z.boolean({ error: 'Must be true or false' }).optional(),
    },
    { error: 'This field cannot be changed' },
  )
  .refine((changes) => Object.keys(changes).length > 0, 'Send at least one field to change');

const listQuerySchema = z.object({
  q: z.string().trim().max(100, 'Use at most 100 characters').optional(),
  includeInactive: z
    .enum(['true', 'false'], { error: 'Must be true or false' })
    .optional()
    .transform((value) => value === 'true'),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

const productNotFound = () => new AppError(404, 'PRODUCT_NOT_FOUND', 'No product has that id.');

const labelsQuerySchema = z.object({
  count: z.coerce
    .number({ error: 'Must be a whole number' })
    .int('Must be a whole number')
    .min(1, 'Print at least 1 label')
    .max(240, 'Print at most 240 labels (10 sheets) at once')
    .default(LABEL_SHEET.perSheet),
  skip: z.coerce
    .number({ error: 'Must be a whole number' })
    .int('Must be a whole number')
    .min(0, 'Must be 0 or more')
    .max(LABEL_SHEET.perSheet - 1, `At most ${LABEL_SHEET.perSheet - 1} labels can be skipped`)
    .default(0),
});

/**
 * A scanned or typed barcode: spaces are ignored (people type "6 001234 567890"), and only
 * letters, digits and dashes can be part of a barcode.
 */
function parseScannedBarcode(value: unknown): string {
  const barcode = String(value ?? '').replace(/\s+/g, '');
  if (!/^[A-Za-z0-9-]{1,48}$/.test(barcode)) {
    throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
      { field: 'barcode', message: 'A barcode has only letters, digits and dashes' },
    ]);
  }
  return barcode;
}

/** Product catalogue. Every signed-in user can view it; only admins can change it (spec 5). */
export function productsRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db));

  router.get('/', async (req, res) => {
    const search = parseBody(listQuerySchema, req.query);
    res.json(await listProducts(db, search));
  });

  /** Finds the product a scanned barcode belongs to (spec 6.7). */
  router.get('/barcode/:barcode', async (req, res) => {
    res.json({ product: await findProductByBarcode(db, parseScannedBarcode(req.params.barcode)) });
  });

  router.get('/:id', async (req, res) => {
    res.json({ product: await getProduct(db, parseIdParam(req.params.id, productNotFound)) });
  });

  router.post('/', requirePermission('product.manage'), async (req, res) => {
    const input = parseBody(createProductSchema, req.body);
    const product = await createProduct(db, input, getAuth(res).user.id);
    res.status(201).json({ product });
  });

  router.patch('/:id', requirePermission('product.manage'), async (req, res) => {
    const id = parseIdParam(req.params.id, productNotFound);
    const changes = parseBody(updateProductSchema, req.body);
    const product = await updateProduct(db, id, changes, getAuth(res).user.id);
    res.json({ product });
  });

  /** Gives a product without a barcode one of Snackify's own EAN-13 barcodes. */
  router.post('/:id/barcode', requirePermission('product.manage'), async (req, res) => {
    const id = parseIdParam(req.params.id, productNotFound);
    res.json({ product: await assignInternalBarcode(db, id, getAuth(res).user.id) });
  });

  /** Printable barcode labels (A4, 24 per sheet) for storekeepers and admins. */
  router.get('/:id/labels', requirePermission('label.print'), async (req, res) => {
    const id = parseIdParam(req.params.id, productNotFound);
    const options = parseBody(labelsQuerySchema, req.query);
    const product = await getProduct(db, id);
    if (!product.barcode) {
      throw new AppError(
        409,
        'PRODUCT_HAS_NO_BARCODE',
        'This product has no barcode yet. An admin can generate one in Products.',
      );
    }
    const ean13 = asEan13(product.barcode);
    if (!ean13) {
      throw new AppError(
        409,
        'BARCODE_NOT_PRINTABLE',
        `Labels can only be printed for EAN-13 barcodes, and ${product.barcode} is not one. ` +
          'Use the barcode printed on the pack.',
      );
    }
    const pdf = await renderLabelsPdf(product, ean13, options);
    res
      .type('application/pdf')
      .set('Content-Disposition', `inline; filename="labels-${product.sku}.pdf"`)
      .set('Cache-Control', 'no-store')
      .send(pdf);
  });

  return router;
}
