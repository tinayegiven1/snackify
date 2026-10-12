-- Up Migration

-- Staff accounts (spec sections 5 and 6.1). Accounts are deactivated, never deleted.
CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username      text NOT NULL,
  full_name     text NOT NULL,
  role          text NOT NULL,
  password_hash text NOT NULL,
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT users_username_key UNIQUE (username),
  -- Stored in lower case, so "Tendai" and "tendai" cannot both exist.
  CONSTRAINT users_username_format CHECK (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
  CONSTRAINT users_full_name_valid CHECK (full_name = btrim(full_name) AND length(full_name) BETWEEN 1 AND 100),
  CONSTRAINT users_role_valid CHECK (role IN ('admin', 'storekeeper', 'salesperson', 'accounts')),
  -- Only Argon2id hashes are accepted, so a plain-text password can never be stored by mistake.
  CONSTRAINT users_password_hash_argon2id CHECK (password_hash LIKE '$argon2id$%')
);

CREATE TRIGGER users_set_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

REVOKE DELETE ON users FROM snackify_app;

-- Signed-in sessions. Only a SHA-256 hash of each token is stored, so a copy of the
-- database cannot be used to sign in.
CREATE TABLE sessions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users (id),
  token_hash bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,

  CONSTRAINT sessions_token_hash_key UNIQUE (token_hash),
  CONSTRAINT sessions_token_hash_length CHECK (length(token_hash) = 32),
  CONSTRAINT sessions_expires_after_created CHECK (expires_at > created_at)
);

CREATE INDEX sessions_user_id_idx ON sessions (user_id, created_at);

-- Who did what, and when (spec 6.1 and 9). Append-only for the API.
-- Never store passwords, tokens or other secrets in details.
CREATE TABLE audit_logs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at   timestamptz NOT NULL DEFAULT now(),
  actor_user_id uuid REFERENCES users (id),
  action        text NOT NULL,
  entity_type   text,
  entity_id     uuid,
  details       jsonb NOT NULL DEFAULT '{}',

  -- For example "auth.login" or "user.created".
  CONSTRAINT audit_logs_action_format CHECK (action ~ '^[a-z_]+\.[a-z_]+$')
);

CREATE INDEX audit_logs_occurred_at_idx ON audit_logs (occurred_at);
CREATE INDEX audit_logs_actor_idx ON audit_logs (actor_user_id, occurred_at);
CREATE INDEX audit_logs_entity_idx ON audit_logs (entity_type, entity_id);

REVOKE UPDATE, DELETE ON audit_logs FROM snackify_app;

-- Down Migration

DROP TABLE audit_logs;
DROP TABLE sessions;
DROP TABLE users;
