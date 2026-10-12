import type { z } from 'zod';
import { AppError } from './app-error.js';

/**
 * Validates a request body against `schema`. On failure throws a 400 VALIDATION_ERROR
 * listing each invalid field. Messages describe the rule, never the submitted value.
 */
export function parseBody<T extends z.ZodType>(schema: T, body: unknown): z.infer<T> {
  const result = schema.safeParse(body ?? {});
  if (!result.success) {
    throw new AppError(
      400,
      'VALIDATION_ERROR',
      'Some fields are missing or invalid.',
      result.error.issues.map((issue) => ({
        field: issue.path.join('.'),
        message: issue.message,
      })),
    );
  }
  return result.data;
}
