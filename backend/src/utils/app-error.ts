/**
 * An error that is safe to show to API clients.
 * Throw this from route handlers for expected failures (not found, validation, conflicts).
 * Any other error is treated as unexpected and returned as a generic 500.
 */
export class AppError extends Error {
  readonly statusCode: number;
  readonly code: string;
  readonly details?: unknown;

  constructor(statusCode: number, code: string, message: string, details?: unknown) {
    super(message);
    this.name = 'AppError';
    this.statusCode = statusCode;
    this.code = code;
    this.details = details;
  }
}
