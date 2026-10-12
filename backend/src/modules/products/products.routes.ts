import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requireRole } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { moneySchema, parseIdParam } from '../../utils/schemas.js';
import { parseBody } from '../../utils/validation.js';
import { createProduct, getProduct, listProducts, updateProduct } from './products.service.js';

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

const createProductSchema = z.object({
  sku: skuSchema,
  name: text(100),
  flavour: text(60),
  size: text(40),
  barcode: barcodeSchema.optional().transform((value) => value ?? null),
  defaultPrice: moneySchema,
  reorderLevel: reorderLevelSchema.optional().transform((value) => value ?? null),
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

/** Product catalogue. Every signed-in user can view it; only admins can change it (spec 5). */
export function productsRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db));

  router.get('/', async (req, res) => {
    const search = parseBody(listQuerySchema, req.query);
    res.json(await listProducts(db, search));
  });

  router.get('/:id', async (req, res) => {
    res.json({ product: await getProduct(db, parseIdParam(req.params.id, productNotFound)) });
  });

  router.post('/', requireRole('admin'), async (req, res) => {
    const input = parseBody(createProductSchema, req.body);
    const product = await createProduct(db, input, getAuth(res).user.id);
    res.status(201).json({ product });
  });

  router.patch('/:id', requireRole('admin'), async (req, res) => {
    const id = parseIdParam(req.params.id, productNotFound);
    const changes = parseBody(updateProductSchema, req.body);
    const product = await updateProduct(db, id, changes, getAuth(res).user.id);
    res.json({ product });
  });

  return router;
}
