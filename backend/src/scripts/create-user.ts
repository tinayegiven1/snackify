// Creates a staff account from the command line. Use it to create the first admin:
//
//   npm run user:create -- --username tendai --name "Tendai Moyo" --role admin
//
// --role takes role codes, comma-separated (e.g. hq_warehouse_officer,hq_sales_officer), or one
// of the old names: admin (all four Head Office roles), storekeeper, accounts, salesperson.
// --organisation is the organisation's code; the default is the Head Office.
//
// The account starts on the default PIN 1234 and must choose its own PIN at the first sign-in.
import { parseArgs } from 'node:util';
import { z } from 'zod';
import { loadDotEnv, readDatabaseUrl } from '../config/env.js';
import { createPool } from '../database/pool.js';
import { LEGACY_ROLE_ALIASES } from '../modules/auth/permissions.js';
import {
  DEFAULT_PIN,
  fullNameSchema,
  roleCodesSchema,
  usernameSchema,
} from '../modules/auth/roles.js';
import { createUser } from '../modules/users/users.service.js';
import { logger } from '../utils/logger.js';

/** "admin" or "hq_warehouse_officer,hq_sales_officer" -> role codes. */
function roleCodesFrom(option: string | undefined): string[] | undefined {
  if (option === undefined) return undefined;
  return option
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .flatMap((part) => LEGACY_ROLE_ALIASES[part] ?? [part]);
}

const optionName = (field: unknown) =>
  field === 'fullName' ? 'name' : field === 'roleCodes' ? 'role' : String(field);

loadDotEnv();

const { values } = parseArgs({
  options: {
    username: { type: 'string' },
    name: { type: 'string' },
    role: { type: 'string' },
    organisation: { type: 'string' },
  },
});

const pool = createPool(readDatabaseUrl('DATABASE_URL'));

try {
  const input = z
    .object({ username: usernameSchema, fullName: fullNameSchema, roleCodes: roleCodesSchema })
    .safeParse({
      username: values.username,
      fullName: values.name,
      roleCodes: roleCodesFrom(values.role),
    });
  if (!input.success) {
    const problems = input.error.issues.map(
      (issue) => `--${optionName(issue.path[0])}: ${issue.message}`,
    );
    throw new Error(`Invalid options:\n  ${problems.join('\n  ')}`);
  }

  const { rows } = await pool.query<{ id: string }>(
    values.organisation
      ? 'SELECT id FROM organisations WHERE code = upper($1)'
      : "SELECT id FROM organisations WHERE organisation_type = 'HQ'",
    values.organisation ? [values.organisation] : [],
  );
  const organisationId = rows[0]?.id;
  if (!organisationId) {
    throw new Error(`--organisation: no organisation has the code "${values.organisation}"`);
  }

  const user = await createUser(
    pool,
    { ...input.data, organisationId },
    { actorUserId: null, via: 'cli' },
  );
  logger.info('Staff account created', {
    username: user.username,
    organisation: user.organisation.code,
    roles: user.roles.map((role) => role.code),
    firstPin: DEFAULT_PIN,
    note: 'They must choose their own PIN at the first sign-in',
  });
} catch (error) {
  logger.error('Could not create the account', { reason: (error as Error).message });
  process.exitCode = 1;
} finally {
  await pool.end();
}
