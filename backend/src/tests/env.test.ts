import { describe, expect, it } from 'vitest';
import { loadConfig } from '../config/env.js';

describe('loadConfig', () => {
  it('uses safe development defaults when variables are not set', () => {
    expect(loadConfig({})).toEqual({
      nodeEnv: 'development',
      port: 3000,
      corsOrigins: ['http://localhost:8080'],
    });
  });

  it('reads PORT, NODE_ENV and a comma-separated list of CORS origins', () => {
    const config = loadConfig({
      NODE_ENV: 'production',
      PORT: '8081',
      CORS_ORIGINS: 'https://app.example.com, http://localhost:8080',
    });

    expect(config.nodeEnv).toBe('production');
    expect(config.port).toBe(8081);
    expect(config.corsOrigins).toEqual(['https://app.example.com', 'http://localhost:8080']);
  });

  it('rejects an invalid PORT without echoing the value', () => {
    expect(() => loadConfig({ PORT: 'not-a-port-value' })).toThrow(/PORT/);
    expect(() => loadConfig({ PORT: 'not-a-port-value' })).not.toThrow(/not-a-port-value/);
    expect(() => loadConfig({ PORT: '70000' })).toThrow(/PORT/);
  });

  it('rejects an unknown NODE_ENV', () => {
    expect(() => loadConfig({ NODE_ENV: 'staging' })).toThrow(/NODE_ENV/);
  });

  it('rejects a wildcard CORS origin', () => {
    expect(() => loadConfig({ CORS_ORIGINS: '*' })).toThrow(/CORS_ORIGINS/);
  });

  it('rejects CORS origins with a path or trailing slash', () => {
    expect(() => loadConfig({ CORS_ORIGINS: 'http://localhost:8080/' })).toThrow(/CORS_ORIGINS/);
  });

  it('rejects an empty CORS origin list', () => {
    expect(() => loadConfig({ CORS_ORIGINS: ' , ' })).toThrow(/CORS_ORIGINS/);
  });
});
