# The Snackify server for Google Cloud Run: the API plus the built Flutter web app, on one
# address. Build the web app first (deploy/deploy-staging.ps1 does this):
#   cd mobile_web && flutter build web --release
#
# The same image also runs database migrations:
#   node dist/scripts/migrate.js up

# --- Build: compile the TypeScript backend ---
FROM node:24-slim AS build
WORKDIR /app/backend
COPY backend/package.json backend/package-lock.json ./
RUN npm ci --ignore-scripts
COPY backend/tsconfig.json backend/tsconfig.build.json ./
COPY backend/src ./src
RUN npm run build

# --- Run: only what the server needs ---
FROM node:24-slim
ENV NODE_ENV=production
WORKDIR /app/backend
COPY backend/package.json backend/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY --from=build /app/backend/dist ./dist
# The migration runner looks for ../database/migrations relative to the backend folder.
COPY database/migrations /app/database/migrations
COPY mobile_web/build/web /app/web
ENV WEB_APP_DIR=/app/web

# Cloud Run sets PORT. Run as the unprivileged "node" user, not root.
USER node
CMD ["node", "dist/server.js"]
