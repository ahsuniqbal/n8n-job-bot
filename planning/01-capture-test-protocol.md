# 01 — Capture Test Protocol (2 Weeks)

**Status:** pre-build validation. Do NOT write product code until this passes.

## Why this exists

The SaaS thesis is a **career companion that remembers** — the moat is personal interview
memory (L1): log every interview, and future prep gets sharper because it knows *your*
weaknesses. Everything downstream (aggregate/network-effect layer, tailoring, sourcing)
is worthless if one behavior doesn't hold:

> A real person, after a real interview, logs a 60-second retro — **repeatedly**.

That is a *behavioral* unknown, not a technical one. So we test it by hand (concierge /
Wizard-of-Oz), with no product, before building anything.

## The one question this test answers

**After a user feels the payoff of logging interview #1 (personalized prep drawn from it),
do they log interview #2 unprompted?**

If yes, the reciprocity flywheel closes → build.
If they ghost after #1 despite feeling the value → capture is structurally broken → pivot
the mechanic or kill the moat. No amount of UI polish fixes a dead loop.

## Kill criteria — pre-committed (do not move these mid-test)

| Signal | Green | Red (kill / pivot) |
|---|---|---|
| Sustained capture rate (logged ÷ total interviews across cohort) | ≥ 50% | < 40% |
| Unprompted capture #2 after payoff #1 | ≥ half the cohort | < a third |
| Log latency | same-day majority | mostly days-late / never |

If results land between green and red: extend one week, don't rationalize.

## Bias warning (own-network cohort)

Friends log to *help you*, not because the loop works — this inflates capture. Corrections:

1. Open every recruit with: *"Be brutal. If you wouldn't log it for a stranger's product,
   don't log it. Skipping is the most useful signal you can give me."*
2. Track **prompted vs unprompted** separately. Only *unprompted* logs count toward the
   green line. A log that needed a nudge from you = a log that wouldn't happen in production.
3. Discount the final capture number ~15-20% when reading it. If it barely clears green on
   friends, treat as red for strangers.

## Recruit script (copy-paste, DM)

> Hey — building a small tool that helps you prep for interviews by remembering how your
> past ones went. Testing it by hand first, no app yet. If you're interviewing over the next
> 2 weeks: after each one you send me a 60-sec voice note or fill a quick form, and before
> your next interview I send you personalized prep based on your history. Free, I do the work.
> Only ask: be brutally honest — if you can't be bothered to log one, don't, that's the data
> I need. In?

Target: 5-10 people who are **actively interviewing now**. Fewer honest loggers > more polite ones.

## Retro capture form (Typeform / Google Form) — minimal schema

Keep it 60 seconds. Chips/dropdowns, not essays. Voice-note fallback for everything.

- **Company** + stage (seed / growth / big / unknown)  ← aggregate join key (future L2)
- **Role type** (backend-IC / frontend / fullstack / PM / data / other)  ← join key
- **Round type** (recruiter screen / coding / system-design / behavioral / onsite / other)
- **Questions asked** — repeatable: `{ text, category, self-rated 1-5, tripped on? y/n }`
- **What landed / what didn't** — one line each
- **Outcome** (advanced / rejected / ghosted / offer / waiting)  ← hardest + most valuable
- Date (auto)

Cut any field >30% of loggers skip. Skips are schema signal.

## Your job (Wizard-of-Oz the AI)

- **Within 1 hour of "I interviewed"** → send the retro link. Fresh memory window is everything.
- Structure each retro by hand into the schema (a spreadsheet is fine).
- Before their next interview → **hand-write the prep**: pull their weak categories
  (self-rated ≤2, tripped-on) + resume + JD → "Last time sys-design tripped you; drill X, Y."
  Fabricate the "it remembers you" moment on interview #1 using profile + generic aggregate,
  so payoff isn't delayed to #3.
- The prep is the **bribe**: they only get it *after* logging. Retro = the unlock. Reciprocity
  is the capture driver — make it obvious.

## Tracking sheet (one row per interview)

`user | date | company | role_type | round_type | logged? (y/n) | prompted or unprompted |
latency_hours | is this their #2+? | got_payoff_before? | notes`

This sheet *is* your result. Capture rate, latency, and the #2-after-payoff number all read
straight off it.

## Two-week cadence

- **Days 1-2:** recruit cohort, set up form + tracking sheet.
- **Days 3-12:** run the loop — retro link within 1h, structure by hand, hand-write next-round prep.
- **Days 13-14:** read the sheet against kill criteria. Decide: build / extend / pivot / kill.

## Decision gate

- **Green** → build the thinnest MVP (profile → match → tailor+prep → manual apply+track →
  retro → memory feeds next prep). Auto-apply stays out of v1.
- **Between** → extend one week; tighten the payoff/bribe mechanic; re-read.
- **Red** → the personal-memory moat doesn't hold on behavior. Pivot capture (voice-first?
  auto-pull from calendar? interviewer-side?) or drop the thesis before writing code.
