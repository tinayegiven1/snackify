// Creates a staff account from the command line. Use it to create the first admin:
//
//   npm run user:create -- --username tendai --name "Tendai Moyo" --role admin
//
// The password is asked for twice and is not shown while typing. It is never accepted as a
// command-line argument, so it cannot end up in shell history. (When input is piped rather
// than typed, the first line of input is used as the password.)
import { parseArgs } from 'node:util';
import { z } from 'zod';
import { loadDotEnv, readDatabaseUrl } from '../config/env.js';
import { createPool } from '../database/pool.js';
import {
  fullNameSchema,
  newPasswordSchema,
  roleSchema,
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

loadDotEnv();

const { values } = parseArgs({
  options: {
    username: { type: 'string' },
    name: { type: 'string' },
    role: { type: 'string' },
  },
});

const pool = createPool(readDatabaseUrl('DATABASE_URL'));

try {
  const input = z
    .object({ username: usernameSchema, fullName: fullNameSchema, role: roleSchema })
    .safeParse({ username: values.username, fullName: values.name, role: values.role });
  if (!input.success) {
    const problems = input.error.issues.map(
      (issue) =>
        `--${issue.path[0] === 'fullName' ? 'name' : String(issue.path[0])}: ${issue.message}`,
    );
    throw new Error(`Invalid options:\n  ${problems.join('\n  ')}`);
  }

  const password = newPasswordSchema.safeParse(await askForPassword());
  if (!password.success) {
    throw new Error(`Password: ${password.error.issues[0]?.message}`);
  }

  const user = await createUser(
    pool,
    { ...input.data, password: password.data },
    { actorUserId: null, via: 'cli' },
  );
  logger.info('Staff account created', { username: user.username, role: user.role });
} catch (error) {
  logger.error('Could not create the account', { reason: (error as Error).message });
  process.exitCode = 1;
} finally {
  await pool.end();
}
