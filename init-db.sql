-- Dedupe table for seen jobs. n8n owns its own schema; this lives alongside.
CREATE TABLE IF NOT EXISTS seen_jobs (
  id           BIGSERIAL PRIMARY KEY,
  job_hash     TEXT UNIQUE NOT NULL,
  source       TEXT NOT NULL,
  title        TEXT,
  company      TEXT,
  url          TEXT,
  score        INTEGER,
  status       TEXT DEFAULT 'discovered',
  drive_folder TEXT,
  seen_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_seen_jobs_hash ON seen_jobs(job_hash);
CREATE INDEX IF NOT EXISTS idx_seen_jobs_seen_at ON seen_jobs(seen_at DESC);
