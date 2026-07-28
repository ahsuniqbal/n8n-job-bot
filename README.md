# n8n Job Bot

Self-hosted daily job-discovery and application-prep pipeline. It runs on your own machine in Docker, pulls jobs from free APIs every morning, scores each one against *your* profile with Claude, and for every high-fit role writes a tailored resume + cover letter, renders them to PDF, files them in a per-job Google Drive folder, logs a row in Google Sheets, and emails you.

It stops at packaging. **It never submits an application for you** — you review and click Apply yourself.

```
Schedule 8am → Adzuna + HN "Who is hiring" → dedupe → keyword prefilter
     └→ per job: Postgres seen-check → Claude score → gate on threshold
              → tailor resume → tailor cover letter → Gotenberg PDFs
              → Drive folder + upload → Sheets row → mark seen → email
```

## What you get

- **Two free sources** — [Adzuna](https://developer.adzuna.com) (remote-filtered) and Hacker News "Who is hiring" via the Algolia API. Official/public APIs only; no scraping, no LinkedIn ToS risk.
- **Fit scoring** — Claude Haiku scores 0–100 against a candidate profile you write into the prompt. Jobs below `JOB_MIN_SCORE` are dropped before any expensive work.
- **Truthful tailoring** — Claude Sonnet reorders and reframes your existing resume. The prompt forbids inventing employers, dates, titles, or metrics, and forbids touching your HTML/CSS design.
- **Matching cover letter** — same visual design as the resume, so the pair looks like one set.
- **Dedupe that survives restarts** — every job gets a hash stored in Postgres (`seen_jobs`), so you never get the same posting twice.
- **Everything local** — n8n, Postgres, Gotenberg, your resume, and your data all live in this folder.

## Cost

Job sources are free. You pay only for Anthropic API tokens: one small Haiku call per prefiltered job, plus two Sonnet calls per job that clears the score threshold. Tune `JOB_KEYWORDS` and `JOB_MIN_SCORE` to control volume.

## Stack

| Piece | What it does |
|---|---|
| **n8n** | Workflow orchestration, scheduling, credentials |
| **Postgres 16** | n8n's own DB + the `seen_jobs` dedupe table |
| **Gotenberg 8** | HTML → PDF rendering |
| **Anthropic Claude** | Scoring (`claude-haiku-4-5-20251001`), tailoring (`claude-sonnet-5`) |
| **Google Drive / Sheets** | Document storage and the tracking spreadsheet |
| **SMTP** | Digest email per match |

## Requirements

- Docker + Docker Compose
- An [Anthropic API key](https://console.anthropic.com) (paid usage)
- Free [Adzuna developer](https://developer.adzuna.com) credentials
- A Google account (for Drive + Sheets OAuth)
- An SMTP account — Gmail with an [app password](https://myaccount.google.com/apppasswords) works

---

## What you must provide yourself

This repo ships the plumbing, not the person. Nothing here works until you replace all of the following with your own values.

| # | Thing | Where |
|---|---|---|
| 1 | API keys, DB password, SMTP creds, target roles | `.env` (copy from `.env.example`) |
| 2 | Your actual resume | `resume/resume.html` |
| 3 | Your candidate profile inside the scoring prompt | **Claude Score Fit** node, in n8n |
| 4 | Your own Google Sheet ID | **Sheets Append Row** node, in n8n |
| 5 | n8n credentials — Postgres, Anthropic, Drive, Sheets, SMTP | n8n UI → Credentials |

Steps below walk through each.

---

## Setup

### 1. Configure env

```bash
cp .env.example .env
```

Fill in `.env`:

| Variable | How to get it |
|---|---|
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 16` — losing this makes stored credentials unreadable |
| `POSTGRES_PASSWORD` | Any strong password |
| `ADZUNA_APP_ID` / `ADZUNA_APP_KEY` | https://developer.adzuna.com |
| `ADZUNA_COUNTRY` | 2-letter code, e.g. `us`, `gb`, `de` |
| `ANTHROPIC_API_KEY` | https://console.anthropic.com |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASS` | Your mail provider; Gmail → app password |
| `NOTIFY_TO` | Where digest emails land |
| `GENERIC_TIMEZONE` / `TZ` | Your timezone, e.g. `Europe/Berlin` — drives the 8 AM trigger |

Tuning knobs:

- `JOB_KEYWORDS` — comma-separated target roles. Adzuna is queried **once per keyword**, so keep it to ~15 to stay inside the free tier.
- `JOB_LOCATION` — `remote` by default.
- `JOB_MIN_SCORE` — fit threshold (0–100). Below this, no tailoring happens. Start at `70`.
- `JOB_MAX_AGE_DAYS` — ignore postings older than this.

### 2. Put in your resume

Replace `resume/resume.html` with your own — a complete, styled HTML document (`<!DOCTYPE html>`, inline `<style>` block, your name and contact in the header). Tailoring preserves the markup and CSS exactly and rewrites only the text, so the design you ship here is the design that comes out the other end.

The folder is mounted read-only into n8n at `/data/resume`, and the workflow reads `/data/resume/resume.html`. Keep that filename or update the **Read Resume MD** node.

### 3. Start the stack

```bash
docker compose up -d
docker compose logs -f n8n
```

Open http://localhost:5678 and create the owner account. `init-db.sql` creates the `seen_jobs` table automatically on first Postgres boot.

### 4. Add credentials in the n8n UI

| Credential | Values |
|---|---|
| **Postgres** | host `postgres`, port `5432`, db/user/password from `.env` |
| **Anthropic** | paste your `ANTHROPIC_API_KEY` — the HTTP nodes use this stored credential, not the env var |
| **Google Drive** | OAuth flow |
| **Google Sheets** | OAuth flow |
| **SMTP** | host/port/user/password from `.env` |

### 5. Create your tracking Google Sheet

New spreadsheet, first row exactly:

```
Date | Source | Title | Company | Location | URL | Score | Fit Summary | Requirements | Drive Folder | Resume Link | Cover Letter Link | Status
```

Keep the sheet ID from its URL — you'll point the workflow at it in step 7.

### 6. Import the workflows

The pipeline is two workflows, exported to `backups/`:

- `main-*.json` — **Job Bot** — schedule trigger, source fan-out, dedupe, prefilter, calls the sub-workflow once per job
- `sub-*.json` — **Job Bot — Process One Job** — scoring, tailoring, PDFs, Drive, Sheets, email

In n8n: **Workflows → Import from File**. Import the **sub-workflow first** — the main workflow references it by ID — then the main one.

If n8n assigns the sub-workflow a new ID on import, open the main workflow's **Process One Job** node and re-select the sub-workflow from the dropdown.

### 7. Make it yours

Three nodes carry the previous owner's details and **must** be edited:

- **Claude Score Fit** — the prompt contains a hardcoded candidate summary ("senior engineer, 7+ years, React/Next.js…"). Replace that block with your own background, or scoring will rank jobs against someone else's career. This is the single highest-leverage thing to get right.
- **Sheets Append Row** — swap `documentId` for your own sheet ID and re-pick the tab.
- **Drive Create Folder / Drive Upload** — re-select your Drive and the parent folder you want job folders created under.

Then re-select every credential on the Postgres, Anthropic, Drive, Sheets, and email nodes — credentials are never included in exports.

### 8. Test before enabling the schedule

Run the main workflow manually once with `JOB_MIN_SCORE` lowered so at least one job gets all the way through. Check that a Drive folder appears, both PDFs render, the Sheet row lands, and the email arrives. Then restore your threshold and activate the workflow.

---

## Commands

```bash
docker compose up -d                          # start
docker compose down                           # stop
docker compose logs -f n8n                    # tail logs
docker compose pull && docker compose up -d   # update images
```

Reset the dedupe table (re-process jobs you've already seen):

```bash
docker compose exec postgres psql -U n8n -d n8n -c "TRUNCATE seen_jobs;"
```

## Layout

```
backups/        exported workflow JSON — re-export here after edits
docs/           full design + per-node documentation (start at docs/README.md)
resume/         your master resume — mounted read-only at /data/resume
workflows/      mounted read-write at /data/workflows for runtime file I/O
n8n_data/       n8n state and encrypted credentials  (gitignored)
postgres_data/  database files                        (gitignored)
init-db.sql     creates the seen_jobs dedupe table
```

## Documentation

`docs/` has the deep version: [overview](docs/01-overview.md), [problem & design](docs/02-problem-solution.md), [stage-by-stage workflow](docs/03-workflow.md), [node inventory](docs/04-tools-nodes.md), [Mermaid diagrams](docs/05-diagram.md), and a [node-by-node deep dive](docs/06-workflow-deep-dive.md) covering every expression and config choice.

## Security notes

- `.env`, `n8n_data/`, and `postgres_data/` are gitignored. Keep it that way — `n8n_data/` holds your encrypted credential store.
- Exported workflow JSON does not contain credential secrets, but it **does** embed Google Sheet IDs, Drive folder IDs, email addresses, and whatever personal detail you wrote into the prompts. Scrub `backups/` before pushing a fork.
- `resume/resume.html` contains your phone number, email, and address. It is not gitignored by default — add it if your repo is public.
- The stack binds n8n to `localhost:5678` and Postgres to `localhost:5433` with no TLS. It is built for local use; do not expose these ports to the internet as-is.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No jobs at all | Adzuna keys missing/invalid, or `JOB_KEYWORDS` too narrow. Check the **Fetch All Sources** node output. |
| Jobs found, none processed | Every job already in `seen_jobs`, or all scored below `JOB_MIN_SCORE`. |
| Scores look random | You skipped step 7 — the prompt still describes the original candidate. |
| PDF step fails | Gotenberg unhealthy: `docker compose logs gotenberg`. |
| Drive/Sheets 401 | OAuth token expired — reconnect the credential in the n8n UI. |
| No email | Gmail needs an app password, not your account password; check `SMTP_USER` matches the sending account. |

## Non-goals

- **Auto-apply.** Deliberate. The pipeline packages; you submit.
- **LinkedIn.** Its Jobs API is partner-gated and unofficial scrapers risk account bans.
- **A CRM.** The Google Sheet is the whole tracking surface.

## License

No license file yet — add one before others can legally reuse this.
