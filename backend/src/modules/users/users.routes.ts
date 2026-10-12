import { Router } from 'express';
import type pg from 'pg';
import { z } from 'zod';
import { getAuth, requireAuth, requireRole } from '../../middleware/authenticate.js';
import { AppError } from '../../utils/app-error.js';
import { parseBody } from '../../utils/validation.js';
import { fullNameSchema, newPasswordSchema, roleSchema, usernameSchema } from '../auth/roles.js';
import { createUser, listUsers, setPassword, updateUser } from './users.service.js';

const createUserSchema = z.object({
  username: usernameSchema,
  fullName: fullNameSchema,
  role: roleSchema,
  password: newPasswordSchema,
});

const updateUserSchema = z
  .strictObject(
    {
      fullName: fullNameSchema.optional(),
      role: roleSchema.optional(),
      isActive: z.boolean({ error: 'Must be true or false' }).optional(),
    },
    { error: 'Only fullName, role and isActive can be changed here' },
  )
  .refine(
    (changes) => Object.keys(changes).length > 0,
    'Send at least one of fullName, role or isActive',
  );

const resetPasswordSchema = z.object({ newPassword: newPasswordSchema });

/** An invalid id cannot match any account, so treat it as "not found". */
function userIdParam(id: string | undefined): string {
  if (!z.uuid().safeParse(id).success) {
    throw new AppError(404, 'USER_NOT_FOUND', 'No staff account has that id.');
  }
  return id as string;
}

/** Staff account management. Admins only. */
export function usersRouter(db: pg.Pool): Router {
  const router = Router();
  router.use(requireAuth(db), requireRole('admin'));

  router.get('/', async (_req, res) => {
    res.json({ users: await listUsers(db) });
  });

  router.post('/', async (req, res) => {
    const input = parseBody(createUserSchema, req.body);
    const user = await createUser(db, input, { actorUserId: getAuth(res).user.id, via: 'api' });
    res.status(201).json({ user });
  });

  router.patch('/:id', async (req, res) => {
    const userId = userIdParam(req.params.id);
    const changes = parseBody(updateUserSchema, req.body);
    const user = await updateUser(db, userId, changes, getAuth(res).user);
    res.json({ user });
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
    await setPassword(db, userId, newPassword, {
      actorUserId: actor.id,
      action: 'user.password_reset',
    });
    res.status(204).end();
  });

  return router;
}
