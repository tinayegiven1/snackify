import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createApp } from '../app.js';
import { loadConfig } from '../config/env.js';
import { testConfig } from './test-config.js';

let dir: string;
let app: ReturnType<typeof createApp>;

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'snackify-web-'));
  await writeFile(join(dir, 'index.html'), '<!DOCTYPE html><title>Snackify</title>');
  await writeFile(join(dir, 'main.dart.js'), 'console.log("app");');
  app = createApp(
    { ...testConfig, webAppDir: dir },
    {
      db: new pg.Pool({ connectionString: testConfig.databaseUrl }),
      checkDatabase: async () => true,
    },
  );
});
afterAll(() => rm(dir, { recursive: true, force: true }));

describe('the web app on the same address as the API', () => {
  it('is served at the root, with a policy that lets Flutter run and nothing else', async () => {
    const response = await request(app).get('/');

    expect(response.status).toBe(200);
    expect(response.text).toContain('<title>Snackify</title>');
    expect(response.headers['cache-control']).toBe('no-cache');
    const policy = response.headers['content-security-policy'] as string;
    expect(policy).toContain("default-src 'self'");
    expect(policy).toContain("script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com");
    expect(policy).toContain("frame-ancestors 'none'");
    expect(policy).not.toContain('unsafe-eval ');
  });

  it('serves its files, and index.html for any other page address', async () => {
    const script = await request(app).get('/main.dart.js');
    expect(script.status).toBe(200);
    expect(script.text).toBe('console.log("app");');

    const deepLink = await request(app).get('/invoices/2026/week-41');
    expect(deepLink.status).toBe(200);
    expect(deepLink.text).toContain('<title>Snackify</title>');
  });

  it('never answers an API address with the web page', async () => {
    const unknown = await request(app).get('/api/v1/no-such-thing');
    expect(unknown.status).toBe(404);
    expect(unknown.body.error.code).toBe('NOT_FOUND');

    const health = await request(app).get('/api/v1/health');
    expect(health.status).toBe(200);
    expect(health.headers['content-security-policy']).toBe(
      "default-src 'none';frame-ancestors 'none'",
    );
  });

  it('does not serve files outside its folder', async () => {
    for (const path of ['/../package.json', '/%2e%2e/package.json', '/..%2fpackage.json']) {
      const response = await request(app).get(path);
      expect(response.text).not.toContain('snackify-backend');
    }
  });

  it('is not served unless WEB_APP_DIR is set', async () => {
    const apiOnly = createApp(testConfig, {
      db: new pg.Pool({ connectionString: testConfig.databaseUrl }),
      checkDatabase: async () => true,
    });
    const response = await request(apiOnly).get('/');
    expect(response.status).toBe(404);
  });
});

describe('web app and proxy settings', () => {
  const DATABASE_URL = 'postgres://snackify_app:s3cret@localhost:5432/snackify_dev';

  it('require WEB_APP_DIR to hold a built web app', () => {
    expect(loadConfig({ DATABASE_URL, WEB_APP_DIR: dir }).webAppDir).toBe(dir);
    expect(() => loadConfig({ DATABASE_URL, WEB_APP_DIR: join(dir, 'missing') })).toThrow(
      /WEB_APP_DIR: Must be a folder containing the built web app/,
    );
  });

  it('accept a small number of trusted proxies', () => {
    expect(loadConfig({ DATABASE_URL, TRUST_PROXY_HOPS: '1' }).trustProxyHops).toBe(1);
    for (const hops of ['-1', '6', 'yes', '1.5']) {
      expect(() => loadConfig({ DATABASE_URL, TRUST_PROXY_HOPS: hops })).toThrow(
        /TRUST_PROXY_HOPS/,
      );
    }
  });
});
