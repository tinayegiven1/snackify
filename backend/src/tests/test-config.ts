import type { AppConfig } from '../config/env.js';

export const testConfig: AppConfig = {
  nodeEnv: 'test',
  port: 0,
  corsOrigins: ['http://localhost:8080'],
};
