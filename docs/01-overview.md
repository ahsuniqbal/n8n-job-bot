# 01 — Project Overview

## What This Is

**n8n Job Bot** is a self-hosted, fully automated job discovery and application-prep pipeline. It runs daily inside Docker on your local machine, surfaces jobs that match your target roles across two free job sources (Adzuna and Hacker News "Who is hiring"), ranks them with an LLM, and for every high-fit role automatically:

- Tailors your resume to the job description
- Drafts a focused cover letter
- Converts both into PDFs
- Uploads them to a per-job folder on Google Drive
- Logs the role with all links in a Google Sheet
- Emails you a notification

You stay in control of submission — the bot does the discovery, scoring, writing, and packaging work; you click **Apply** when satisfied.

## Why Build This

Applying to jobs the traditional way is slow and uneven:

- You spend hours searching across multiple sites that don't share results.
- You either send a generic resume everywhere (low conversion) or rewrite it for each role (unsustainable).
- You lose track of which roles you applied to, when, and with which version of your materials.
- The work that has the highest leverage — tailoring — is the work most people skip.

This pipeline removes the boring parts (searching, deduping, scoring, packaging) so the only thing you spend time on is reviewing matches and deciding whether to apply.

## Goals

1. **Zero ongoing cost for sourcing** — only free job APIs.
2. **All data stays local** — Postgres, n8n, files, and resume all sit inside this folder.
3. **One-folder deployment** — `docker compose up -d` brings the whole stack online.
4. **Reproducible, no scraping** — each job source is an official or public API. No browser automation, no LinkedIn ToS risk.
5. **Truthful tailoring** — the LLM is instructed to reorder and reframe, never invent.

## Non-Goals

- **Auto-apply.** The pipeline stops at packaging. It will not submit applications on your behalf. Submission is a manual click — by design.
- **LinkedIn job search.** LinkedIn's Jobs API is gated to partners; unofficial scrapers risk account bans. Excluded.
- **A general-purpose CRM.** The Google Sheet is the tracking surface; no UI is built on top.

## Who This Is For

A job seeker who:

- Has a defined domain or set of keywords they hunt within.
- Wants to apply to many roles without commoditizing their resume.
- Is comfortable running Docker locally and entering API keys.
- Trusts an LLM to draft tailored copy that the candidate will review before sending.

## High-Level Outcome

Every morning at 8 AM (local time), you receive an email digest of new high-fit roles. Each one already has a tailored resume PDF, a tailored cover letter PDF, and a dedicated folder on your Drive. Your Sheet has a new row per role with score, fit summary, requirements, and direct links to the PDFs. Reviewing and applying takes minutes instead of hours.
