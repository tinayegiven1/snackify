-- Up Migration

-- Sign-in with a PIN instead of a password (owner's request, 2026-10-21; docs/STAGE_3_5_PLAN.md).
-- Every account starts from the default PIN 1234 and must choose its own PIN at the next
-- sign-in before doing anything else. Because a short PIN is easy to guess by trying, an account
-- is locked for 15 minutes after 5 wrong PINs (on top of the per-address limit).
--
-- The PIN hash stays in password_hash (Argon2id, as before), so nothing else changes shape.

ALTER TABLE users
  ADD COLUMN must_change_pin boolean NOT NULL DEFAULT true,
  ADD COLUMN failed_pin_attempts integer NOT NULL DEFAULT 0,
  ADD COLUMN locked_until timestamptz,
  ADD CONSTRAINT users_failed_pin_attempts_valid CHECK (failed_pin_attempts >= 0);

COMMENT ON COLUMN users.password_hash IS
  'Argon2id hash of the sign-in PIN (the column predates PINs).';
COMMENT ON COLUMN users.must_change_pin IS
  'True while the account still has the default PIN: only choosing a new PIN is allowed.';

-- The Argon2id hash of the default PIN "1234". This is not a secret: the default is public and
-- every account must replace it at its next sign-in.
UPDATE users
SET password_hash = '$argon2id$v=19$m=19456,t=2,p=1$XhrDlTrDEiFLty8Mxg85eg$bgtaEjZNFlIXxhfOkspbX5TCkIIWXPzP0XLtShsaXsc',
    must_change_pin = true,
    failed_pin_attempts = 0,
    locked_until = NULL;

-- Everyone signs in again, with the PIN.
UPDATE sessions SET revoked_at = now() WHERE revoked_at IS NULL;

-- Down Migration

-- Passwords cannot be restored: after going back, admins must set new passwords.
ALTER TABLE users
  DROP CONSTRAINT users_failed_pin_attempts_valid,
  DROP COLUMN locked_until,
  DROP COLUMN failed_pin_attempts,
  DROP COLUMN must_change_pin;
COMMENT ON COLUMN users.password_hash IS NULL;
