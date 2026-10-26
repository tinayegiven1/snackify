import { argon2, randomBytes, timingSafeEqual } from 'node:crypto';

// Hashing for sign-in secrets. Since 2026-10-21 these are PINs; the functions keep their
// names. Argon2id makes every guess slow, which matters even more for short PINs.

// OWASP Password Storage Cheat Sheet settings for Argon2id: 19 MiB memory, 2 passes, 1 lane.
const PARAMETERS = { memory: 19_456, passes: 2, parallelism: 1 } as const;
const SALT_BYTES = 16;
const HASH_BYTES = 32;

// Standard "PHC" format, as used by other Argon2 libraries:
// $argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>   (salt and hash in unpadded base64)
const PHC_FORMAT =
  /^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$/;

function derive(
  password: string,
  salt: Buffer,
  settings: { memory: number; passes: number; parallelism: number; tagLength: number },
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    argon2('argon2id', { message: password, nonce: salt, ...settings }, (error, key) => {
      if (error) reject(error);
      else resolve(key);
    });
  });
}

const base64 = (bytes: Buffer) => bytes.toString('base64').replace(/=+$/, '');

/** Hashes a password with Argon2id and a random salt. */
export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(SALT_BYTES);
  const hash = await derive(password, salt, { ...PARAMETERS, tagLength: HASH_BYTES });
  const { memory, passes, parallelism } = PARAMETERS;
  return `$argon2id$v=19$m=${memory},t=${passes},p=${parallelism}$${base64(salt)}$${base64(hash)}`;
}

/** Checks a password against a stored hash, taking the same time whether or not it matches. */
export async function verifyPassword(password: string, storedHash: string): Promise<boolean> {
  const match = PHC_FORMAT.exec(storedHash);
  const [, memory, passes, parallelism, salt = '', hash = ''] = match ?? [];
  const expected = Buffer.from(hash, 'base64');
  // A malformed stored hash counts as "wrong password" rather than crashing the request.
  if (!match || expected.length < 16) {
    return false;
  }
  const actual = await derive(password, Buffer.from(salt, 'base64'), {
    memory: Number(memory),
    passes: Number(passes),
    parallelism: Number(parallelism),
    tagLength: expected.length,
  });
  return timingSafeEqual(actual, expected);
}

let dummyHash: Promise<string> | undefined;

/**
 * A hash of a random password. Checking a password against it when a username does not exist
 * makes failed sign-ins take the same time, so response times do not reveal which usernames exist.
 */
export function hashForUnknownUser(): Promise<string> {
  dummyHash ??= hashPassword(randomBytes(16).toString('hex'));
  return dummyHash;
}
