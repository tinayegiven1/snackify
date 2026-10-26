import type { RequestHandler, Response } from 'express';
import type pg from 'pg';
import type { Permission } from '../modules/auth/permissions.js';
import type { PublicUser } from '../modules/auth/roles.js';
import { findActiveSession, type AuthContext } from '../modules/auth/sessions.js';
import { AppError } from '../utils/app-error.js';
import { currentRequest } from '../utils/request-context.js';

/** Reads "Authorization: Bearer <token>". */
function bearerToken(header: string | undefined): string | null {
  const match = /^Bearer (\S+)$/.exec(header ?? '');
  return match?.[1] ?? null;
}

/**
 * Rejects the request with 401 unless it carries a current session token. Only the
 * Authorization header is read, never cookies, so another website cannot make a signed-in
 * browser act on Snackify (no cross-site request forgery).
 */
export function requireAuth(
  db: pg.Pool,
  options: {
    /** For the few routes an account on the default PIN may use: me, sign out, change PIN. */
    allowDefaultPin?: boolean;
  } = {},
): RequestHandler {
  return async (req, res, next) => {
    const token = bearerToken(req.headers.authorization);
    if (!token) {
      throw new AppError(401, 'UNAUTHENTICATED', 'Please sign in.');
    }
    const auth = await findActiveSession(db, token);
    if (!auth) {
      throw new AppError(401, 'UNAUTHENTICATED', 'Your session has ended. Please sign in again.');
    }
    // The default PIN is public: until it is changed, the account can do nothing else.
    if (auth.user.mustChangePin && !options.allowDefaultPin) {
      throw new AppError(
        403,
        'PIN_CHANGE_REQUIRED',
        'Choose your own PIN first (POST /api/v1/auth/change-pin).',
      );
    }
    res.locals.auth = auth;
    const request = currentRequest();
    if (request) request.organisationId = auth.user.organisation.id;
    next();
  };
}

/** True when the user holds `permission` through any of their roles. */
export function can(user: PublicUser, permission: Permission): boolean {
  return user.permissions.includes(permission);
}

export const forbidden = () =>
  new AppError(403, 'FORBIDDEN', 'Your role does not allow this action.');

/**
 * Rejects the request with 403 unless the user has at least one of `permissions`. Must come
 * after requireAuth. Permissions are enforced here, never only by hiding buttons.
 */
export function requirePermission(...permissions: Permission[]): RequestHandler {
  return (_req, res, next) => {
    const { user } = getAuth(res);
    if (!permissions.some((permission) => can(user, permission))) throw forbidden();
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
