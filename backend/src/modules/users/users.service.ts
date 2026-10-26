import type pg from 'pg';
import { isUniqueViolation, withTransaction, type Queryable } from '../../database/transaction.js';
import { AppError } from '../../utils/app-error.js';
import { changedFields, recordAudit, type AuditAction } from '../audit/audit.js';
import { hashPassword } from '../auth/passwords.js';
import { DEFAULT_PIN } from '../auth/roles.js';
import type { OrganisationRef, RoleRef } from '../auth/permissions.js';
import type { PublicUser } from '../auth/roles.js';
import { revokeUserSessions } from '../auth/sessions.js';
import {
  organisationRef,
  toPublicUser,
  USER_ACCESS_COLUMNS,
  type UserAccessRow,
} from '../auth/user-access.js';
import { canAccessOrganisation, type AccessScope } from '../organisations/access.js';

/** A staff account as shown to admins. */
export interface StaffUser {
  id: string;
  username: string;
  fullName: string;
  organisation: OrganisationRef;
  roles: RoleRef[];
  isActive: boolean;
  createdAt: Date;
  lastSignInAt: Date | null;
}

interface StaffUserRow extends UserAccessRow {
  is_active: boolean;
  created_at: Date;
  last_sign_in_at: Date | null;
}

const STAFF_USER_SELECT = `
  SELECT u.id, u.username, u.full_name, u.is_active, u.created_at,
         (SELECT max(s.created_at) FROM sessions s WHERE s.user_id = u.id) AS last_sign_in_at,
         ${USER_ACCESS_COLUMNS}
  FROM users u
  JOIN organisations o ON o.id = u.organisation_id`;

function toStaffUser(row: StaffUserRow): StaffUser {
  return {
    id: row.id,
    username: row.username,
    fullName: row.full_name,
    organisation: organisationRef(row),
    roles: row.roles,
    isActive: row.is_active,
    createdAt: row.created_at,
    lastSignInAt: row.last_sign_in_at,
  };
}

const userNotFound = () => new AppError(404, 'USER_NOT_FOUND', 'No staff account has that id.');

function fieldError(field: string, message: string): AppError {
  return new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
    { field, message },
  ]);
}

