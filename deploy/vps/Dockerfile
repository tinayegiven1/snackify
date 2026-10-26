# Snackify on the VPS: the API plus the Flutter web app, built entirely on the server from a
# git checkout (the web build is not kept in Git). Used by deploy/vps/docker-compose.yml.

# --- Web app: Flutter (same version as development) ---
FROM debian:bookworm-slim AS web
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
  && rm -rf /var/lib/apt/lists/*
ARG FLUTTER_VERSION=3.47.7
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:$PATH"
RUN flutter config --no-analytics && flutter precache --web
WORKDIR /src/mobile_web
COPY mobile_web/pubspec.yaml mobile_web/pubspec.lock ./
RUN flutter pub get
COPY mobile_web/ ./
RUN flutter build web --release

# --- Backend: compile TypeScript ---
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
COPY --from=web /src/mobile_web/build/web /app/web
ENV WEB_APP_DIR=/app/web
# Receipt documents live in a volume mounted here; the unprivileged user must own it.
RUN mkdir -p /data/attachments && chown node:node /data/attachments
USER node
# Bring the database up to date, then start the API.
CMD ["sh", "-c", "node dist/scripts/migrate.js up && exec node dist/server.js"]
