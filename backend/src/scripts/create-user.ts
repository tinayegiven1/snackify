// Creates a staff account from the command line. Use it to create the first admin:
//
//   npm run user:create -- --username tendai --name "Tendai Moyo" --role admin
//
// --role takes role codes, comma-separated (e.g. hq_warehouse_officer,hq_sales_officer), or one
// of the old names: admin (all four Head Office roles), storekeeper, accounts, salesperson.
// --organisation is the organisation's code; the default is the Head Office.
//
// The password is asked for twice and is not shown while typing. It is never accepted as a
// command-line argument, so it cannot end up in shell history. (When input is piped rather
// than typed, the first line of input is used as the password.)
import { parseArgs } from 'node:util';
import { z } from 'zod';
import { loadDotEnv, readDatabaseUrl } from '../config/env.js';
import { createPool } from '../database/pool.js';
import { LEGACY_ROLE_ALIASES } from '../modules/auth/permissions.js';
import {
  fullNameSchema,
  newPasswordSchema,
  roleCodesSchema,
  usernameSchema,
} from '../modules/auth/roles.js';
import { createUser } from '../modules/users/users.service.js';
import { logger } from '../utils/logger.js';

/** Reads a line from the keyboard without echoing it. */
function readHidden(prompt: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const stdin = process.stdin;
    process.stdout.write(prompt);
    stdin.setRawMode(true);
    stdin.setEncoding('utf8');
    stdin.resume();

    let value = '';
    const finish = (error?: Error) => {
      stdin.off('data', onData);
      stdin.setRawMode(false);
      stdin.pause();
      process.stdout.write('\n');
      if (error) reject(error);
      else resolve(value);
    };
    const onData = (chunk: string) => {
      for (const char of chunk) {
        if (char === '\r' || char === '\n') return finish();
        if (char === '\u0003') return finish(new Error('Cancelled'));
        if (char === '\u007f' || char === '\b') value = value.slice(0, -1);
        else value += char;
      }
    };
    stdin.on('data', onData);
  });
}

async function readPipedLine(): Promise<string> {
  let input = '';
  for await (const chunk of process.stdin) input += String(chunk);
  return input.split(/\r?\n/)[0] ?? '';
}

async function askForPassword(): Promise<string> {
  if (!process.stdin.isTTY) {
    return readPipedLine();
  }
  const password = await readHidden('Password (at least 10 characters): ');
  const repeated = await readHidden('Repeat password: ');
  if (password !== repeated) {
    throw new Error('The two passwords do not match.');
  }
  return password;
}

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

  const password = newPasswordSchema.safeParse(await askForPassword());
  if (!password.success) {
    throw new Error(`Password: ${password.error.issues[0]?.message}`);
  }

  const user = await createUser(
    pool,
    { ...input.data, organisationId, password: password.data },
    { actorUserId: null, via: 'cli' },
  );
  logger.info('Staff account created', {
    username: user.username,
    organisation: user.organisation.code,
    roles: user.roles.map((role) => role.code),
  });
} catch (error) {
  logger.error('Could not create the account', { reason: (error as Error).message });
  process.exitCode = 1;
} finally {
  await pool.end();
}
