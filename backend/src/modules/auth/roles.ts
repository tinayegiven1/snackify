import { z } from 'zod';
import type { OrganisationRef, Permission, RoleRef } from './permissions.js';

/**
 * The signed-in user, as returned by the API. Never includes the password hash.
 * What they may do is `permissions` (from all their roles); which organisations' data they may
 * see follows from `organisation` (see organisations/access.ts).
 */
export interface PublicUser {
  id: string;
  username: string;
  fullName: string;
  organisation: OrganisationRef;
  roles: RoleRef[];
  permissions: Permission[];
}

// Shared input rules, so the API and the create-user command validate the same way.
export const usernameSchema = z
  .string({ error: 'Required' })
  .trim()
  .toLowerCase()
  .regex(
    /^[a-z0-9][a-z0-9._-]{2,31}$/,
    'Use 3–32 letters, digits, dots, dashes or underscores, starting with a letter or digit',
  );

export const fullNameSchema = z
  .string({ error: 'Required' })
  .trim()
  .min(1, 'Required')
  .max(100, 'Use at most 100 characters');

export const roleCodesSchema = z
  .array(z.string({ error: 'Must be a role code' }).regex(/^[a-z][a-z_]{1,39}$/, 'Unknown role'), {
    error: 'Must be a list of role codes',
  })
  .min(1, 'Give at least one role')
  .max(10, 'Too many roles')
  .transform((codes) => [...new Set(codes)].sort());

// Long passphrases are encouraged; the upper limit stops absurdly long inputs.
export const newPasswordSchema = z
  .string({ error: 'Required' })
  .min(10, 'Use at least 10 characters')
  .max(128, 'Use at most 128 characters');
