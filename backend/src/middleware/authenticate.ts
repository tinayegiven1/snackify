import type { RequestHandler, Response } from 'express';
import type pg from 'pg';
import type { Role } from '../modules/auth/roles.js';
import { findActiveSession, type AuthContext } from '../modules/auth/sessions.js';
import { AppError } from '../utils/app-error.js';

/** Reads "Authorization: Bearer <token>". */
function bearerToken(header: string | undefined): string | null {
  const match = /^Bearer (\S+)$/.exec(header ?? '');
  return match?.[1] ?? null;
}

/** Rejects the request with 401 unless it carries a current session token. */
export function requireAuth(db: pg.Pool): RequestHandler {
  return async (req, res, next) => {
    const token = bearerToken(req.headers.authorization);
    if (!token) {
      throw new AppError(401, 'UNAUTHENTICATED', 'Please sign in.');
    }
    const auth = await findActiveSession(db, token);
    if (!auth) {
      throw new AppError(401, 'UNAUTHENTICATED', 'Your session has ended. Please sign in again.');
    }
    res.locals.auth = auth;
    next();
  };
}

/**
 * Rejects the request with 403 unless the user has one of `roles`. Admins are always allowed.
 * Must come after requireAuth. Permissions are enforced here, never only by hiding buttons.
 */
export function requireRole(...roles: Role[]): RequestHandler {
  return (_req, res, next) => {
    const { user } = getAuth(res);
    if (user.role !== 'admin' && !roles.includes(user.role)) {
      throw new AppError(403, 'FORBIDDEN', 'Your role does not allow this action.');
    }
    next();
  };
}

/** The signed-in user and session for this request (set by requireAuth). */
export function getAuth(res: Response): AuthContext {
  const auth = res.locals.auth as AuthContext | undefined;
  if (!auth) {
    throw new Error('getAuth() used on a route without requireAuth');
  }
  return auth;
}
