import { createHash, randomBytes } from 'node:crypto';
import type { Queryable } from '../../database/transaction.js';
import type { PublicUser, Role } from './roles.js';

/** A session lasts one working day; staff sign in again after that. */
export const SESSION_LIFETIME_HOURS = 12;

// Tokens are 32 random bytes in base64url: always 43 characters.
const TOKEN_FORMAT = /^[A-Za-z0-9_-]{43}$/;

/** Only this hash is stored; the token itself is given to the client once and never saved. */
export function hashToken(token: string): Buffer {
  return createHash('sha256').update(token).digest();
}

export interface NewSession {
  id: string;
  token: string;
  expiresAt: Date;
}

export async function createSession(db: Queryable, userId: string): Promise<NewSession> {
  const token = randomBytes(32).toString('base64url');
  const { rows } = await db.query<{ id: string; expires_at: Date }>(
    `INSERT INTO sessions (user_id, token_hash, expires_at)
     VALUES ($1, $2, now() + make_interval(hours => $3))
     RETURNING id, expires_at`,
    [userId, hashToken(token), SESSION_LIFETIME_HOURS],
  );
  const row = rows[0];
  if (!row) throw new Error('Session was not created');
  return { id: row.id, token, expiresAt: row.expires_at };
}

export interface AuthContext {
  sessionId: string;
  user: PublicUser;
}

/** Finds the user for a token, if the session is current and the account is active. */
export async function findActiveSession(db: Queryable, token: string): Promise<AuthContext | null> {
  if (!TOKEN_FORMAT.test(token)) {
    return null;
  }
  const { rows } = await db.query<{
    session_id: string;
    id: string;
    username: string;
    full_name: string;
    role: Role;
  }>(
    `SELECT s.id AS session_id, u.id, u.username, u.full_name, u.role
     FROM sessions s
     JOIN users u ON u.id = s.user_id
     WHERE s.token_hash = $1
       AND s.revoked_at IS NULL
       AND s.expires_at > now()
       AND u.is_active`,
    [hashToken(token)],
  );
  const row = rows[0];
  if (!row) return null;
  return {
    sessionId: row.session_id,
    user: { id: row.id, username: row.username, fullName: row.full_name, role: row.role },
  };
}

export async function revokeSession(db: Queryable, sessionId: string): Promise<void> {
  await db.query('UPDATE sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL', [
    sessionId,
  ]);
}

/** Signs a user out everywhere, optionally keeping one session (the one making the request). */
export async function revokeUserSessions(
  db: Queryable,
  userId: string,
  exceptSessionId?: string,
): Promise<void> {
  await db.query(
    `UPDATE sessions SET revoked_at = now()
     WHERE user_id = $1 AND revoked_at IS NULL AND ($2::uuid IS NULL OR id <> $2)`,
    [userId, exceptSessionId ?? null],
  );
}
