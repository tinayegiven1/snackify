import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requirePermission } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { parseBody } from '../../utils/validation.js';
import {
  fullNameSchema,
  newPasswordSchema,
  roleCodesSchema,
  usernameSchema,
} from '../auth/roles.js';
import { scopeOf } from '../organisations/access.js';
import {
  assertUserInScope,
  createUser,
  listUsers,
  setPassword,
  updateUser,
} from './users.service.js';

const organisationIdSchema = z.uuid({ error: 'Must be an organisation id' });

const createUserSchema = z.object({
  username: usernameSchema,
  fullName: fullNameSchema,
  organisationId: organisationIdSchema,
  roleCodes: roleCodesSchema,
  password: newPasswordSchema,
});

const updateUserSchema = z
  .strictObject(
    {
      fullName: fullNameSchema.optional(),
      organisationId: organisationIdSchema.optional(),
      roleCodes: roleCodesSchema.optional(),
      isActive: z.boolean({ error: 'Must be true or false' }).optional(),
    },
    { error: 'Only fullName, organisationId, roleCodes and isActive can be changed here' },
  )
  .refine(
    (changes) => Object.keys(changes).length > 0,
    'Send at least one of fullName, organisationId, roleCodes or isActive',
  );

const listQuerySchema = z.object({ organisationId: organisationIdSchema.optional() });

const resetPasswordSchema = z.object({ newPassword: newPasswordSchema });

/** An invalid id cannot match any account, so treat it as "not found". */
function userIdParam(id: string | undefined): string {
  if (!z.uuid().safeParse(id).success) {
    throw new AppError(404, 'USER_NOT_FOUND', 'No staff account has that id.');
  }
  return id as string;
}

/** Staff account management (permission user.manage). */
export function usersRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db), requirePermission('user.manage'));

  router.get('/', async (req, res) => {
    const filter = parseBody(listQuerySchema, req.query);
    res.json({ users: await listUsers(db, scopeOf(getAuth(res).user), filter) });
  });

  router.post('/', async (req, res) => {
    const input = parseBody(createUserSchema, req.body);
    const { user: actor } = getAuth(res);
    const scope = scopeOf(actor);
    if (!scope.allOrganisations && input.organisationId !== scope.organisationId) {
      throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
        { field: 'organisationId', message: 'No organisation has that id' },
      ]);
    }
    const user = await createUser(db, input, { actorUserId: actor.id, via: 'api' });
    res.status(201).json({ user });
  });

  router.patch('/:id', async (req, res) => {
    const userId = userIdParam(req.params.id);
    const changes = parseBody(updateUserSchema, req.body);
    const { user: actor } = getAuth(res);
    const scope = scopeOf(actor);
    await assertUserInScope(db, scope, userId);
    if (
      changes.organisationId &&
      !scope.allOrganisations &&
      changes.organisationId !== scope.organisationId
    ) {
      throw new AppError(400, 'VALIDATION_ERROR', 'Some fields are missing or invalid.', [
        { field: 'organisationId', message: 'No organisation has that id' },
      ]);
    }
    res.json({ user: await updateUser(db, userId, changes, actor) });
  });

  router.post('/:id/reset-password', async (req, res) => {
    const userId = userIdParam(req.params.id);
    const { newPassword } = parseBody(resetPasswordSchema, req.body);
    const actor = getAuth(res).user;
    if (userId === actor.id) {
      // Changing your own password must prove you know the current one.
      throw new AppError(
        409,
        'USE_CHANGE_PASSWORD',
        'To change your own password, use POST /api/v1/auth/change-password.',
      );
    }
    await assertUserInScope(db, scopeOf(actor), userId);
    await setPassword(db, userId, newPassword, {
      actorUserId: actor.id,
      action: 'user.password_reset',
    });
    res.status(204).end();
  });

  return router;
}
