import { z } from 'zod';
import type { OrganisationRef, Permission, RoleRef } from './permissions.js';

/**
 * The signed-in user, as returned by the API. Never includes the PIN hash.
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
  /** Still on the default PIN: the only thing allowed is choosing a new PIN. */
  mustChangePin: boolean;
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

/**
 * The PIN every new account (and every account an admin resets) starts with. It is public, so
 * an account on it may do nothing but choose its own PIN.
 */
export const DEFAULT_PIN = '1234';

/** A PIN as typed at sign-in: digits only (checked loosely, so every wrong PIN looks alike). */
export const pinSchema = z.string({ error: 'Required' }).regex(/^\d{1,12}$/, 'Use digits only');

/** True for PINs anyone would try first: 1234, 0000, 1111, 2468-style runs, 4321 ... */
export function isEasyPin(pin: string): boolean {
  if (/^(\d)\1+$/.test(pin)) return true;
  const digits = [...pin].map(Number);
  const steps = new Set(digits.slice(1).map((digit, index) => digit - (digits[index] as number)));
  return steps.size === 1 && [1, -1, 2, -2].includes([...steps][0] as number);
}

/** A PIN someone chooses: 4–8 digits, not the default and not an easy one. */
export const newPinSchema = z
  .string({ error: 'Required' })
  .regex(/^\d+$/, 'Use digits only')
  .min(4, 'Use at least 4 digits')
  .max(8, 'Use at most 8 digits')
  // Only judged once the length is right, so a short PIN gets one clear message.
  .refine((pin) => !/^\d{4,8}$/.test(pin) || (pin !== DEFAULT_PIN && !isEasyPin(pin)), {
    message: 'Too easy to guess: avoid 1234, 0000, 4321 and the like',
  });