/** Staff the user may see: everyone for the Head Office, otherwise their own organisation's. */
export async function listUsers(
  db: Queryable,
  scope: AccessScope,
  filter: { organisationId?: string | undefined } = {},
): Promise<StaffUser[]> {
  const params: unknown[] = [];
  const conditions: string[] = [];
  if (!scope.allOrganisations) {
    params.push(scope.organisationId);
    conditions.push(`u.organisation_id = $${params.length}`);
  }
  if (filter.organisationId) {
    params.push(filter.organisationId);
    conditions.push(`u.organisation_id = $${params.length}`);
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const { rows } = await db.query<StaffUserRow>(
    `${STAFF_USER_SELECT} ${where}
     ORDER BY u.is_active DESC, o.organisation_type, o.name, u.full_name`,
    params,
  );
  return rows.map(toStaffUser);
}

export async function findUserById(db: Queryable, id: string): Promise<StaffUser | null> {
  const { rows } = await db.query<StaffUserRow>(`${STAFF_USER_SELECT} WHERE u.id = $1`, [id]);
  return rows[0] ? toStaffUser(rows[0]) : null;
}

/** Everything needed to check a sign-in, including the PIN hash. Never send this out. */
export async function findUserForSignIn(
  db: Queryable,
  username: string,
): Promise<(PublicUser & { isActive: boolean; pinHash: string; locked: boolean }) | null> {
  const { rows } = await db.query<
    UserAccessRow & {
      is_active: boolean;
      organisation_active: boolean;
      password_hash: string;
      locked: boolean;
    }
  >(
    `SELECT u.id, u.username, u.full_name, u.is_active, u.password_hash,
            COALESCE(u.locked_until > now(), false) AS locked,
            o.is_active AS organisation_active, ${USER_ACCESS_COLUMNS}
     FROM users u
     JOIN organisations o ON o.id = u.organisation_id
     WHERE u.username = $1`,
    [username],
  );
  const row = rows[0];
  if (!row) return null;
  return {
    ...toPublicUser(row),
    // Staff of a deactivated organisation cannot sign in either.
    isActive: row.is_active && row.organisation_active,
    pinHash: row.password_hash,
    locked: row.locked,
  };
}

/** Wrong PINs allowed in a row before the account is locked. */
export const MAX_FAILED_PINS = 5;

/**
 * Counts a wrong PIN. The fifth in a row locks the account for 15 minutes (and starts the count
 * again). Returns true when this attempt locked it.
 */
export async function recordFailedPin(db: Queryable, userId: string): Promise<boolean> {
  const { rows } = await db.query<{ locked: boolean }>(
    `UPDATE users
     SET failed_pin_attempts = CASE WHEN failed_pin_attempts + 1 >= $2 THEN 0
                                    ELSE failed_pin_attempts + 1 END,
         locked_until = CASE WHEN failed_pin_attempts + 1 >= $2
                             THEN now() + interval '15 minutes' ELSE locked_until END
     WHERE id = $1
     RETURNING failed_pin_attempts = 0 AND locked_until > now() AS locked`,
    [userId, MAX_FAILED_PINS],
  );
  return rows[0]?.locked ?? false;
}

/** A correct PIN starts the count of wrong ones again. */
export async function clearFailedPins(db: Queryable, userId: string): Promise<void> {
  await db.query(
    'UPDATE users SET failed_pin_attempts = 0, locked_until = NULL WHERE id = $1 AND (failed_pin_attempts > 0 OR locked_until IS NOT NULL)',
    [userId],
  );
}

export async function getPasswordHash(db: Queryable, userId: string): Promise<string> {
  const { rows } = await db.query<{ password_hash: string }>(
    'SELECT password_hash FROM users WHERE id = $1',
    [userId],
  );
  if (!rows[0]) throw userNotFound();
  return rows[0].password_hash;
}

interface OrganisationInfo {
  id: string;
  code: string;
  organisation_type: string;
  is_active: boolean;
}

async function findOrganisation(db: Queryable, id: string): Promise<OrganisationInfo | null> {
  const { rows } = await db.query<OrganisationInfo>(
    'SELECT id, code, organisation_type, is_active FROM organisations WHERE id = $1',
    [id],
  );
  return rows[0] ?? null;
}

/**
 * Turns role codes into role ids, checking each exists and suits the organisation's type: a
 * subsidiary's staff can never hold a Head Office role (the database checks this too).
 */
async function resolveRoles(
  db: Queryable,
  codes: string[],
  organisation: OrganisationInfo,
): Promise<{ id: string; code: string }[]> {
  const { rows } = await db.query<{ id: string; code: string; organisation_type: string }>(
    'SELECT id, code, organisation_type FROM roles WHERE code = ANY($1::text[])',
    [codes],
  );
  const unknown = codes.filter((code) => !rows.some((row) => row.code === code));
  if (unknown.length > 0) throw fieldError('roleCodes', `Unknown role: ${unknown.join(', ')}`);
  const unsuitable = rows.filter((row) => row.organisation_type !== organisation.organisation_type);
  if (unsuitable.length > 0) {
    throw fieldError(
      'roleCodes',
      organisation.organisation_type === 'HQ'
        ? `${unsuitable.map((r) => r.code).join(', ')} is for a subsidiary's staff`
        : `${unsuitable.map((r) => r.code).join(', ')} is for Head Office staff`,
    );
  }
  return rows.map(({ id, code }) => ({ id, code }));
}

export interface NewUserInput {
  username: string;
  fullName: string;
  organisationId: string;
  roleCodes: string[];
  /**
   * The first PIN. Left out, the account starts on the default PIN and must choose its own
   * at the first sign-in (the normal case; tests and tools may set one).
   */
  pin?: string;
}

/** Creates a staff account. `actorUserId` is null when created by the setup command. */
export async function createUser(
  pool: pg.Pool,
  input: NewUserInput,
  audit: { actorUserId: string | null; via: 'api' | 'cli' },
): Promise<StaffUser> {
  const passwordHash = await hashPassword(input.pin ?? DEFAULT_PIN);
  const mustChangePin = input.pin === undefined;

  try {
    const userId = await withTransaction(pool, async (client) => {
      const organisation = await findOrganisation(client, input.organisationId);
      if (!organisation) throw fieldError('organisationId', 'No organisation has that id');
      if (!organisation.is_active) {
        throw fieldError('organisationId', 'This organisation is deactivated');
      }
      const roles = await resolveRoles(client, input.roleCodes, organisation);

      const { rows } = await client.query<{ id: string }>(
        `INSERT INTO users (username, full_name, organisation_id, password_hash, must_change_pin)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id`,
        [input.username, input.fullName, organisation.id, passwordHash, mustChangePin],
      );
      const id = (rows[0] as { id: string }).id;
      await client.query(
        `INSERT INTO user_roles (user_id, role_id, granted_by)
         SELECT $1, unnest($2::uuid[]), $3`,
        [id, roles.map((role) => role.id), audit.actorUserId],
      );
      await recordAudit(client, {
        actorUserId: audit.actorUserId,
        action: 'user.created',
        entityType: 'user',
        entityId: id,
        organisationId: organisation.id,
        details: {
          username: input.username,
          organisation: organisation.code,
          roles: input.roleCodes,
          via: audit.via,
        },
      });
      return id;
    });
    return (await findUserById(pool, userId)) as StaffUser;
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
  organisationId?: string | undefined;
  roleCodes?: string[] | undefined;
  isActive?: boolean | undefined;
}

/**
 * Changes a staff account's name, organisation, roles or active status. Deactivating signs the
 * user out everywhere at once. Admins cannot change their own roles or organisation, or
 * deactivate themselves, so the business can never be left without an active admin.
 */
export async function updateUser(
  pool: pg.Pool,
  userId: string,
  changes: UserChanges,
  actor: PublicUser,
): Promise<StaffUser> {
  if (userId === actor.id) {
    const ownRoles = actor.roles.map((role) => role.code).sort();
    const changesOwnAccess =
      (changes.roleCodes !== undefined && changes.roleCodes.join() !== ownRoles.join()) ||
      (changes.organisationId !== undefined && changes.organisationId !== actor.organisation.id) ||
      changes.isActive === false;
    if (changesOwnAccess) {
      throw new AppError(
        409,
        'CANNOT_CHANGE_OWN_ACCESS',
        'You cannot change your own roles or organisation, or deactivate your own account. ' +
          'Ask another admin.',
      );
    }
  }

  await withTransaction(pool, async (client) => {
    const { rows } = await client.query<{
      full_name: string;
      organisation_id: string;
      is_active: boolean;
    }>('SELECT full_name, organisation_id, is_active FROM users WHERE id = $1 FOR UPDATE', [
      userId,
    ]);
    const before = rows[0];
    if (!before) throw userNotFound();
    const { rows: roleRows } = await client.query<{ code: string }>(
      `SELECT r.code FROM user_roles ur JOIN roles r ON r.id = ur.role_id
       WHERE ur.user_id = $1 ORDER BY r.code`,
      [userId],
    );
    const rolesBefore = roleRows.map((row) => row.code);

    const organisationId = changes.organisationId ?? before.organisation_id;
    const organisation = await findOrganisation(client, organisationId);
    if (!organisation) throw fieldError('organisationId', 'No organisation has that id');
    const roleCodes = changes.roleCodes ?? rolesBefore;
    // Checked whenever the organisation or the roles change, so they always suit each other.
    const roles =
      changes.roleCodes !== undefined || organisationId !== before.organisation_id
        ? await resolveRoles(client, roleCodes, organisation)
        : null;

    const after = {
      fullName: changes.fullName ?? before.full_name,
      organisationId,
      isActive: changes.isActive ?? before.is_active,
    };
    if (roles) await client.query('DELETE FROM user_roles WHERE user_id = $1', [userId]);
    await client.query(
      'UPDATE users SET full_name = $2, organisation_id = $3, is_active = $4 WHERE id = $1',
      [userId, after.fullName, after.organisationId, after.isActive],
    );
    if (roles) {
      await client.query(
        `INSERT INTO user_roles (user_id, role_id, granted_by)
         SELECT $1, unnest($2::uuid[]), $3`,
        [userId, roles.map((role) => role.id), actor.id],
      );
    }

    const movedOrDeactivated =
      (before.is_active && !after.isActive) || organisationId !== before.organisation_id;
    if (movedOrDeactivated) await revokeUserSessions(client, userId);

    const fieldChanges = changedFields(
      {
        fullName: before.full_name,
        organisationId: before.organisation_id,
        isActive: before.is_active,
      },
      after,
    );
    if (Object.keys(fieldChanges).length > 0) {
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'user.updated',
        entityType: 'user',
        entityId: userId,
        details: { changes: fieldChanges },
      });
    }
    if (roles && roleCodes.join() !== rolesBefore.join()) {
      await recordAudit(client, {
        actorUserId: actor.id,
        action: 'user.roles_changed',
        entityType: 'user',
        entityId: userId,
        details: { from: rolesBefore, to: roleCodes },
      });
    }
  });

  const user = await findUserById(pool, userId);
  if (!user) throw userNotFound();
  return user;
}

/** Whether `actor` may manage the account `userId` (it is in an organisation they can see). */
export async function assertUserInScope(
  db: Queryable,
  scope: AccessScope,
  userId: string,
): Promise<void> {
  const user = await findUserById(db, userId);
  if (!user || !canAccessOrganisation(scope, user.organisation.id)) throw userNotFound();
}

/**
 * Sets a PIN and signs the user out of every other session. A user choosing their own PIN
 * passes it; an admin's reset leaves it out, which puts the account back on the default PIN
 * (to be changed at the next sign-in) and unlocks it.
 */
export async function setPin(
  pool: pg.Pool,
  userId: string,
  newPin: string | null,
  audit: {
    actorUserId: string;
    action: Extract<AuditAction, 'user.pin_reset' | 'auth.pin_changed'>;
    keepSessionId?: string;
  },
): Promise<void> {
  const pinHash = await hashPassword(newPin ?? DEFAULT_PIN);

  await withTransaction(pool, async (client) => {
    const { rowCount } = await client.query(
      `UPDATE users SET password_hash = $2, must_change_pin = $3, failed_pin_attempts = 0,
              locked_until = NULL
       WHERE id = $1`,
      [userId, pinHash, newPin === null],
    );
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
