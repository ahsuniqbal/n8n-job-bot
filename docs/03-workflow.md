# 03 — Workflow

This document describes the runtime flow at a stage-by-stage level. Per-node configuration detail lives in [06-workflow-deep-dive.md](06-workflow-deep-dive.md).

The pipeline is split across **two** workflows for per-job error isolation. The **main** workflow — `Job Bot — Discover, Tailor, Apply Prep` (5 nodes) — handles the schedule, source fetch, dedupe, and prefilter, then dispatches each surviving job to the **sub** workflow — `Job Bot — Process One Job` (26 nodes) — which runs the entire per-job pipeline (seen-check through email) in its own sub-execution. The stages below are grouped accordingly: Stages 1–3 run in the main workflow, Stages 4–12 run inside the sub workflow, once per job.

## Trigger

The workflow is driven by a **Schedule Trigger** set to fire once per day at 08:00 in the configured timezone (`Asia/Karachi` by default). Manual execution from the n8n UI is also supported for testing.

## Stage 1 — Source Aggregation

A single **Code** node, `Fetch All Sources`, queries two remote sources. `JOB_KEYWORDS` is a comma-separated list of 14 target roles, and the node loops per keyword against each source:

1. **Adzuna** — one `GET /v1/api/jobs/{country}/search/1` per keyword with `app_id`, `app_key`, `what=<keyword>`, `what_phrase='remote'` (no `where` parameter), `country=us`, `results_per_page=50`, and `max_days_old`. Constraining on the `remote` phrase rather than a location returns remote-mentioning roles.
2. **HN Algolia** — first find the latest "Ask HN: Who is hiring" story, then run a per-keyword comment search under that story.

Remotive, RemoteOK, and Arbeitnow were removed as sources — they returned mostly junk/irrelevant listings. Each source is wrapped in a try/catch; a failed source contributes an empty array and the run continues. Normalization runs inline — every result is mapped to `{ source, title, company, location, url, description, posted }` before being emitted as separate items.

## Stage 2 — Deduplication

A second **Code** node, `Dedupe + Hash`, computes a 32-character SHA-256 hash of `(title|company|url)` for every item and skips duplicates within the same batch. Items missing a title or URL are dropped. Each surviving item gains a `job_hash` field used downstream.

## Stage 2.5 — Relevance Prefilter

A **Code** node, `Prefilter Relevant`, sits between dedupe and the loop and drops any job whose combined title + description contains no tech/AI token. It matches against a word-boundary regex covering terms like `engineer`, `developer`, `frontend`, `full-stack`, `software`, `react`, `node`, `typescript`, `ai`, `ml`, `llm`, `gpt`, `agent`, and similar. This cuts the volume of jobs that reach the paid scorer.

## Stage 3 — Per-Job Dispatch

**Process One Job** (Execute Workflow v1.1) is the last node in the main workflow. It runs in `mode: each` — meaning it fires the sub workflow (`Job Bot — Process One Job`) once per prefiltered job — with `onError: continueRegularOutput`. This replaces the old `Loop Over Jobs` Split In Batches node and its loopbacks: instead of iterating in-place and threading every terminal path back to a batch node, the main workflow now hands each job to a fresh sub-execution and moves on to the next.

The point of the split is **per-job error isolation**. Because each job runs in its own sub-execution and the dispatcher is set to `continueRegularOutput`, a job that throws mid-pipeline is skipped and the remaining jobs still process — one bad listing no longer aborts the whole run. Inside the sub workflow there are no loopbacks at all: a rejected job simply ends its sub-execution and control returns to the parent, which dispatches the next one.

## Stage 4 — Already-Seen Filter

Inside the sub workflow, **Job Input** (an Execute Workflow Trigger) receives the single job passed in by the parent and passes it through unchanged. It feeds **Postgres Check Seen**, which runs `SELECT 1 AS exists_flag FROM seen_jobs WHERE job_hash = $1`. The downstream **IF Unseen** node routes the job to the LLM only when `exists_flag` is empty (no row returned). Seen jobs hit the false branch, which simply ends this sub-execution — there is no loopback; control returns to the parent, which dispatches the next job.

## Stage 5 — Fit Scoring

**Claude Score Fit** posts to Anthropic's `/v1/messages` with `claude-haiku-4-5-20251001` (cheapest tier). The prompt is candidate-aware: it embeds a compact candidate profile plus a 0–100 scoring rubric, and asks for a strict JSON object:

```json
{ "score": 0-100, "fit_summary": "one sentence", "requirements": ["...", "..."] }
```

**Parse Score JSON** extracts the JSON block from Claude's response, attaches the parsed fields to the job, and emits a single item.

**IF Score >= Threshold** compares `score` against `JOB_MIN_SCORE` from the environment (default 70). Below threshold → the false branch ends this sub-execution and control returns to the parent for the next job. Above → proceed to tailoring.

## Stage 6 — Resume Load

