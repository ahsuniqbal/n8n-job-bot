# 04 — Tools & Nodes

## Infrastructure Stack

The whole pipeline runs as three Docker containers on a single user-defined bridge network, orchestrated by one `docker-compose.yml`. All persistent state stays inside the project folder (bind mounts), so backing up or moving the project is a single directory copy.

| Container | Image | Purpose |
|-----------|-------|---------|
| `jobbot-n8n` | `docker.n8n.io/n8nio/n8n:latest` | Workflow engine, UI, scheduler |
| `jobbot-postgres` | `postgres:16-alpine` | n8n metadata DB and `seen_jobs` dedupe table |
| `jobbot-gotenberg` | `gotenberg/gotenberg:8` | HTML → PDF rendering via headless Chromium |

Volumes:

- `./n8n_data` → `/home/node/.n8n` (workflow data, credentials, encryption key)
- `./postgres_data` → `/var/lib/postgresql/data` (database files)
- `./resume` → `/data/resume` (read-only mount of master resume — `resume.html`)
- `./init-db.sql` → `/docker-entrypoint-initdb.d/init-db.sql` (runs once at first DB boot)

Ports exposed to the host:

- `5678` → n8n UI
- `5433` → Postgres (for DBeaver / external clients; container-to-container traffic uses internal port 5432)

## External Services

| Service | What | Why | Cost |
|---------|------|-----|------|
| **Adzuna API** | Job aggregator | Remote-only roles (`what_phrase='remote'`) | Free 1000 calls/mo |
| **HN Algolia API** | HN "Who is hiring" comments | Direct-from-founders roles | Free, no key |
| **Anthropic Claude API** | LLM scoring + tailoring | Score (Haiku) + draft (Sonnet) | Pay-per-token, cents/day |
| **Google Drive** | File storage | Per-job folder + PDF storage | Free 15 GB tier |
| **Google Sheets** | Tracking | Tabular review surface | Free |
| **Gmail SMTP** | Notifications | Personal email delivery | Free with app password |

## n8n Nodes Used

The pipeline is split across **two workflows**: a **main** workflow that discovers and prefilters jobs (5 nodes), and a **sub** workflow that processes a single job end-to-end (26 nodes). The main workflow's `Execute Workflow` node calls the sub once **per job** (mode: `each`, `onError: continueRegularOutput`), so one failing job is skipped and the batch continues instead of aborting the whole run. This split exists purely for **per-job error isolation** — a Gotenberg render failure or a Claude timeout on job #7 no longer kills jobs #8–#20.

### Main — `Job Bot — Discover, Tailor, Apply Prep` (id `TsWvUtT4VUBbPE2u`)

| Node Type | Count | Role |
|-----------|-------|------|
| `Schedule Trigger` | 1 | Daily 08:00 cron (`Schedule Daily 8am`) |
| `Code` | 3 | `Fetch All Sources`, `Dedupe + Hash`, `Prefilter Relevant` |
| `Execute Workflow` | 1 | `Process One Job` — calls the sub once per job (mode `each`, `onError` continue) |

**Main total: 5 nodes** = 1 Schedule Trigger + 3 Code + 1 Execute Workflow.

### Sub — `Job Bot — Process One Job` (id `4nmCCacM8B8nfYwZ`)

Runs once per job, receiving a single normalized job as input.

#### Triggers

| Node Type | Count | Role |
|-----------|-------|------|
| `Execute Workflow Trigger` | 1 | `Job Input` — entry point (inputSource passthrough) |

#### Data Fetch / API

| Node Type | Count | Role |
|-----------|-------|------|
| `HTTP Request` | 5 | `Claude Score Fit`, `Claude Tailor Resume`, `Gotenberg Resume PDF`, `Claude Cover Letter`, `Gotenberg Letter PDF` |

#### Transformation / Logic

| Node Type | Count | Role |
|-----------|-------|------|
| `Code` | 8 | `Parse Score JSON`, `Resume Binary to Text`, `Extract Resume HTML`, `Rename Resume PDF`, `Extract Letter HTML`, `Rename Letter PDF`, `Combine Binaries`, `Build Sheet Row` |
| `IF` | 2 | `IF Unseen` + `IF Score >= Threshold` |
| `Merge` | 2 | `Merge Resume+Letter` + `Merge Uploads` |
| `Read/Write Files from Disk` | 1 | `Read Resume MD` — load `resume.html` |

