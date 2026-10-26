import type { OrganisationRef, OrganisationType, Permission, RoleRef } from './permissions.js';
import type { PublicUser } from './roles.js';

/**
 * Columns that load a user's organisation, roles and permissions in the same query as the user.
 * Use with `FROM users u JOIN organisations o ON o.id = u.organisation_id`.
 */
export const USER_ACCESS_COLUMNS = `
  o.id AS organisation_id, o.code AS organisation_code, o.name AS organisation_name,
  o.organisation_type, u.must_change_pin,
  COALESCE((SELECT json_agg(json_build_object('code', r.code, 'name', r.name) ORDER BY r.name)
            FROM user_roles ur JOIN roles r ON r.id = ur.role_id
            WHERE ur.user_id = u.id), '[]'::json) AS roles,
  COALESCE((SELECT array_agg(DISTINCT rp.permission_code ORDER BY rp.permission_code)
            FROM user_roles ur JOIN role_permissions rp ON rp.role_id = ur.role_id
            WHERE ur.user_id = u.id), '{}'::text[]) AS permissions`;

export interface UserAccessRow {
  id: string;
  username: string;
  full_name: string;
  organisation_id: string;
  organisation_code: string;
  organisation_name: string;
  organisation_type: OrganisationType;
  roles: RoleRef[];
  permissions: Permission[];
  must_change_pin: boolean;
}

export function organisationRef(row: UserAccessRow): OrganisationRef {
  return {
    id: row.organisation_id,
    code: row.organisation_code,
    name: row.organisation_name,
    type: row.organisation_type,
  };
}

export function toPublicUser(row: UserAccessRow): PublicUser {
  return {
    id: row.id,
    username: row.username,
    fullName: row.full_name,
    organisation: organisationRef(row),
    roles: row.roles,
    permissions: row.permissions,
    mustChangePin: row.must_change_pin,
  };
}
