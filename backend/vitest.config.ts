import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: 'unit',
          include: ['src/**/*.test.ts'],
          exclude: ['src/tests/db/**'],
        },
      },
      {
        // Integration tests against the real snackify_test database (npm run test:db).
        // The schema is rebuilt from the migrations first, and files share one database,
        // so they run one at a time.
        test: {
          name: 'db',
          include: ['src/tests/db/**/*.test.ts'],
          globalSetup: ['src/tests/db/global-setup.ts'],
          fileParallelism: false,
        },
      },
    ],
  },
});
