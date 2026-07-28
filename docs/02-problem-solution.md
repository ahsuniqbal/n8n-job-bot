# 02 — Problem & Solution

## The Problem, In Detail

### 1. Job Discovery Is Fragmented

There is no single source of truth for jobs. Indeed has roles LinkedIn doesn't. Remotive has remote roles missing from both. Hacker News' "Who is hiring" thread has roles posted nowhere else. Each board has different keywords, different freshness, different ranking. Manually visiting five sites and running the same query is slow and lossy.

### 2. LinkedIn's API Is Closed

LinkedIn's official Jobs API requires a partnership approval typically granted only to ATS vendors. Public developers cannot get access. Unofficial routes — scraping HTML, third-party scraping APIs — work but violate ToS and risk account suspension. Excluded from this design.

Other big aggregators (Indeed Publisher API, Glassdoor) have also closed their APIs to new developers in the last several years, leaving free tier sourcing dependent on a smaller number of providers.

### 3. Tailoring Is The High-Value Step That Gets Skipped

Recruiters and ATS systems both reward resumes that mirror the job description's vocabulary. A truthful but reframed resume converts far better than a generic one. But rewriting your resume per role takes 20-40 minutes of focused work and is the first thing to be cut when applying at volume.

### 4. Tracking Falls Apart Without Structure

After applying to 30 roles you cannot remember which version of your resume went where, which company asked about systems design vs. product instinct, or whether you already passed on a role last week. A spreadsheet helps; one that auto-populates with links to materials helps more.

### 5. Automation That Submits Forms Is Risky

Tools that auto-submit applications via browser automation (LinkedIn Easy Apply bots, similar) cross a line: they impersonate the candidate to a third-party site under terms of service that prohibit it. Risks include account suspension and platform-wide reputation damage. The cost-benefit is poor.

## The Solution Shape

The pipeline is organized around five principles:

### Principle 1 — Aggregate Many Free Sources, Not One Paid Source

Instead of one curated paid API, the bot queries two free sources in parallel, once per keyword:

- **Adzuna** — broad aggregator with official API, ~1000 free calls/month. Queried remote-only via `what_phrase='remote'` with no `where` filter, one call per keyword.
- **HN Algolia** — Hacker News "Who is hiring" thread comments, fully free, no key. Searched per keyword against the comment index.

This started as five sources. Remotive, RemoteOK, and Arbeitnow were dropped after live testing returned junk: Remotive ignores its search parameter (it returns the same generic feed regardless of query), RemoteOK's feed is dominated by non-tech spam, and Arbeitnow is effectively a German-language board. None returned results relevant to this candidate.

Adzuna is geo-based — its "remote" results skew toward US-listed roles — so there is a US bias in the raw feed. The fit scorer and a cheap prefilter (below) compensate by demoting or dropping the noise that survives. Each source fails quietly: if one 5xx's, the other still runs and the digest still ships.

### Principle 2 — Normalize, Then Dedupe

Each source returns wildly different JSON. The first transform inside n8n flattens every result to a common schema:

```
{ source, title, company, location, url, description, posted }
```

An FNV-1a hash of `(title|company|url)` becomes the dedupe key, persisted in Postgres. The same role appearing in Adzuna and HN is collapsed; a role seen yesterday is skipped today.

### Principle 3 — Score Before You Tailor

Tailoring is expensive (Sonnet tokens). Scoring is cheap (Haiku tokens). Cheaper still is a regex **prefilter** that runs before any LLM call: it drops jobs with no tech/AI signal via a word-boundary token match against the title and description, so obvious noise never reaches Haiku and the classifier volume stays low.

What survives the prefilter goes to a candidate-aware classifier. The Haiku prompt embeds a compact candidate profile plus a 0–100 fit rubric — scoring is grounded in who this candidate actually is, not a bare keyword count. It returns the fit score plus a short list of extracted requirements. Only roles above a configurable threshold (default 70) progress to the tailoring stage. This keeps LLM costs proportional to high-quality results.

### Principle 4 — Tailor Truthfully, Render Clean PDFs

The master resume is `resume.html` — a designed HTML/CSS document, not Markdown. The tailoring prompt instructs Claude Sonnet (`claude-sonnet-5`) to:

- Reorder bullets to surface the experience most relevant to this role.
- Reframe the summary to lead with the matching domain.
- Pull skill keywords into prominence.
- Never invent facts, employers, dates, or metrics.

Critically, tailoring **preserves the resume's exact HTML/CSS design** — it only reorders and reframes existing text within that structure, never touching the layout and never inventing content. The cover letter is generated to reuse the same CSS, so the two PDFs read as one matching set. Each finished HTML document is shipped to a local **Gotenberg** container that renders it through headless Chromium and returns a PDF.

PDFs render locally — no external paid PDF service, no upload-to-third-party.

### Principle 5 — File Everything, Notify The Human

For every accepted match the pipeline:

1. Creates a Drive folder named `{Title}_{Company}_{YYYY-MM-DD}`.
2. Uploads the resume PDF and cover letter PDF into that folder.
3. Appends a row to the Google Sheet: date, source, title, company, location, url, score, fit summary, requirements, folder link, resume link, cover letter link, status (`to_review`).
4. Records the job hash in Postgres so it's never re-processed.
5. Sends an email with a one-line summary and direct links to the folder and the job posting.

Sheet plus email become the single review surface. Drive holds the artifacts. Postgres holds the history.

## What This Solution Deliberately Does Not Do

- It does **not** submit applications. That stays manual.
- It does **not** scrape LinkedIn, Indeed, or Glassdoor. Free APIs only.
- It does **not** build a custom dashboard. Sheet + email are enough.
- It does **not** keep a vector database of your past applications. Out of scope.
- It does **not** retry indefinitely on transient errors. Failed jobs are skipped and re-discovered next run.

This keeps the surface area small, the running cost near zero, and the legal posture clean.
