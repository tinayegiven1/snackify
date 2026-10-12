import type { ErrorRequestHandler } from 'express';
import { AppError } from '../utils/app-error.js';
import { logger } from '../utils/logger.js';

/**
 * Every API error uses this shape:
 *   { "error": { "code": "NOT_FOUND", "message": "...", "details": ... } }
 */
interface ErrorBody {
  error: { code: string; message: string; details?: unknown };
}

/** Errors raised by express.json() carry a `type` string. */
function bodyParserErrorType(err: unknown): string | undefined {
  if (typeof err === 'object' && err !== null && 'type' in err && typeof err.type === 'string') {
    return err.type;
  }
  return undefined;
}

export const errorHandler: ErrorRequestHandler = (err, req, res, next) => {
  if (res.headersSent) {
    next(err);
    return;
  }

  if (err instanceof AppError) {
    const body: ErrorBody = { error: { code: err.code, message: err.message } };
    if (err.details !== undefined) body.error.details = err.details;
    res.status(err.statusCode).json(body);
    return;
  }

  switch (bodyParserErrorType(err)) {
    case 'entity.parse.failed':
      res
        .status(400)
        .json({ error: { code: 'INVALID_JSON', message: 'The request body is not valid JSON.' } });
      return;
    case 'entity.too.large':
      res
        .status(413)
        .json({ error: { code: 'PAYLOAD_TOO_LARGE', message: 'The request body is too large.' } });
      return;
  }

  // Unexpected error: log the details on the server, but never send them to the client.
  logger.error('Unhandled error', {
    method: req.method,
    path: req.path,
    error: err instanceof Error ? { name: err.name, message: err.message, stack: err.stack } : err,
  });
  res.status(500).json({
    error: { code: 'INTERNAL_ERROR', message: 'Something went wrong. Please try again.' },
  });
};
