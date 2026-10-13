import { z } from 'zod';
import type { AppError } from './app-error.js';

/**
 * Money as an exact decimal string such as "0.50": 0 or more, at most 2 decimal places.
 * A JSON number (0.5) is also accepted and turned into text before checking.
 */
export const moneySchema = z
  .union([z.string(), z.number()], { error: 'Required' })
  .transform((value) => String(value).trim())
  .refine(
    (value) => /^\d{1,10}(\.\d{1,2})?$/.test(value),
    // Stop here when the format is wrong, so later checks (e.g. "more than 0") add no noise.
    { message: 'Use an amount of 0 or more with up to 2 decimal places, e.g. 0.50', abort: true },
  );

/** Optional text: trimmed, and empty text or null counts as "not given" (null). */
export const optionalText = (max: number) =>
  z
    .string({ error: 'Must be text' })
    .trim()
    .max(max, `Use at most ${max} characters`)
    .nullish()
    .transform((value) => value || null);

/** Checks an id from the URL. An invalid id cannot match any record, so it is "not found". */
export function parseIdParam(id: unknown, notFound: () => AppError): string {
  const result = z.uuid().safeParse(id);
  if (!result.success) throw notFound();
  return result.data;
}
