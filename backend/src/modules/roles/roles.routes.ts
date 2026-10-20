import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { withTransaction } from '../../database/transaction.js';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { parseBody } from '../../utils/validation.js';
import { recordAudit } from '../audit/audit.js';
import { PERMISSIONS, type OrganisationType, type Permission } from '../auth/permissions.js';

export interface RoleView {
  code: string;
  name: string;
  description: string;
  organisationType: OrganisationType;
  permissions: Permission[];
}

/**
 * The System Administrator role must always be able to manage staff and roles, or nobody could
 * undo a mistake made here.
 */
const ALWAYS_KEPT: Record<string, Permission[]> = {
  system_admin: ['user.manage', 'role.manage'],
};

const permissionsSchema = z.object({
  permissions: z
    .array(z.enum(PERMISSIONS, { error: 'Unknown permission' }), {
      error: 'Must be a list of permission codes',
    })
    .max(PERMISSIONS.length)
    .transform((codes) => [...new Set(codes)].sort()),
});

async function listRoles(db: pg.Pool): Promise<RoleView[]> {
  const { rows } = await db.query<{
    code: string;
    name: string;
    description: string;
    organisation_type: OrganisationType;
    permissions: Permission[];
  }>(
    `SELECT r.code, r.name, r.description, r.organisation_type,
            COALESCE(array_agg(rp.permission_code ORDER BY rp.permission_code)
                     FILTER (WHERE rp.permission_code IS NOT NULL), '{}') AS permissions
     FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id
     GROUP BY r.id
     ORDER BY r.organisation_type, r.name`,
  );
  return rows.map((row) => ({
    code: row.code,
    name: row.name,
    description: row.description,
    organisationType: row.organisation_type,
    permissions: row.permissions,
  }));
}

/**
 * Roles and what they may do. Staff managers read them (to give roles); changing which
 * permissions a role has needs role.manage, applies to everyone holding the role at once, and
 * is audited.
 */
export function rolesRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('user.manage', 'role.manage'));

  router.get('/', async (_req, res) => {
    const { rows } = await db.query<{ code: Permission; description: string }>(
      'SELECT code, description FROM permissions ORDER BY code',
    );
    res.json({ roles: await listRoles(db), permissions: rows });
  });

  router.put('/:code/permissions', requirePermission('role.manage'), async (req, res) => {
    const { permissions } = parseBody(permissionsSchema, req.body);
    const code = req.params.code as string;
    const missing = (ALWAYS_KEPT[code] ?? []).filter((kept) => !permissions.includes(kept));
    if (missing.length > 0) {
      throw new AppError(409, 'PERMISSION_REQUIRED', `This role must keep ${missing.join(', ')}.`, [
        { field: 'permissions', message: `Must include ${missing.join(', ')}` },
      ]);
    }

    await withTransaction(db, async (client) => {
      const { rows } = await client.query<{ id: string }>(
        'SELECT id FROM roles WHERE code = $1 FOR UPDATE',
        [code],
      );
      const role = rows[0];
      if (!role) throw new AppError(404, 'ROLE_NOT_FOUND', 'No role has that code.');
      const { rows: before } = await client.query<{ permission_code: string }>(
        'SELECT permission_code FROM role_permissions WHERE role_id = $1 ORDER BY permission_code',
        [role.id],
      );
      await client.query('DELETE FROM role_permissions WHERE role_id = $1', [role.id]);
      await client.query(
        `INSERT INTO role_permissions (role_id, permission_code)
         SELECT $1, unnest($2::text[])`,
        [role.id, permissions],
      );
      await recordAudit(client, {
        actorUserId: getAuth(res).user.id,
        action: 'role.permissions_changed',
        entityType: 'role',
        entityId: role.id,
        details: { role: code, from: before.map((row) => row.permission_code), to: permissions },
      });
    });
    const role = (await listRoles(db)).find((candidate) => candidate.code === code);
    res.json({ role });
  });

  return router;
}
