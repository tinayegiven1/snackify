import { z } from 'zod';

/** Staff roles (spec section 5). Admins may do everything. */
export const ROLES = ['admin', 'storekeeper', 'salesperson', 'accounts'] as const;
export type Role = (typeof ROLES)[number];

/** The signed-in user, as returned by the API. Never includes the password hash. */
export interface PublicUser {
  id: string;
  username: string;
  fullName: string;
  role: Role;
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

export const roleSchema = z.enum(ROLES, { error: `Must be one of: ${ROLES.join(', ')}` });

// Long passphrases are encouraged; the upper limit stops absurdly long inputs.
export const newPasswordSchema = z
  .string({ error: 'Required' })
  .min(10, 'Use at least 10 characters')
  .max(128, 'Use at most 128 characters');
