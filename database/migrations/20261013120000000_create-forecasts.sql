-- Up Migration

-- Packs to keep in hand on top of the forecast demand, for suggesting how much to receive
-- (spec 6.11). Set per product by admins; 0 means no extra buffer.
ALTER TABLE products ADD COLUMN safety_stock integer NOT NULL DEFAULT 0;
ALTER TABLE products ADD CONSTRAINT products_safety_stock_not_negative CHECK (safety_stock >= 0);

-- One forecast run: when it was made, by whom, from which date and with which method.
CREATE TABLE forecast_runs (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  forecast_start date NOT NULL,
  method         text NOT NULL,
  created_by     uuid NOT NULL REFERENCES users (id),
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX forecast_runs_created_idx ON forecast_runs (created_at);

-- The forecast for one product and horizon in a run (spec 6.11 and section 7). Estimates, kept
-- as they were made so they can later be compared with what was actually dispatched.
CREATE TABLE forecasts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id             uuid NOT NULL REFERENCES forecast_runs (id),
  product_id         uuid NOT NULL REFERENCES products (id),
  -- First day forecast; the period is forecast_start .. forecast_start + horizon_days - 1.
  forecast_start     date NOT NULL,
  horizon_days       integer NOT NULL,
  method             text NOT NULL,
  status             text NOT NULL,
  predicted_quantity numeric(12, 1),
  lower_quantity     integer,
  upper_quantity     integer,
  -- How much dispatch history the forecast had.
  history_days       integer NOT NULL,
  weeks_used         integer NOT NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT forecasts_run_product_horizon_key UNIQUE (run_id, product_id, horizon_days),
  CONSTRAINT forecasts_horizon_positive CHECK (horizon_days > 0),
  CONSTRAINT forecasts_status_valid CHECK (status IN ('ok', 'insufficient_history', 'no_history')),
  -- A forecast is made only with enough history; otherwise nothing is predicted.
  CONSTRAINT forecasts_prediction_matches_status CHECK (
    (status = 'ok' AND predicted_quantity IS NOT NULL AND lower_quantity IS NOT NULL
       AND upper_quantity IS NOT NULL)
    OR (status <> 'ok' AND predicted_quantity IS NULL AND lower_quantity IS NULL
       AND upper_quantity IS NULL)
  ),
  CONSTRAINT forecasts_range_valid CHECK (
    predicted_quantity >= 0 AND lower_quantity >= 0
    AND lower_quantity <= predicted_quantity AND predicted_quantity <= upper_quantity
  )
);

CREATE INDEX forecasts_product_start_idx ON forecasts (product_id, horizon_days, forecast_start);

-- Forecasts are records of what was predicted: never changed or deleted.
REVOKE UPDATE, DELETE ON forecast_runs, forecasts FROM snackify_app;

-- Down Migration

DROP TABLE forecasts;
DROP TABLE forecast_runs;
ALTER TABLE products DROP CONSTRAINT products_safety_stock_not_negative;
ALTER TABLE products DROP COLUMN safety_stock;
