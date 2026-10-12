import express from 'express';
import request from 'supertest';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createApp } from '../app.js';
import { errorHandler } from '../middleware/error-handler.js';
import { AppError } from '../utils/app-error.js';
import { testConfig } from './test-config.js';

describe('error handling', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('returns a JSON 404 for unknown routes', async () => {
    const response = await request(createApp(testConfig)).get('/api/v1/does-not-exist');

    expect(response.status).toBe(404);
    expect(response.body).toEqual({
      error: { code: 'NOT_FOUND', message: 'Route GET /api/v1/does-not-exist was not found.' },
    });
  });

  it('returns 400 INVALID_JSON for a malformed JSON body', async () => {
    const response = await request(createApp(testConfig))
      .post('/api/v1/health')
      .set('Content-Type', 'application/json')
      .send('{"name": ');

    expect(response.status).toBe(400);
    expect(response.body.error.code).toBe('INVALID_JSON');
  });

  it('returns the status, code and details of an AppError', async () => {
    const app = express();
    app.get('/conflict', () => {
      throw new AppError(409, 'DUPLICATE_SKU', 'SKU already exists.', { field: 'sku' });
    });
    app.use(errorHandler);

    const response = await request(app).get('/conflict');

    expect(response.status).toBe(409);
    expect(response.body).toEqual({
      error: { code: 'DUPLICATE_SKU', message: 'SKU already exists.', details: { field: 'sku' } },
    });
  });

  it('hides internal details of unexpected errors from the client', async () => {
    const logged = vi.spyOn(console, 'error').mockImplementation(() => {});
    const app = express();
    app.get('/boom', () => {
      throw new Error('connection to db-host:5432 failed for user snackify');
    });
    app.use(errorHandler);

    const response = await request(app).get('/boom');

    expect(response.status).toBe(500);
    expect(response.body).toEqual({
      error: { code: 'INTERNAL_ERROR', message: 'Something went wrong. Please try again.' },
    });
    expect(JSON.stringify(response.body)).not.toContain('db-host');
    // The real cause is still logged on the server for debugging.
    expect(logged).toHaveBeenCalledOnce();
    expect(String(logged.mock.calls[0]?.[0])).toContain('db-host');
  });
});
