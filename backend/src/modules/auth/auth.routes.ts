import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import type pg from 'pg';
import { z } from 'zod';
import { withTransaction } from '../../database/transaction.js';
import { getAuth, requireAuth } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { parseBody } from '../../utils/validation.js';
import { recordAudit } from '../audit/audit.js';
import { findUserForSignIn, getPasswordHash, setPassword } from '../users/users.service.js';
import { hashForUnknownUser, verifyPassword } from './passwords.js';
import { newPasswordSchema } from './roles.js';
import { createSession, revokeSession } from './sessions.js';

const signInSchema = z.object({
  username: z.string({ error: 'Required' }).trim().toLowerCase().min(1, 'Required').max(64),
  password: z.string({ error: 'Required' }).min(1, 'Required').max(128),
});

const changePasswordSchema = z.object({
  currentPassword: z.string({ error: 'Required' }).min(1, 'Required').max(128),
  newPassword: newPasswordSchema,
});

const invalidCredentials = () =>
  new AppError(401, 'INVALID_CREDENTIALS', 'Incorrect username or password.');

export function authRouter(db: pg.Pool): Router {
  const router = Router();

  // At most 10 failed password attempts per 15 minutes from one network address.
  // Successful sign-ins do not count, because staff often share one office connection.
  const passwordAttemptLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 10,
    skipSuccessfulRequests: true,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    handler: (_req, _res, next) => {
      next(
        new AppError(
          429,
          'TOO_MANY_ATTEMPTS',
          'Too many incorrect attempts. Please wait 15 minutes and try again.',
        ),
      );
    },
  });

  router.post('/login', passwordAttemptLimiter, async (req, res) => {
    const { username, password } = parseBody(signInSchema, req.body);
    const user = await findUserForSignIn(db, username);

    // Always check a password, even for unknown usernames, so timing does not reveal them.
    const passwordMatches = await verifyPassword(
      password,
      user?.passwordHash ?? (await hashForUnknownUser()),
    );

    if (!user || !user.isActive || !passwordMatches) {
      const reason = !user
        ? 'unknown_username'
        : !user.isActive
          ? 'account_inactive'
          : 'wrong_password';
      await recordAudit(db, {
        actorUserId: user?.id ?? null,
        action: 'auth.login_failed',
        organisationId: user?.organisation.id ?? null,
        details: { username, reason },
      });
      // The same answer in every case, so callers cannot tell which part was wrong.
      throw invalidCredentials();
    }

    const session = await withTransaction(db, async (client) => {
      const created = await createSession(client, user.id);
      await recordAudit(client, {
        actorUserId: user.id,
        action: 'auth.login',
        entityType: 'user',
        entityId: user.id,
        organisationId: user.organisation.id,
      });
      return created;
    });
    const publicUser = {
      id: user.id,
      username: user.username,
      fullName: user.fullName,
      organisation: user.organisation,
      roles: user.roles,
      permissions: user.permissions,
    };

    res.json({
      token: session.token,
      expiresAt: session.expiresAt,
      user: publicUser,
    });
  });

  router.post('/logout', requireAuth(db), async (_req, res) => {
    const { sessionId, user } = getAuth(res);
    await withTransaction(db, async (client) => {
      await revokeSession(client, sessionId);
      await recordAudit(client, {
        actorUserId: user.id,
        action: 'auth.logout',
        entityType: 'user',
        entityId: user.id,
      });
    });
    res.status(204).end();
  });

  router.get('/me', requireAuth(db), (_req, res) => {
    res.json({ user: getAuth(res).user });
  });

  router.post('/change-password', passwordAttemptLimiter, requireAuth(db), async (req, res) => {
    const { currentPassword, newPassword } = parseBody(changePasswordSchema, req.body);
    const { sessionId, user } = getAuth(res);

    if (!(await verifyPassword(currentPassword, await getPasswordHash(db, user.id)))) {
      throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
        { field: 'currentPassword', message: 'Incorrect password' },
      ]);
    }
    if (newPassword === currentPassword) {
      throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
        { field: 'newPassword', message: 'Must be different from the current password' },
      ]);
    }

    // Keep this session; sign out everywhere else.
    await setPassword(db, user.id, newPassword, {
      actorUserId: user.id,
      action: 'auth.password_changed',
      keepSessionId: sessionId,
    });
    res.status(204).end();
  });

  return router;
}
