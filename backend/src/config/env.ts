import { existsSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

export interface AppConfig {
  nodeEnv: 'development' | 'test' | 'production';
  port: number;
  /** Browser origins allowed to call the API (e.g. the Flutter web dev server). */
  corsOrigins: string[];
  /** PostgreSQL connection string for the API's runtime role (snackify_app). */
  databaseUrl: string;
  /** IANA time zone that decides what "today" is for business dates, e.g. Africa/Harare. */
  businessTimezone: string;
  /** First day of the billing week (1 = Monday ... 7 = Sunday). */
  billingWeekStartsOn: number;
  /** ISO 4217 code of the currency prices are in, stored on every invoice, e.g. USD. */
  baseCurrency: string;
  /** Days after the issue date that an invoice is due, e.g. 7. */
  paymentTermsDays: number;
  /** Printed at the top of invoices. */
  business: { name: string; contact: string | null };
  /** Folder with the built Flutter web app, served on the same address as the API, or null. */
  webAppDir: string | null;
  /**
   * How many proxies in front of the API to trust for the client's address (X-Forwarded-For),
   * e.g. 1 on Google Cloud Run. Sign-in rate limits are per address, so this must be right:
   * too low and everyone shares one limit; too high and clients can fake their address.
   */
  trustProxyHops: number;
  /** Goods-received notes (StockFlow Stage 4). */
  receipts: {
    /** True: stock is added when a receipt is submitted, before verification (decision D3). */
    stockAvailableBeforeVerification: boolean;
    /** True: a receipt needs at least one document, unless an authorised user gives a reason. */
    documentRequired: boolean;
  };
  /** Receipt documents: where they are kept (outside the web app) and how large they may be. */
  attachments: { storageDir: string; maxBytes: number };
  /** Subsidiary orders (StockFlow Stage 5). */
  orders: {
    /**
     * True: an order may be approved although the Head Office has less stock than ordered (the
     * rest waits as a backorder). False: approval needs enough stock for every line.
     */
    allowBackorders: boolean;
  };
}

/** Private documents live here by default: inside the project, never inside the web app. */
export const DEFAULT_ATTACHMENT_DIR = fileURLToPath(
  new URL('../../../storage/attachments', import.meta.url),
);

const booleanSetting = (fallback: boolean) =>
  z
    .enum(['true', 'false'], { error: 'Must be true or false' })
    .optional()
    .transform((value) => (value === undefined ? fallback : value === 'true'));

/** Loads backend/.env for local development. Real environment variables take precedence. */
export function loadDotEnv(path = '.env'): void {
  if (existsSync(path)) {
    process.loadEnvFile(path);
  }
}

const corsOriginsSchema = z
  .string()
  .transform((value) =>
    value
      .split(',')
      .map((origin) => origin.trim())
      .filter((origin) => origin.length > 0),
  )
  .pipe(
    z
      .array(
        z.url({ error: 'Each origin must be a full URL such as http://localhost:8080' }).refine(
          // Zod still runs this check when z.url() fails; skip it then so only one error is shown.
          (origin) => !URL.canParse(origin) || new URL(origin).origin === origin,
          'Origins must not have a path or trailing slash (use http://localhost:8080, not http://localhost:8080/)',
        ),
      )
      .min(1, 'At least one origin is required'),
  );

// Messages are fixed text: a database URL contains a password, so it must never be echoed.
const postgresUrlSchema = z
  .string({ error: 'Required (see backend/.env.example)' })
  .refine(
    (value) => URL.canParse(value) && /^postgres(ql)?:$/.test(new URL(value).protocol),
    'Must be a PostgreSQL URL like postgres://user:password@localhost:5432/snackify_dev',
  );

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  CORS_ORIGINS: corsOriginsSchema.default(['http://localhost:8080']),
  DATABASE_URL: postgresUrlSchema,
  BUSINESS_TIMEZONE: z
    .string()
    .refine((zone) => {
      try {
        new Intl.DateTimeFormat('en', { timeZone: zone });
        return true;
      } catch {
        return false;
      }
    }, 'Must be a time zone name such as Africa/Harare')
    .default('Africa/Harare'),
  BILLING_WEEK_STARTS_ON: z
    .enum(['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'], {
      error: 'Must be a day of the week, e.g. monday',
    })
    .default('monday'),
  BASE_CURRENCY: z
    .string()
    .regex(/^[A-Z]{3}$/, 'Must be a 3-letter currency code such as USD')
    .default('USD'),
  PAYMENT_TERMS_DAYS: z.coerce
    .number({ error: 'Must be a whole number of days' })
    .int('Must be a whole number of days')
    .min(0, 'Must be 0 or more')
    .max(365, 'Must be at most 365')
    .default(7),
  BUSINESS_NAME: z.string().trim().min(1).max(100).default('Snackify'),
  BUSINESS_CONTACT: z.string().trim().max(200).optional(),
  WEB_APP_DIR: z
    .string()
    .trim()
    .min(1)
    .refine(
      (dir) => existsSync(join(dir, 'index.html')),
      'Must be a folder containing the built web app (index.html); run flutter build web',
    )
    .optional(),
  TRUST_PROXY_HOPS: z.coerce
    .number({ error: 'Must be a whole number' })
    .int('Must be a whole number')
    .min(0, 'Must be 0 or more')
    .max(5, 'Must be at most 5')
    .default(0),
  RECEIPT_STOCK_AVAILABLE_BEFORE_VERIFICATION: booleanSetting(true),
  RECEIPT_DOCUMENT_REQUIRED: booleanSetting(true),
  ATTACHMENT_MAX_BYTES: z.coerce
    .number({ error: 'Must be a whole number of bytes' })
    .int('Must be a whole number of bytes')
    .min(1024, 'Must be at least 1024')
    .max(50 * 1024 * 1024, 'Must be at most 52428800 (50 MB)')
    .default(10 * 1024 * 1024),
  ATTACHMENT_STORAGE_DIR: z.string().trim().min(1).optional(),
  ORDERS_ALLOW_BACKORDERS: booleanSetting(true),
});

