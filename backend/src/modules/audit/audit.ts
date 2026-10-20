import type { Queryable } from '../../database/transaction.js';
import { currentRequest } from '../../utils/request-context.js';

export type AuditAction =
  | 'auth.login'
  | 'auth.login_failed'
  | 'auth.logout'
  | 'auth.password_changed'
  | 'user.created'
  | 'user.updated'
  | 'user.password_reset'
  | 'user.roles_changed'
  | 'organisation.created'
  | 'organisation.updated'
  | 'role.permissions_changed'
  | 'product.created'
  | 'product.updated'
  | 'product.barcode_assigned'
  | 'stock.opening_balance'
  | 'stock.adjusted'
  | 'customer.created'
  | 'customer.updated'
  | 'dispatch.confirmed'
  | 'dispatch.cancelled'
  | 'dispatch.reversed'
  | 'invoice.issued'
  | 'invoice.voided'
  | 'payment.recorded'
  | 'payment.allocated'
  | 'payment.voided'
  | 'forecast.run';

export interface AuditEntry {
  /** The signed-in user who acted, or null for setup commands and unknown users. */
  actorUserId: string | null;
  action: AuditAction;
  entityType?:
    | 'user'
    | 'organisation'
    | 'role'
    | 'product'
    | 'customer'
    | 'dispatch'
    | 'invoice'
    | 'payment'
    | 'forecast';
  entityId?: string;
  /** Extra facts about the action. Never include passwords, tokens or other secrets. */
  details?: Record<string, unknown>;
  /**
   * The organisation the action was done for or by. Defaults to the signed-in user's
   * organisation; pass it where that is not known yet (signing in).
   */
  organisationId?: string | null;
}

/** Lists the fields whose value changed, as { field: { from, to } }, for audit details. */
export function changedFields<T extends Record<string, unknown>>(
  before: T,
  after: T,
): Record<string, { from: unknown; to: unknown }> {
  const changes: Record<string, { from: unknown; to: unknown }> = {};
  for (const field of Object.keys(after)) {
    if (before[field] !== after[field]) {
      changes[field] = { from: before[field], to: after[field] };
    }
  }
  return changes;
}

/**
 * Appends an entry to the audit log. Pass the transaction client to save it with the change.
 * The request's network address and organisation are added automatically.
 */
export async function recordAudit(db: Queryable, entry: AuditEntry): Promise<void> {
  const request = currentRequest();
  await db.query(
    `INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details,
                             organisation_id, ip_address)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      entry.actorUserId,
      entry.action,
      entry.entityType ?? null,
      entry.entityId ?? null,
      entry.details ?? {},
      entry.organisationId !== undefined ? entry.organisationId : (request?.organisationId ?? null),
      request?.ip ?? null,
    ],
  );
}
