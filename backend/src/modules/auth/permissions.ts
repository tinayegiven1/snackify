/**
 * Everything the API can allow or refuse, by code. The same codes are rows in the permissions
 * table (migration 20261020090000000); a database test checks that the two lists match. Which
 * role has which permission is data (role_permissions), not code.
 */
export const PERMISSIONS = [
  'organisation.manage',
  'user.manage',
  'role.manage',
  'audit.view',
  'product.manage',
  'label.print',
  'stock.view',
  'stock.receive',
  'stock.opening_balance',
  'stock.adjust',
  'customer.view',
  'customer.edit_details',
  'customer.edit_credit_limit',
  'customer.change_active',
  'dispatch.view',
  'dispatch.draft',
  'dispatch.confirm',
  'dispatch.reverse',
  'invoice.manage',
  'payment.manage',
  'payment.void',
  'report.dashboard',
  'report.financial',
  'report.stock',
  'forecast.use',
] as const;

export type Permission = (typeof PERMISSIONS)[number];

export type OrganisationType = 'HQ' | 'SUBSIDIARY';

/** The organisation a user works for, as shown with the user. */
export interface OrganisationRef {
  id: string;
  code: string;
  name: string;
  type: OrganisationType;
}

export interface RoleRef {
  code: string;
  name: string;
}

/**
 * The old single roles, still accepted by `npm run user:create --role` as short names for the
 * roles they became (decision D2 in docs/STAGE_3_5_PLAN.md).
 */
export const LEGACY_ROLE_ALIASES: Record<string, string[]> = {
  admin: ['system_admin', 'hq_finance_officer', 'hq_warehouse_officer', 'hq_sales_officer'],
  storekeeper: ['hq_warehouse_officer'],
  accounts: ['hq_finance_officer'],
  salesperson: ['hq_sales_officer'],
};
