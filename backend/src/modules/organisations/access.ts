import { AppError } from '../../utils/app-error.js';
import type { PublicUser } from '../auth/roles.js';

/**
 * Which organisations' records a user may see (decision D6 in docs/STAGE_3_5_PLAN.md):
 * Head Office users may see every organisation, within their permissions; a subsidiary's users
 * only their own. Always built on the server from the signed-in user, never from the request.
 */
export interface AccessScope {
  allOrganisations: boolean;
  /** The user's own organisation. */
  organisationId: string;
}

export function scopeOf(user: PublicUser): AccessScope {
  return {
    allOrganisations: user.organisation.type === 'HQ',
    organisationId: user.organisation.id,
  };
}

export function canAccessOrganisation(scope: AccessScope, organisationId: string): boolean {
  return scope.allOrganisations || scope.organisationId === organisationId;
}

/**
 * The organisation a request is about: the one asked for, if the user may see it, otherwise the
 * user's own. Another organisation's data answers 404, so its existence is not revealed.
 */
export function organisationFor(scope: AccessScope, requested: string | undefined): string {
  if (requested === undefined) return scope.organisationId;
  if (!canAccessOrganisation(scope, requested)) throw organisationNotFound();
  return requested;
}

export const organisationNotFound = () =>
  new AppError(404, 'ORGANISATION_NOT_FOUND', 'No organisation has that id.');
