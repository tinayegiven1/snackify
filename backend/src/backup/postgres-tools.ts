import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

/** The default PostgreSQL install folder on Windows (EDB installer). */
const WINDOWS_DEFAULT_BIN = 'C:\\Program Files\\PostgreSQL\\18\\bin';

/**
 * Where pg_dump and pg_restore are: PG_BIN_DIR if set, the default Windows install folder if it
 * exists, otherwise they must be on the PATH.
 */
export function postgresBinDir(env: NodeJS.ProcessEnv = process.env): string | null {
  if (env.PG_BIN_DIR) return env.PG_BIN_DIR;
  if (process.platform === 'win32' && existsSync(WINDOWS_DEFAULT_BIN)) return WINDOWS_DEFAULT_BIN;
  return null;
}

/** The connection details of a PostgreSQL URL, kept apart so the password is never an argument. */
export interface Connection {
  host: string;
  port: string;
  user: string;
  password: string;
  database: string;
}

export function parseConnection(url: string): Connection {
  const parsed = new URL(url);
  return {
    host: parsed.hostname,
    port: parsed.port || '5432',
    user: decodeURIComponent(parsed.username),
    password: decodeURIComponent(parsed.password),
    database: decodeURIComponent(parsed.pathname.replace(/^\//, '')),
  };
}

/** The same server and login, another database. */
export function withDatabase(url: string, database: string): string {
  const parsed = new URL(url);
  parsed.pathname = `/${encodeURIComponent(database)}`;
  return parsed.toString();
}

/**
 * Runs pg_dump or pg_restore and returns what it printed. With a connection, the password goes
 * in the child's environment (PGPASSWORD), never on the command line, so it does not show in
 * process lists or logs.
 */
export function runPostgresTool(
  tool: 'pg_dump' | 'pg_restore',
  args: string[],
  connection?: Connection,
): Promise<string> {
  const dir = postgresBinDir();
  const executable = dir ? join(dir, process.platform === 'win32' ? `${tool}.exe` : tool) : tool;
  const connectionArgs = connection
    ? [
        '--host',
        connection.host,
        '--port',
        connection.port,
        '--username',
        connection.user,
        '--dbname',
        connection.database,
        '--no-password',
      ]
    : [];
  const env: NodeJS.ProcessEnv = { ...process.env, PGCONNECT_TIMEOUT: '10' };
  if (connection) env.PGPASSWORD = connection.password;

  return new Promise((resolve, reject) => {
    execFile(
      executable,
      [...connectionArgs, ...args],
      { env, maxBuffer: 64 * 1024 * 1024, windowsHide: true },
      (error, stdout, stderr) => {
        if (error) {
          const code = (error as NodeJS.ErrnoException).code;
          const detail =
            code === 'ENOENT'
              ? `${executable} was not found. Install the PostgreSQL client tools or set PG_BIN_DIR.`
              : stderr.trim() || error.message;
          reject(new Error(`${tool} failed: ${detail}`));
        } else {
          resolve(stdout);
        }
      },
    );
  });
}