**Read Resume MD** reads `/data/resume/resume.html` (mounted read-only from the host folder `./resume/`) — the master resume is now HTML; the old `resume.md` was deleted. **Resume Binary → Text** decodes the binary via n8n's `getBinaryDataBuffer` helper (which correctly handles filesystem binary storage) into a UTF-8 string on `resume_md`, merged with the upstream job data.

## Stage 7 — Tailoring (Parallel)

Two HTTP nodes fan out in parallel:

- **Claude Tailor Resume** — `claude-sonnet-5` (`max_tokens` 8000), instructed to preserve the master resume's exact HTML/CSS and design and only reorder or reframe the text. The prompt forbids fabrication.
- **Claude Cover Letter** — `claude-sonnet-5` (`max_tokens` 5000), a focused cover letter that reuses the resume's CSS so both PDFs share the same look, output as a complete HTML document.

Both responses are extracted (`Extract Resume HTML`, `Extract Letter HTML`). Because Sonnet 5 emits a thinking block first, each Extract node must select the response content block whose `type` is `text` before stripping code fences, then convert the result to a binary buffer labeled `index.html` for Gotenberg.

## Stage 8 — PDF Rendering

**Gotenberg Resume PDF** and **Gotenberg Letter PDF** POST the HTML buffer to `http://gotenberg:3000/forms/chromium/convert/html` as `multipart/form-data` with the field `files`. Gotenberg renders via headless Chromium and returns a PDF binary. Two small Code nodes (`Rename Resume PDF`, `Rename Letter PDF`) attach a meaningful filename (`Resume_{Company}.pdf`, `CoverLetter_{Company}.pdf`) and label the binary properties as `resume_pdf` and `cover_pdf` respectively.

## Stage 9 — Convergence

**Merge Resume+Letter** (Combine By Position) reunites the two parallel branches into a single item — the resume branch feeds input 0 and the letter branch input 1.

## Stage 10 — Drive Layout

**Drive Create Folder** creates `{Title}_{Company}_{YYYY-MM-DD}` at the Drive root. **Combine Binaries** then consolidates both PDFs onto one item's binary payload while preserving the upstream job metadata in `json`. The returned folder ID is used by the next two Drive nodes.

- **Drive Upload Resume** uploads `Resume_{Company}.pdf` into the folder.
- **Drive Upload Letter** uploads `CoverLetter_{Company}.pdf` into the same folder.

Both run in parallel from the folder-creation node.

## Stage 11 — Sheet Row

**Merge Uploads** synchronizes the two parallel uploads. **Build Sheet Row** assembles the final row payload from `Combine Binaries`, `Drive Create Folder`, `Drive Upload Resume`, and `Drive Upload Letter` references. **Sheets Append Row** appends the row to the configured spreadsheet using auto-mapped input columns.

## Stage 12 — Persist + Notify

**Postgres Insert Seen** records `(job_hash, source, title, company, url, score, drive_folder)` into the `seen_jobs` table using an **upsert** operation (conflict target `job_hash`). This replaced an older comma-joined `executeQuery`, which broke whenever a title or company contained a comma. It is the dedupe guard for tomorrow's run.

**Email Notify** sends an HTML email to `NOTIFY_TO`. Subject contains the score, title, and company. Body contains the fit summary, source, location, and links to the job posting and the Drive folder. `Email Notify` is the last node in the sub workflow; once the email is sent the sub-execution ends and control returns to the parent, which dispatches the next job.

## End State Per Job

After a successful per-job run:

- One row exists in the Google Sheet.
- One folder with two PDFs exists on Drive.
- One row exists in `seen_jobs`.
- One email has been sent.

Per-job error isolation is now in place. Because each job runs in its own sub-execution and the main workflow dispatches with `onError: continueRegularOutput`, an unhandled error mid-job is contained to that job's sub-execution: the failing job is skipped and the batch continues, so jobs queued behind it still process in the same run. Nothing is written for the failed job, and the next daily run rediscovers only it. This was verified with a forced-failure test — an injected error in one job did not stop the remaining jobs from completing.

## Daily Run Footprint

With only two sources and the relevance prefilter in front of the scorer, the paid volume is much lower than the earlier five-source design. For a typical day (fewer raw results now that Adzuna and HN are the only sources, trimmed further by dedupe, then materially cut again by the prefilter before anything unseen reaches Haiku, with a handful landing above threshold), the workflow performs, roughly:

- Outbound source GETs — one Adzuna call per keyword plus the HN story lookup and per-keyword comment searches (no longer a flat 5)
- One Postgres SELECT per unseen candidate
- One Haiku call per unseen candidate — the prefilter meaningfully reduces this count versus scoring every deduped job
- Two Sonnet calls (tailor + letter) per above-threshold job
- Two Gotenberg renders, two Drive uploads, one Drive folder create, one Sheets append, one Postgres upsert, and one email per above-threshold job

Total external cost: a few cents in Anthropic tokens; everything else runs free.
