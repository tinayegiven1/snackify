import { describe, expect, it } from 'vitest';
import { hashForUnknownUser, hashPassword, verifyPassword } from '../modules/auth/passwords.js';

describe('password hashing (Argon2id)', () => {
  it('produces a standard Argon2id hash with OWASP settings, never the password itself', async () => {
    const hash = await hashPassword('correct horse battery');

    expect(hash).toMatch(
      /^\$argon2id\$v=19\$m=19456,t=2,p=1\$[A-Za-z0-9+/]{22}\$[A-Za-z0-9+/]{43}$/,
    );
    expect(hash).not.toContain('correct horse battery');
  });

  it('accepts the right password and rejects a wrong one', async () => {
    const hash = await hashPassword('correct horse battery');

    expect(await verifyPassword('correct horse battery', hash)).toBe(true);
    expect(await verifyPassword('correct horse batterY', hash)).toBe(false);
    expect(await verifyPassword('', hash)).toBe(false);
  });

  it('uses a different random salt every time', async () => {
    const [first, second] = await Promise.all([
      hashPassword('same password'),
      hashPassword('same password'),
    ]);
    expect(first).not.toBe(second);
  });

  it('treats a malformed stored hash as a wrong password instead of crashing', async () => {
    expect(await verifyPassword('anything', 'not-a-hash')).toBe(false);
    expect(await verifyPassword('anything', '$argon2id$v=19$m=19456,t=2,p=1$AAAA$AA')).toBe(false);
  });

  it('reuses one hash for unknown usernames', async () => {
    expect(await hashForUnknownUser()).toBe(await hashForUnknownUser());
  });
});
