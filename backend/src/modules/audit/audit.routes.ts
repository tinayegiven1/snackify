import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { parseBody } from '../../utils/validation.js';
import { scopeOf } from '../organisations/access.js';

const querySchema = z.object({
  from: z.iso.date({ error: 'Use a date like 2026-10-20' }).optional(),
  to: z.iso.date({ error: 'Use a date like 2026-10-20' }).optional(),
  action: z
    .string()
    .regex(/^[a-z_]+(\.[a-z_]+)?$/, 'Use an action like user.created, or a group like stock')
    .optional(),
  userId: z.uuid({ error: 'Must be a user id' }).optional(),
  organisationId: z.uuid({ error: 'Must be an organisation id' }).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

export interface AuditLogEntry {
  id: string;
  occurredAt: Date;
  action: string;
  actor: { id: string; fullName: string } | null;
  organisation: { id: string; code: string } | null;
  entityType: string | null;
  entityId: string | null;
  details: Record<string, unknown>;
  ipAddress: string | null;
}

/** Reading the audit log (permission audit.view), newest first, with filters and paging. */
export function auditRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('audit.view'));

  router.get('/', async (req, res) => {
    const query = parseBody(querySchema, req.query);
    const scope = scopeOf(getAuth(res).user);
    const conditions: string[] = [];
    const params: unknown[] = [];
    const add = (condition: string, value: unknown) => {
      params.push(value);
      conditions.push(condition.replaceAll('?', `$${params.length}`));
    };
    if (!scope.allOrganisations) add('a.organisation_id = ?', scope.organisationId);
    if (query.organisationId) add('a.organisation_id = ?', query.organisationId);
    if (query.from) add(`a.occurred_at >= ?::date`, query.from);
    if (query.to) add(`a.occurred_at < ?::date + 1`, query.to);
    if (query.userId) add('a.actor_user_id = ?', query.userId);
    if (query.action) {
      if (query.action.includes('.')) add('a.action = ?', query.action);
      else add(`a.action LIKE ? || '.%'`, query.action);
    }
    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';

    const { rows } = await db.query<{
      id: string;
      occurred_at: Date;
      action: string;
      actor_user_id: string | null;
      actor_name: string | null;
      organisation_id: string | null;
      organisation_code: string | null;
      entity_type: string | null;
      entity_id: string | null;
      details: Record<string, unknown>;
      ip_address: string | null;
      total: number;
    }>(
      `SELECT a.id, a.occurred_at, a.action, a.actor_user_id, u.full_name AS actor_name,
              a.organisation_id, o.code AS organisation_code, a.entity_type, a.entity_id,
              a.details, host(a.ip_address) AS ip_address, count(*) OVER ()::integer AS total
       FROM audit_logs a
       LEFT JOIN users u ON u.id = a.actor_user_id
       LEFT JOIN organisations o ON o.id = a.organisation_id
       ${where}
       ORDER BY a.occurred_at DESC, a.id DESC
       LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, query.limit, query.offset],
    );

    const entries: AuditLogEntry[] = rows.map((row) => ({
      id: row.id,
      occurredAt: row.occurred_at,
      action: row.action,
      actor:
        row.actor_user_id === null
          ? null
          : { id: row.actor_user_id, fullName: row.actor_name ?? '' },
      organisation:
        row.organisation_id === null
          ? null
          : { id: row.organisation_id, code: row.organisation_code ?? '' },
      entityType: row.entity_type,
      entityId: row.entity_id,
      details: row.details,
      ipAddress: row.ip_address,
    }));
    res.json({ entries, total: rows[0]?.total ?? 0 });
  });

  return router;
}
