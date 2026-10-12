import type pg from 'pg';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { changedFields, recordAudit, type AuditAction } from '../audit/audit.js';
import { hashPassword } from '../auth/passwords.js';
import type { PublicUser, Role } from '../auth/roles.js';
import { revokeUserSessions } from '../auth/sessions.js';

/** A staff account as shown to admins. */
export interface StaffUser extends PublicUser {
  isActive: boolean;
  createdAt: Date;
  lastSignInAt: Date | null;
}

interface StaffUserRow {
  id: string;
  username: string;
  full_name: string;
  role: Role;
  is_active: boolean;
  created_at: Date;
  last_sign_in_at: Date | null;
}

const STAFF_USER_COLUMNS = `
  u.id, u.username, u.full_name, u.role, u.is_active, u.created_at,
  (SELECT max(s.created_at) FROM sessions s WHERE s.user_id = u.id) AS last_sign_in_at`;

function toStaffUser(row: StaffUserRow): StaffUser {
  return {
    id: row.id,
    username: row.username,
    fullName: row.full_name,
    role: row.role,
    isActive: row.is_active,
    createdAt: row.created_at,
    lastSignInAt: row.last_sign_in_at,
  };
}

const userNotFound = () => new AppError(404, 'USER_NOT_FOUND', 'No staff account has that id.');

export async function listUsers(db: Queryable): Promise<StaffUser[]> {
  const { rows } = await db.query<StaffUserRow>(
    `SELECT ${STAFF_USER_COLUMNS} FROM users u ORDER BY u.is_active DESC, u.full_name`,
  );
  return rows.map(toStaffUser);
}

export async function findUserById(db: Queryable, id: string): Promise<StaffUser | null> {
  const { rows } = await db.query<StaffUserRow>(
    `SELECT ${STAFF_USER_COLUMNS} FROM users u WHERE u.id = $1`,
    [id],
  );
  return rows[0] ? toStaffUser(rows[0]) : null;
}

/** Everything needed to check a sign-in, including the password hash. Never send this out. */
export async function findUserForSignIn(
  db: Queryable,
  username: string,
): Promise<(PublicUser & { isActive: boolean; passwordHash: string }) | null> {
  const { rows } = await db.query<StaffUserRow & { password_hash: string }>(
    `SELECT id, username, full_name, role, is_active, password_hash FROM users WHERE username = $1`,
    [username],
  );
  const row = rows[0];
  if (!row) return null;
  return {
    id: row.id,
    username: row.username,
    fullName: row.full_name,
    role: row.role,
    isActive: row.is_active,
    passwordHash: row.password_hash,
  };
}

export async function getPasswordHash(db: Queryable, userId: string): Promise<string> {
  const { rows } = await db.query<{ password_hash: string }>(
    'SELECT password_hash FROM users WHERE id = $1',
    [userId],
  );
  if (!rows[0]) throw userNotFound();
  return rows[0].password_hash;
}

export interface NewUserInput {
  username: string;
  fullName: string;
  role: Role;
  password: string;
}

/** Creates a staff account. `actorUserId` is null when created by the setup command. */
export async function createUser(
  pool: pg.Pool,
  input: NewUserInput,
  audit: { actorUserId: string | null; via: 'api' | 'cli' },
): Promise<StaffUser> {
  const passwordHash = await hashPassword(input.password);

  try {
    return await withTransaction(pool, async (client) => {
      const { rows } = await client.query<StaffUserRow>(
        `INSERT INTO users (username, full_name, role, password_hash)
         VALUES ($1, $2, $3, $4)
         RETURNING id, username, full_name, role, is_active, created_at, NULL AS last_sign_in_at`,
        [input.username, input.fullName, input.role, passwordHash],
      );
      const user = toStaffUser(rows[0] as StaffUserRow);
      await recordAudit(client, {
        actorUserId: audit.actorUserId,
        action: 'user.created',
        entityType: 'user',
        entityId: user.id,
        details: { username: user.username, role: user.role, via: audit.via },
      });
      return user;
    });
  } catch (error) {
    if (isUniqueViolation(error, 'users_username_key')) {
      throw new AppError(
        409,
        'USERNAME_TAKEN',
        `The username "${input.username}" is already taken.`,
      );
    }
    throw error;
  }
}

export interface UserChanges {
  fullName?: string | undefined;
  role?: Role | undefined;
  isActive?: boolean | undefined;
}

/**
 * Changes a staff account's name, role or active status. Deactivating signs the user out
 * everywhere at once. Admins cannot change their own role or deactivate themselves, so the
 * business can never be left without an active admin.
 */
export async function updateUser(
  pool: pg.Pool,
  userId: string,
  changes: UserChanges,
  actor: PublicUser,
): Promise<StaffUser> {
  const changesOwnAccess =
    (changes.role !== undefined && changes.role !== actor.role) || changes.isActive === false;
  if (userId === actor.id && changesOwnAccess) {
    throw new AppError(
      409,
      'CANNOT_CHANGE_OWN_ACCESS',
      'You cannot change your own role or deactivate your own account. Ask another admin.',
    );
  }

  await withTransaction(pool, async (client) => {
    const { rows } = await client.query<Pick<StaffUserRow, 'full_name' | 'role' | 'is_active'>>(
      'SELECT full_name, role, is_active FROM users WHERE id = $1 FOR UPDATE',
      [userId],
    );
    const before = rows[0];
    if (!before) throw userNotFound();

    const after = {
      fullName: changes.fullName ?? before.full_name,
      role: changes.role ?? before.role,
      isActive: changes.isActive ?? before.is_active,
    };
    await client.query('UPDATE users SET full_name = $2, role = $3, is_active = $4 WHERE id = $1', [
      userId,
      after.fullName,
      after.role,
      after.isActive,
    ]);

    if (before.is_active && !after.isActive) {
      await revokeUserSessions(client, userId);
    }

    const beforeValues = {
      fullName: before.full_name,
      role: before.role,
      isActive: before.is_active,
    };
    await recordAudit(client, {
      actorUserId: actor.id,
      action: 'user.updated',
      entityType: 'user',
      entityId: userId,
      details: { changes: changedFields(beforeValues, after) },
    });
  });

  const user = await findUserById(pool, userId);
  if (!user) throw userNotFound();
  return user;
}

/**
 * Sets a new password and signs the user out of every other session.
 * Used by admins resetting a password, and by users changing their own.
 */
export async function setPassword(
  pool: pg.Pool,
  userId: string,
  newPassword: string,
  audit: {
    actorUserId: string;
    action: Extract<AuditAction, 'user.password_reset' | 'auth.password_changed'>;
    keepSessionId?: string;
  },
): Promise<void> {
  const passwordHash = await hashPassword(newPassword);

  await withTransaction(pool, async (client) => {
    const { rowCount } = await client.query('UPDATE users SET password_hash = $2 WHERE id = $1', [
      userId,
      passwordHash,
    ]);
    if (rowCount === 0) throw userNotFound();

    await revokeUserSessions(client, userId, audit.keepSessionId);
    await recordAudit(client, {
      actorUserId: audit.actorUserId,
      action: audit.action,
      entityType: 'user',
      entityId: userId,
    });
  });
}
