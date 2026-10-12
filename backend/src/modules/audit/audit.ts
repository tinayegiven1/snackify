import type { Queryable } from '../../database/transaction.js';

export type AuditAction =
  | 'auth.login'
  | 'auth.login_failed'
  | 'auth.logout'
  | 'auth.password_changed'
  | 'user.created'
  | 'user.updated'
  | 'user.password_reset';

export interface AuditEntry {
  /** The signed-in user who acted, or null for setup commands and unknown users. */
  actorUserId: string | null;
  action: AuditAction;
  entityType?: 'user';
  entityId?: string;
  /** Extra facts about the action. Never include passwords, tokens or other secrets. */
  details?: Record<string, unknown>;
}

/** Appends an entry to the audit log. Pass the transaction client to save it with the change. */
export async function recordAudit(db: Queryable, entry: AuditEntry): Promise<void> {
  await db.query(
    `INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details)
     VALUES ($1, $2, $3, $4, $5)`,
    [
      entry.actorUserId,
      entry.action,
      entry.entityType ?? null,
      entry.entityId ?? null,
      entry.details ?? {},
    ],
  );
}