const WEEKDAYS = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];

function invalidConfig(error: z.ZodError, path: string[] = []): Error {
  const problems = error.issues
    .map((issue) => `  - ${[...path, ...issue.path].join('.') || 'environment'}: ${issue.message}`)
    .join('\n');
  return new Error(`Invalid environment configuration:\n${problems}`);
}

/**
 * Reads and validates the API configuration from environment variables.
 * Throws an error naming each invalid variable; values are never echoed back,
 * so secrets cannot leak into logs.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const result = envSchema.safeParse(env);
  if (!result.success) {
    throw invalidConfig(result.error);
  }

  return {
    nodeEnv: result.data.NODE_ENV,
    port: result.data.PORT,
    corsOrigins: result.data.CORS_ORIGINS,
    databaseUrl: result.data.DATABASE_URL,
    businessTimezone: result.data.BUSINESS_TIMEZONE,
    billingWeekStartsOn: WEEKDAYS.indexOf(result.data.BILLING_WEEK_STARTS_ON) + 1,
    baseCurrency: result.data.BASE_CURRENCY,
    paymentTermsDays: result.data.PAYMENT_TERMS_DAYS,
    business: { name: result.data.BUSINESS_NAME, contact: result.data.BUSINESS_CONTACT || null },
    webAppDir: result.data.WEB_APP_DIR ?? null,
    trustProxyHops: result.data.TRUST_PROXY_HOPS,
    receipts: {
      stockAvailableBeforeVerification: result.data.RECEIPT_STOCK_AVAILABLE_BEFORE_VERIFICATION,
      documentRequired: result.data.RECEIPT_DOCUMENT_REQUIRED,
    },
    attachments: {
      storageDir: attachmentDir(result.data.ATTACHMENT_STORAGE_DIR, result.data.WEB_APP_DIR),
      maxBytes: result.data.ATTACHMENT_MAX_BYTES,
    },
    orders: { allowBackorders: result.data.ORDERS_ALLOW_BACKORDERS },
  };
}

/** Documents must never be inside the folder the web app is served from. */
function attachmentDir(configured: string | undefined, webAppDir: string | undefined): string {
  const dir = resolve(configured ?? DEFAULT_ATTACHMENT_DIR);
  if (webAppDir) {
    const web = resolve(webAppDir);
    if (dir === web || dir.startsWith(web + sep)) {
      throw new Error(
        'Invalid environment configuration:\n  - ATTACHMENT_STORAGE_DIR: Must not be inside WEB_APP_DIR',
      );
    }
  }
  return dir;
}

/** Reads one PostgreSQL URL variable, such as MIGRATION_DATABASE_URL, for scripts and tests. */
export function readDatabaseUrl(name: string, env: NodeJS.ProcessEnv = process.env): string {
  const result = postgresUrlSchema.safeParse(env[name]);
  if (!result.success) {
    throw invalidConfig(result.error, [name]);
  }
  return result.data;
}
