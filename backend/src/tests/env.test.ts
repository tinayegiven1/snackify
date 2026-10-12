import { describe, expect, it } from 'vitest';
import { loadConfig, readDatabaseUrl } from '../config/env.js';

const DATABASE_URL = 'postgres://snackify_app:s3cret-pass@localhost:5432/snackify_dev';

describe('loadConfig', () => {
  it('uses safe development defaults for everything except the database', () => {
    expect(loadConfig({ DATABASE_URL })).toEqual({
      nodeEnv: 'development',
      port: 3000,
      corsOrigins: ['http://localhost:8080'],
      databaseUrl: DATABASE_URL,
      businessTimezone: 'Africa/Harare',
      billingWeekStartsOn: 1,
      baseCurrency: 'USD',
      business: { name: 'Snackify', contact: null },
    });
  });

  it('reads PORT, NODE_ENV and a comma-separated list of CORS origins', () => {
    const config = loadConfig({
      DATABASE_URL,
      NODE_ENV: 'production',
      PORT: '8081',
      CORS_ORIGINS: 'https://app.example.com, http://localhost:8080',
    });

    expect(config.nodeEnv).toBe('production');
    expect(config.port).toBe(8081);
    expect(config.corsOrigins).toEqual(['https://app.example.com', 'http://localhost:8080']);
  });

  it('requires DATABASE_URL', () => {
    expect(() => loadConfig({})).toThrow(/DATABASE_URL: Required/);
  });

  it('rejects a DATABASE_URL that is not PostgreSQL, without echoing it', () => {
    const notPostgres = 'mysql://snackify_app:s3cret-pass@localhost:3306/snackify';
    expect(() => loadConfig({ DATABASE_URL: notPostgres })).toThrow(/DATABASE_URL/);
    expect(() => loadConfig({ DATABASE_URL: notPostgres })).not.toThrow(/s3cret-pass/);
  });

  it('rejects an invalid PORT without echoing the value', () => {
    expect(() => loadConfig({ DATABASE_URL, PORT: 'not-a-port-value' })).toThrow(/PORT/);
    expect(() => loadConfig({ DATABASE_URL, PORT: 'not-a-port-value' })).not.toThrow(
      /not-a-port-value/,
    );
    expect(() => loadConfig({ DATABASE_URL, PORT: '70000' })).toThrow(/PORT/);
  });

  it('rejects an unknown NODE_ENV', () => {
    expect(() => loadConfig({ DATABASE_URL, NODE_ENV: 'staging' })).toThrow(/NODE_ENV/);
  });

  it('rejects a wildcard CORS origin', () => {
    expect(() => loadConfig({ DATABASE_URL, CORS_ORIGINS: '*' })).toThrow(/CORS_ORIGINS/);
  });

  it('rejects CORS origins with a path or trailing slash', () => {
    expect(() => loadConfig({ DATABASE_URL, CORS_ORIGINS: 'http://localhost:8080/' })).toThrow(
      /CORS_ORIGINS/,
    );
  });

  it('rejects an empty CORS origin list', () => {
    expect(() => loadConfig({ DATABASE_URL, CORS_ORIGINS: ' , ' })).toThrow(/CORS_ORIGINS/);
  });
});

describe('readDatabaseUrl', () => {
  it('returns a valid PostgreSQL URL', () => {
    expect(
      readDatabaseUrl('MIGRATION_DATABASE_URL', { MIGRATION_DATABASE_URL: DATABASE_URL }),
    ).toBe(DATABASE_URL);
  });

  it('names the missing variable', () => {
    expect(() => readDatabaseUrl('MIGRATION_DATABASE_URL', {})).toThrow(
      /MIGRATION_DATABASE_URL: Required/,
    );
  });
});