#### Storage / Persistence

| Node Type | Count | Role |
|-----------|-------|------|
| `Postgres` | 2 | `Postgres Check Seen` + `Postgres Insert Seen` (upsert on conflict `job_hash`) |
| `Google Drive` | 3 | `Drive Create Folder` + `Drive Upload Resume` + `Drive Upload Letter` |
| `Google Sheets` | 1 | `Sheets Append Row` |

#### Output

| Node Type | Count | Role |
|-----------|-------|------|
| `Send Email` | 1 | `Email Notify` — SMTP digest per accepted job |

**Sub total: 26 nodes** = 1 Execute Workflow Trigger + 5 HTTP + 8 Code + 2 IF + 2 Merge + 1 file read + 2 Postgres + 3 Drive + 1 Sheets + 1 Email.

## Postgres Schema

A single helper table created by `init-db.sql` at first container boot:

```sql
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

CREATE INDEX IF NOT EXISTS idx_seen_jobs_hash    ON seen_jobs(job_hash);
CREATE INDEX IF NOT EXISTS idx_seen_jobs_seen_at ON seen_jobs(seen_at DESC);
```

n8n owns its own schema in the same database (workflows, executions, credentials) — the helper table coexists without conflict.

## Google Sheet Schema

| Column | Source |
|--------|--------|
| `date` | `new Date().toISOString().slice(0,10)` |
| `source` | One of `adzuna` / `hn` |
| `title` | From normalized job |
| `company` | From normalized job |
| `location` | From normalized job |
| `url` | Job posting URL |
| `score` | Haiku output |
| `fit_summary` | Haiku output |
| `requirements` | Haiku output, joined with `;` |
| `drive_folder` | Web view link of created folder |
| `resume_link` | Web view link of uploaded resume PDF |
| `cover_letter_link` | Web view link of uploaded cover PDF |
| `status` | Default `to_review` |

You update `status` manually as you progress (`applied`, `rejected`, `interview`, etc.).

## Credentials in n8n

Both workflows (main and sub) share the same credential records — there is one Postgres, one Anthropic, one Google Drive, one Google Sheets, and one Gmail SMTP credential, referenced from whichever workflow needs them. The workflows expect the following credentials to be created in the n8n UI before activation:

| Name | Type | Used By |
|------|------|---------|
| Postgres (jobbot) | Postgres | `Postgres Check Seen`, `Postgres Insert Seen` |
| Anthropic | `anthropicApi` | `Claude Score Fit`, `Claude Tailor Resume`, `Claude Cover Letter` |
| Google Drive OAuth2 | Google Drive | `Drive Create Folder`, `Drive Upload Resume`, `Drive Upload Letter` |
| Google Sheets OAuth2 | Google Sheets | `Sheets Append Row` |
| Gmail SMTP | SMTP | `Email Notify` |

The Claude HTTP nodes authenticate via the stored `anthropicApi` credential (not an env var). Adzuna is still passed as environment variables and consumed inside the Code node expressions, so no n8n credential record is needed for it.

## Environment Variables Reference

| Var | Purpose |
|-----|---------|
| `N8N_HOST` / `N8N_PORT` / `N8N_ENCRYPTION_KEY` | n8n runtime |
| `GENERIC_TIMEZONE` / `TZ` | Schedule trigger timezone |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Postgres credentials |
| `ADZUNA_APP_ID` / `ADZUNA_APP_KEY` / `ADZUNA_COUNTRY` | Adzuna API |
| `JOB_KEYWORDS` / `JOB_LOCATION` / `JOB_MIN_SCORE` / `JOB_MAX_AGE_DAYS` | Search filters — `JOB_KEYWORDS` is a comma-separated list of 14 roles; `JOB_LOCATION` (`remote`) now only feeds the Adzuna `what_phrase='remote'` query |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASS` / `NOTIFY_TO` | Email |
| `GOTENBERG_URL` | Internal — `http://gotenberg:3000` |

Anything secret stays in `.env`, which is `.gitignore`'d.
