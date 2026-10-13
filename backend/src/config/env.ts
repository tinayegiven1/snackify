import { existsSync } from 'node:fs';
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
}

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
  };
}

/** Reads one PostgreSQL URL variable, such as MIGRATION_DATABASE_URL, for scripts and tests. */
export function readDatabaseUrl(name: string, env: NodeJS.ProcessEnv = process.env): string {
  const result = postgresUrlSchema.safeParse(env[name]);
  if (!result.success) {
    throw invalidConfig(result.error, [name]);
  }
  return result.data;
}
