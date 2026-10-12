import { z } from 'zod';

export interface AppConfig {
  nodeEnv: 'development' | 'test' | 'production';
  port: number;
  /** Browser origins allowed to call the API (e.g. the Flutter web dev server). */
  corsOrigins: string[];
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

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  CORS_ORIGINS: corsOriginsSchema.default(['http://localhost:8080']),
});

/**
 * Reads and validates configuration from environment variables.
 * Throws an error naming each invalid variable; values are never echoed back,
 * so secrets added later cannot leak into logs.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const result = envSchema.safeParse(env);

  if (!result.success) {
    const problems = result.error.issues
      .map((issue) => `  - ${issue.path.join('.') || 'environment'}: ${issue.message}`)
      .join('\n');
    throw new Error(`Invalid environment configuration:\n${problems}`);
  }

  return {
    nodeEnv: result.data.NODE_ENV,
    port: result.data.PORT,
    corsOrigins: result.data.CORS_ORIGINS,
  };
}
