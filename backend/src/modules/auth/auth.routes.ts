import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import type pg from 'pg';
import { z } from 'zod';
import { withTransaction } from '../../database/transaction.js';
import { getAuth, requireAuth } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { parseBody } from '../../utils/validation.js';
import { recordAudit } from '../audit/audit.js';
import {
  clearFailedPins,
  findUserForSignIn,
  getPasswordHash,
  recordFailedPin,
  setPin,
} from '../users/users.service.js';
import { hashForUnknownUser, verifyPassword } from './passwords.js';
import { newPinSchema, pinSchema } from './roles.js';
import { createSession, revokeSession } from './sessions.js';

const signInSchema = z.object({
  username: z.string({ error: 'Required' }).trim().toLowerCase().min(1, 'Required').max(64),
  pin: pinSchema,
});

const changePinSchema = z.object({
  currentPin: pinSchema,
  newPin: newPinSchema,
});

const invalidCredentials = () =>
  new AppError(401, 'INVALID_CREDENTIALS', 'Incorrect username or PIN.');

const accountLocked = () =>
  new AppError(
    423,
    'ACCOUNT_LOCKED',
    'Too many wrong PINs. This account is locked for 15 minutes; an admin can reset the PIN.',
  );

export function authRouter(db: pg.Pool): Router {
  const router = Router();

  // At most 10 failed PIN attempts per 15 minutes from one network address (each account also
  // locks after 5 wrong PINs in a row).
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
    const { username, pin } = parseBody(signInSchema, req.body);
    const user = await findUserForSignIn(db, username);

    // Always check a PIN, even for unknown usernames, so timing does not reveal them.
    const pinMatches = await verifyPassword(pin, user?.pinHash ?? (await hashForUnknownUser()));

    if (user?.locked) {
      await recordAudit(db, {
        actorUserId: user.id,
        action: 'auth.login_failed',
        organisationId: user.organisation.id,
        details: { username, reason: 'account_locked' },
      });
      throw accountLocked();
    }
    if (!user || !user.isActive || !pinMatches) {
      const reason = !user ? 'unknown_username' : !user.isActive ? 'account_inactive' : 'wrong_pin';
      await recordAudit(db, {
        actorUserId: user?.id ?? null,
        action: 'auth.login_failed',
        organisationId: user?.organisation.id ?? null,
        details: { username, reason },
      });
      if (user && reason === 'wrong_pin' && (await recordFailedPin(db, user.id))) {
        await recordAudit(db, {
          actorUserId: user.id,
          action: 'auth.account_locked',
          entityType: 'user',
          entityId: user.id,
          organisationId: user.organisation.id,
          details: { username },
        });
        throw accountLocked();
      }
      // The same answer in every case, so callers cannot tell which part was wrong.
      throw invalidCredentials();
    }
    await clearFailedPins(db, user.id);

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
      mustChangePin: user.mustChangePin,
    };

    res.json({
      token: session.token,
      expiresAt: session.expiresAt,
      user: publicUser,
    });
  });

  router.post('/logout', requireAuth(db, { allowDefaultPin: true }), async (_req, res) => {
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

  router.get('/me', requireAuth(db, { allowDefaultPin: true }), (_req, res) => {
    res.json({ user: getAuth(res).user });
  });

  // Choosing your own PIN; also the first thing an account on the default PIN must do.
  router.post(
    '/change-pin',
    passwordAttemptLimiter,
    requireAuth(db, { allowDefaultPin: true }),
    async (req, res) => {
      const { currentPin, newPin } = parseBody(changePinSchema, req.body);
      const { sessionId, user } = getAuth(res);

      if (!(await verifyPassword(currentPin, await getPasswordHash(db, user.id)))) {
        throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
          { field: 'currentPin', message: 'Incorrect PIN' },
        ]);
      }
      if (newPin === currentPin) {
        throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
          { field: 'newPin', message: 'Must be different from the current PIN' },
        ]);
      }

      // Keep this session; sign out everywhere else.
      await setPin(db, user.id, newPin, {
        actorUserId: user.id,
        action: 'auth.pin_changed',
        keepSessionId: sessionId,
      });
      res.json({ user: { ...user, mustChangePin: false } });
    },
  );

  return router;
}
