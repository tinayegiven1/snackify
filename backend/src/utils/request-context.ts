import { AsyncLocalStorage } from 'node:async_hooks';
import type { RequestHandler } from 'express';

/** Facts about the current request that the audit log records with every entry. */
export interface RequestContext {
  /** The client's address (the real client when TRUST_PROXY_HOPS is set behind a proxy). */
  ip: string | null;
  /** The signed-in user's organisation, once known. */
  organisationId: string | null;
}

const storage = new AsyncLocalStorage<RequestContext>();

/** Starts a context for each request; everything the request does can read it. */
export const requestContextMiddleware: RequestHandler = (req, _res, next) => {
  storage.run({ ip: req.ip ?? null, organisationId: null }, next);
};

/** The current request's context, or undefined outside a request (e.g. command-line scripts). */
export function currentRequest(): RequestContext | undefined {
  return storage.getStore();
}
