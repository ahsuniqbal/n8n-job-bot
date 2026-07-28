# 06 — Workflow Deep Dive (Per-Node Detail)

This document walks through every node in the pipeline with its purpose, exact configuration, key expressions, inputs, outputs, and the reasoning for why it is shaped the way it is. It's written so that a reader who has never opened the workflow can rebuild it from scratch.

The pipeline is now split across **two workflows** for per-job error isolation:

| Workflow | ID | Name | Nodes |
|----------|----|------|-------|
| **Main** | `TsWvUtT4VUBbPE2u` | `Job Bot — Discover, Tailor, Apply Prep` | 5 |
| **Sub** | `4nmCCacM8B8nfYwZ` | `Job Bot — Process One Job` | 26 |

The **main** workflow discovers, dedupes, and prefilters jobs, then invokes the **sub** workflow **once per job** via an Execute Workflow node. Each job's entire tailoring pipeline runs inside its own sub-execution, so a failure on one job errors only that sub-execution and the batch continues (see [Cross-Cutting Concerns](#cross-cutting-concerns)).

Execution order: `v1`
Timezone: `Asia/Karachi`

---

# Main Workflow (5 nodes)

**ID `TsWvUtT4VUBbPE2u` — `Job Bot — Discover, Tailor, Apply Prep`.** Runs on the daily schedule, builds the candidate job list, and hands each job off to the sub-workflow.

## 1. Schedule Daily 8am

- **Type:** `n8n-nodes-base.scheduleTrigger` (v1.2)
- **Role:** Single entry point. Fires the workflow once per day.

**Configuration**

```json
{
  "rule": {
    "interval": [
      { "field": "days", "daysInterval": 1, "triggerAtHour": 8 }
    ]
  }
}
```

**Notes**
- Timezone is inherited from `GENERIC_TIMEZONE` env var (`Asia/Karachi`), set on the n8n container.
- Manual execution from the n8n UI bypasses this and starts immediately, which is the recommended way to test.
- A separate node version (1.3) exists upstream. Bumping is a one-line change; current 1.2 runs fine.

---

## 2. Fetch All Sources

- **Type:** `n8n-nodes-base.code` (v2, JavaScript)
- **Role:** Performs the remote calls for **two** sources (Adzuna + Hacker News), normalizes results to a shared schema, returns a flat array.

**Why a single Code node instead of separate HTTP nodes**

A single Code node gives:
- One place to express filter logic per source.
- `Promise.all` parallelism without n8n having to merge multiple branches.
- Simple try/catch wrappers so any single failing source returns `[]` rather than killing the run.

**Why only two sources (three were dropped)**

The pipeline used to fan out over five boards. Three were removed because they returned mostly junk:

- **Remotive** — ignores the search query entirely and returns its full firehose, so keyword targeting was impossible.
- **RemoteOK** — dominated by non-tech / dropshipping / crypto spam listings that polluted the scorer's input.
- **Arbeitnow** — effectively a German-language job board; almost nothing matched remote English-language engineering roles.

Adzuna (server-side keyword + recency filtering) and Hacker News "Who is hiring" (high signal, developer-native) are the two that consistently returned relevant roles, so they are the only survivors.

**Environment access**

```js
const KEYWORDS = ($env.JOB_KEYWORDS || 'software engineer').split(',').map(s => s.trim()).filter(Boolean);
const LOCATION = $env.JOB_LOCATION || 'remote';
const MAX_AGE_DAYS = parseInt($env.JOB_MAX_AGE_DAYS || '7', 10);
const ADZUNA_ID = $env.ADZUNA_APP_ID;
const ADZUNA_KEY = $env.ADZUNA_APP_KEY;
const ADZUNA_COUNTRY = $env.ADZUNA_COUNTRY || 'us';
```

`JOB_KEYWORDS` is now parsed as a **comma-separated list** (currently 14 target roles), not a single string. Both sources loop over this list, one query per keyword. Uses `$env` (n8n's native env binding) instead of `process.env` to avoid TS lint warnings in the Code editor.

**HTTP helper**

```js
const http = this.helpers.httpRequest;
```

`this.helpers.httpRequest` is the in-node fetch helper. Returns parsed JSON when `json: true`.

**Source: Adzuna (looped per keyword)**

```js
for (const kw of KEYWORDS) {
  http({
    method: 'GET',
    url: `https://api.adzuna.com/v1/api/jobs/${ADZUNA_COUNTRY}/search/1`,
    qs: {
      app_id: ADZUNA_ID,
      app_key: ADZUNA_KEY,
      results_per_page: 50,
      what: kw,
      what_phrase: 'remote',
      max_days_old: MAX_AGE_DAYS,
      'content-type': 'application/json'
    },
    json: true
  });
}
```

One call per keyword, each returning up to 50 recent results. Notes on the query shape:

- There is **no `where` param**. Adzuna has no dedicated remote flag, and `where: 'remote'` returns **zero** results.
- Instead, `what_phrase: 'remote'` restricts matches to postings that literally mention "remote", which is the closest Adzuna gets to a remote filter.

Skipped silently if `ADZUNA_APP_ID` or `ADZUNA_APP_KEY` is empty.

**Source: Hacker News Algolia (looped per keyword)**

Find the latest "Ask HN: Who is hiring" story once, then run one comment search per keyword under it:

```js
// 1) Find latest "Ask HN: Who is hiring" story
const story = await http({
  method: 'GET',
  url: 'https://hn.algolia.com/api/v1/search',
  qs: { query: 'Ask HN: Who is hiring', tags: 'story', hitsPerPage: 1 },
  json: true
});
const storyId = story.hits[0].objectID;

// 2) Search comments under that story, once per keyword
for (const kw of KEYWORDS) {
  const comments = await http({
    method: 'GET',
    url: 'https://hn.algolia.com/api/v1/search',
    qs: { tags: `comment,story_${storyId}`, hitsPerPage: 100, query: kw },
    json: true
  });
}
```

Each matching comment becomes a synthetic job with `title: kw` (the keyword that matched), `company: 'HN Who is hiring'`, and `url: https://news.ycombinator.com/item?id={objectID}`.

**Normalization function**

```js
const norm = (source, j) => ({
  source,
  title: j.title,
  company: j.company,
  location: j.location,
  url: j.url,
  description: (j.description || '').slice(0, 8000),
  posted: j.posted
});
```

Description is hard-capped at 8 000 characters to stay well under Claude's per-message budget.

**Return**

```js
return sources.flat().map(j => ({ json: j }));
```

`Promise.all` resolves to an array of arrays; `.flat()` collapses; each job becomes its own n8n item.

---

## 3. Dedupe + Hash

- **Type:** `n8n-nodes-base.code` (v2, JavaScript)
- **Role:** Hash each job and drop in-batch duplicates.

**Logic**

```js
function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

const seen = new Set();
const out = [];
for (const item of $input.all()) {
  const j = item.json;
  if (!j.title || !j.url) continue;
  const key = `${(j.title||'').toLowerCase().trim()}|${(j.company||'').toLowerCase().trim()}|${j.url}`;
  const hash = fnv1a(key) + fnv1a(key.split('').reverse().join(''));
  if (seen.has(hash)) continue;
  seen.add(hash);
  out.push({ json: { ...j, job_hash: hash } });
}
return out;
```

**Why pure-JS FNV-1a instead of `crypto.createHash`**

The n8n Code node sandbox disallows `require('crypto')` — calling it throws `Module 'crypto' is disallowed`. FNV-1a is a fast non-cryptographic hash that runs in plain JavaScript. Two passes (forward + reversed key) give ~64 bits of effective entropy, which is plenty for personal-scale dedupe across hundreds of jobs.

**Why title + company + URL as the hash key**

- `url` alone collides when the same role is posted to two boards with different URLs.
- `title + company` alone collides when a company posts multiple identical-titled openings.
- The triple key is conservative — it prefers "this is a new job" over "this might be the same job."

**Output width** is 16 hex characters (two 8-char FNV-1a digests concatenated), comfortably stored in the `seen_jobs.job_hash` TEXT column.

---

## 4. Prefilter Relevant

- **Type:** `n8n-nodes-base.code` (v2, JavaScript)
- **Role:** Drop any job that mentions no tech/AI signal at all, before it reaches the paid scorer. Sits between `Dedupe + Hash` and `Process One Job`.

**Logic**

```js
const RELEVANT = /\b(engineer|developer|programmer|frontend|front[-\s]?end|full[-\s]?stack|software|react|next\.?js|vue|angular|svelte|typescript|javascript|node\.?js|node|ai|ml|llm|gen\s?ai|generative|machine\s+learning|gpt|agent|chatbot|large\s+language)\b/i;

return $input.all().filter(item => {
  const j = item.json;
  const hay = `${j.title || ''} ${j.description || ''}`;
  return RELEVANT.test(hay);
});
```

**Why a word-boundary regex**

The token list is matched against `title + ' ' + description` with `\b...\b` anchors. The boundaries matter: without them, the two-letter token `ai` matches inside `email`, `maintain`, `retail`, etc., and nothing would be filtered. Word boundaries keep `ai` matching only the standalone word.

**Purpose**

This is a cost gate. Every job that survives is sent to the paid Haiku scorer inside the sub-workflow (`Claude Score Fit`), so cutting obvious non-matches here directly reduces API spend. It is deliberately loose — any single tech/AI token keeps the job; the fine-grained fit judgement is left to the LLM.

---

## 5. Process One Job (Execute Workflow)

- **Type:** `n8n-nodes-base.executeWorkflow` (v1.1)
- **Role:** Hand each prefiltered job to the sub-workflow, one sub-execution per job. This is the **per-job isolation boundary** — and the last node in the main workflow.

**Configuration**

| Field | Value |
|-------|-------|
| `source` | `database` (call another workflow stored in this n8n instance) |
| `workflowId` | `4nmCCacM8B8nfYwZ` (`Job Bot — Process One Job`) |
| `mode` | `each` — run the sub-workflow **once per incoming item** (one job → one isolated sub-execution) |
| `onError` | `continueRegularOutput` — if a sub-execution errors, skip that item and continue with the rest |

**Why a sub-workflow with `mode: each` + `onError: continueRegularOutput`**

This replaces the old `Loop Over Jobs` (SplitInBatches) batch loop. Previously every job ran in one shared execution, so an unhandled error mid-loop (e.g. a 5xx from Anthropic or Gotenberg) threw out of the loop and aborted the entire run — all queued jobs after the failure were lost.

Now each job runs in its **own** sub-execution. `mode: each` fans the prefiltered array out into one sub-execution per job; `onError: continueRegularOutput` means a job whose sub-execution throws (anywhere in the 26-node pipeline) is simply **skipped**, and the main run moves on to the next job and still succeeds. This was verified with a **forced-failure test**: a deliberately failing job's sub-execution errored while the other jobs completed normally and the main run finished successfully. See [Cross-Cutting Concerns](#cross-cutting-concerns).

Because each job is now its own sub-execution, there is **no loopback wiring** — the SplitInBatches "every terminal must loop back" constraint is gone entirely.

---

# Sub-Workflow: Process One Job (26 nodes)

**ID `4nmCCacM8B8nfYwZ` — `Job Bot — Process One Job`.** Invoked once per job by the main workflow's `Process One Job` node. Everything below runs inside a single job's isolated sub-execution; any node erroring here fails only this one sub-execution, not the whole run.

## 1. Job Input (Execute Workflow Trigger)

- **Type:** `n8n-nodes-base.executeWorkflowTrigger` (v1.1)
- **Role:** Entry point of the sub-workflow. Receives one job (all of its fields) from the parent `Process One Job` Execute Workflow node and emits it as the single item the rest of the pipeline processes.

**Configuration**

```json
{ "inputSource": "passthrough" }
```

`inputSource: passthrough` accepts **all** data sent by the parent node as-is — there is no fixed input schema to declare, so every field the main workflow attached to the job (`title`, `company`, `location`, `url`, `description`, `job_hash`, `source`, `posted`, …) flows straight through. Downstream nodes that used to reference the loop source now reference `$('Job Input')` for the original job metadata.

---

## 2. Postgres Check Seen

- **Type:** `n8n-nodes-base.postgres` (v2.6)
- **Role:** Return one row when the job has been processed before, zero rows otherwise.
- **Input:** the single-job item emitted by `Job Input`.

**Query**

```sql
SELECT EXISTS(SELECT 1 FROM seen_jobs WHERE job_hash = $1) AS exists_flag;
```

`EXISTS()` guarantees the query always returns exactly one row (`true` or `false`). A plain `SELECT 1 ... WHERE` returns zero rows when the job is new, which makes n8n drop the item entirely and the downstream IF never fires.

**Query replacement**

```
{{ $json.job_hash }}
```

**Credential**

Postgres connection points to `host: postgres`, `port: 5432`, `database: n8n`, `user: n8n`, password from `.env`. Container-to-container DNS resolves `postgres` automatically.

**Output**

- Seen job → one item with `exists_flag: 1`
- New job → empty array (n8n still emits one empty item)

---

## 3. IF Unseen

- **Type:** `n8n-nodes-base.if` (v2.2)
- **Role:** Route only new jobs forward.

**Condition**

```json
{
  "leftValue": "={{ $json.exists_flag }}",
  "operator": { "type": "boolean", "operation": "false", "singleValue": true },
  "rightValue": ""
}
```

`exists_flag` from the upstream `EXISTS()` query is a boolean. `false` = new job → true branch → `Claude Score Fit`. `true` = seen → FALSE branch, which is **left unwired and simply terminates this sub-execution** — the job has already been processed, so there is nothing more to do. There is no loopback (each job is its own sub-execution now); ending the branch just ends this job's run and the parent moves on to the next.

**Why two IF nodes total (this one and `IF Score >= Threshold`)**

Splitting "seen check" from "score check" makes the early-exit graph easier to read and lets you visualize how many jobs are dropped at each gate by inspecting node execution counts.

---

## 4. Claude Score Fit

- **Type:** `n8n-nodes-base.httpRequest` (v4.2)
- **Role:** Cheap classifier. Returns a 0–100 fit score, one-sentence summary, and an extracted requirements list.

**Endpoint**

```
POST https://api.anthropic.com/v1/messages
```

**Headers**

| Name | Value |
|------|-------|
| `x-api-key` | `={{ $env.ANTHROPIC_API_KEY }}` |
| `anthropic-version` | `2023-06-01` |
| `content-type` | `application/json` |

**Body**

```json
{
  "model": "claude-haiku-4-5-20251001",
  "max_tokens": 600,
  "messages": [{
    "role": "user",
    "content": "You score how well a job fits THIS candidate. Return ONLY a JSON object: {\"score\":0-100,\"fit_summary\":\"one sentence\",\"requirements\":[\"req1\",\"req2\"]}.\n\n=== CANDIDATE ===\n<compact profile mirrored from profile-compact.md: senior/staff engineer, frontend forte, AI specialization, full-stack, needs remote>\n\n=== SCORING RUBRIC ===\n85-100: AI-native product / frontend-at-an-AI-company role, senior/staff, remote.\n70-84: strong frontend/full-stack with some AI exposure.\n40-69: generic engineering, no AI angle.\n0-39: off-target (non-engineering, on-site only, wrong stack).\n\n=== JOB ===\nTitle: ${$('Job Input').item.json.title}\nCompany: ${$('Job Input').item.json.company}\nLocation: ${$('Job Input').item.json.location}\nDescription: ${$('Job Input').item.json.description}"
  }]
}
```

**Why the prompt is now candidate-aware (not keyword-only)**

The old prompt only passed `$env.JOB_KEYWORDS`, so it scored keyword overlap, not actual fit. The prompt now embeds a **compact candidate profile** (mirrored from `profile-compact.md`) plus an explicit **0–100 rubric**, so Haiku scores against the real target: AI-native / frontend-at-AI-company senior roles score highest, generic no-AI roles land mid-band, off-target roles score low. Keep the profile text in sync with `profile-compact.md` when it changes.

**Job injection**

The job fields are injected via `$('Job Input').item.json` (the job received by the sub-workflow), not `$json` — after entering this HTTP node the local `$json` would otherwise be resolved at request-build time against the wrong context.

**Return shape**

`{score, fit_summary, requirements}` — consumed by `Parse Score JSON`.

**Why Haiku here**

This call runs against every unseen, prefiltered job (potentially dozens per day). Sonnet would multiply cost by ~5×. Haiku is plenty for a rubric-constrained JSON extraction.

**Validator note**

n8n's expression validator warns about a "missing `$` prefix" on this node. It is a **false positive** — it trips on the literal word `JSON` inside the prompt text, not on an actual expression. Safe to ignore.

---

## 5. Parse Score JSON

- **Type:** `n8n-nodes-base.code` (v2, JavaScript)
- **Role:** Extract the JSON object from Claude's response text and attach it to the original job item.

```js
const out = [];
for (const item of $input.all()) {
  const job = $('Job Input').item.json;
  const text = item.json?.content?.[0]?.text || '{}';
  let parsed = { score: 0, fit_summary: '', requirements: [] };
  try { parsed = JSON.parse(text.match(/\{[\s\S]*\}/)?.[0] || '{}'); } catch (e) {}
  out.push({ json: { ...job, ...parsed } });
}
return out;
```

**Why regex-extract before JSON.parse**

Claude occasionally prepends a sentence even when prompted to return only JSON. The regex grabs the first `{...}` block. If parsing still fails, the job falls back to `{score:0,...}` and gets filtered out at the threshold gate — no crash.

**Why pull job from `$('Job Input').item.json`**

After an HTTP node, `$json` refers to the API response, not the upstream job. Referencing the sub-workflow's `Job Input` node lets us reattach the original job metadata.

---

## 6. IF Score >= Threshold

- **Type:** `n8n-nodes-base.if` (v2.2)
- **Role:** Drop low-fit jobs before any Sonnet token is spent.

**Condition**

```json
{
  "leftValue": "={{ $json.score }}",
  "operator": { "type": "number", "operation": "gte" },
  "rightValue": "={{ parseInt($env.JOB_MIN_SCORE || '70', 10) }}"
}
```

Threshold is fully configurable per environment. `true` (score ≥ threshold) → `Read Resume MD`. The **FALSE** branch (below threshold) is **left unwired and terminates this sub-execution** — a below-threshold job is not worth tailoring, so its sub-execution simply ends and the parent moves on to the next job. No loopback (each job is its own sub-execution).

---

## 7. Read Resume MD

- **Type:** `n8n-nodes-base.readWriteFile` (v1)
- **Role:** Read the master resume.

**Config**

```json
{ "operation": "read", "fileSelector": "/data/resume/resume.html" }
```

The master resume is now an **HTML** file (`resume.html`); the old `resume.md` was deleted. The node name is retained for continuity. The path is the in-container mount point (bind-mounted read-only from `./resume/` on the host). Outputs a binary buffer in `$binary.data`.

---

## 8. Resume Binary to Text

- **Type:** `n8n-nodes-base.code` (v2, JavaScript)
- **Role:** Convert the resume binary to a UTF-8 string, merge with job context.

```js
const out = [];
for (let i = 0; i < $input.all().length; i++) {
  const buf = await this.helpers.getBinaryDataBuffer(i, 'data');
  const md = buf ? buf.toString('utf-8') : '';
  const job = $('Parse Score JSON').item.json;
  out.push({ json: { ...job, resume_md: md } });
}
return out;
```

**Critical fix: decode via n8n's helper, not manual base64**

n8n stores binary using the **filesystem-v2** backend, so `item.binary.data.data` is *not* the file's base64 content — it is a storage **pointer** string. The old code did `Buffer.from(item.binary.data.data, 'base64').toString('utf-8')`, which decoded that pointer into garbage. That garbage flowed into the tailor prompt, the model refused to work with it, and the pipeline produced **blank PDFs**.

The fix uses `await this.helpers.getBinaryDataBuffer(i, 'data')`, which resolves the pointer through the binary-data manager and returns the real file buffer. `.toString('utf-8')` then yields the full resume HTML, stored in `resume_md` (field name retained even though the content is now HTML).

---

## 9. Claude Tailor Resume

- **Type:** `n8n-nodes-base.httpRequest` (v4.2)
- **Role:** Generate a tailored resume as a complete HTML document that preserves the master resume's exact design.

**Body**

```json
{
  "model": "claude-sonnet-5",
  "max_tokens": 8000,
  "messages": [{
    "role": "user",
    "content": "Tailor this resume for the job below. PRESERVE the resume's exact HTML structure, CSS, and visual design — do not change layout, styles, fonts, or markup. Only reorder and reframe the TEXT (bullets, summary, skill emphasis) to match the job. Never invent facts. Output ONLY the full HTML document.\n\n===JOB===\nTitle: ${$json.title}\nCompany: ${$json.company}\nRequirements: ${JSON.stringify($json.requirements)}\nDescription: ${$json.description}\n\n===RESUME (HTML)===\n${$json.resume_md}"
  }]
}
```

**Why "Option B" — preserve structure, reframe text only**

The master resume is already a hand-designed HTML document. Rather than letting the model regenerate layout/CSS (which drifts the design every run), the prompt constrains it to keep the exact HTML structure, CSS, and design, and only **reorder/reframe the text** — never invent. The output is the full HTML document, ready for Gotenberg. The input marker is now `===RESUME (HTML)===` (was `===RESUME (Markdown)===`).

**Model + budget**

Now `claude-sonnet-5` with `max_tokens: 8000` — the larger budget is needed because the model must echo back the entire HTML document (structure + CSS + content), not just a short Markdown body.

**The "never invent" instruction**

Critical. Tailoring should reframe, not fabricate. Hiring managers spot invented numbers and dates fast.

---

## 10. Extract Resume HTML

- **Type:** `n8n-nodes-base.code` (v2, JavaScript)
- **Role:** Pull HTML from the response, strip ```` ```html ```` fences, prepare a binary `index.html` for Gotenberg.

```js
const out = [];
for (const item of $input.all()) {
  const textBlock = (item.json?.content || []).find(b => b.type === 'text');
  const html = textBlock?.text || '';
  const cleaned = html
    .replace(/^```html\n?/i, '')
    .replace(/```$/i, '')
    .trim();
  const job = $('Resume Binary to Text').item.json;
  out.push({
    json: { ...job, resume_html: cleaned },
    binary: {
      data: {
        data: Buffer.from(cleaned).toString('base64'),
        mimeType: 'text/html',
        fileName: 'index.html'
      }
    }
  });
}
return out;
```

**Critical: select the `text` block, not `content[0]`**

`claude-sonnet-5` returns a **thinking block first**, so `content[0].type === 'thinking'` and `content[0].text` is undefined — the old `content[0].text` grabbed the wrong block and produced empty HTML. The fix scans the content array with `.find(b => b.type === 'text')` to pick the actual answer block regardless of position.

`fileName: 'index.html'` is required — Gotenberg's HTML route expects exactly that filename.

---

## 11. Gotenberg Resume PDF

- **Type:** `n8n-nodes-base.httpRequest` (v4.2)
- **Role:** Convert HTML to PDF via Gotenberg.

**Endpoint**

```
POST {{ $env.GOTENBERG_URL }}/forms/chromium/convert/html
```

`GOTENBERG_URL` is `http://gotenberg:3000`, resolved via the Docker network's DNS.

**Body**

`multipart/form-data` with a single field:

| Name | Type | Source |
|------|------|--------|
| `files` | `formBinaryData` | binary property `data` |

**Response options**

```json
{ "response": { "responseFormat": "file", "outputPropertyName": "data" } }
```

This tells n8n to keep the response as a binary file rather than parsing it as JSON.

---

## 12. Rename Resume PDF

- **Type:** `n8n-nodes-base.code` (v2)
- **Role:** Give the PDF a meaningful filename and reattach the job metadata.

```js
const out = [];
for (const item of $input.all()) {
  const job = $('Extract Resume HTML').item.json;
  const fname = `Resume_${(job.company||'co').replace(/[^a-z0-9]+/gi,'_')}.pdf`;
  const bin = item.binary?.data;
  if (bin) { bin.fileName = fname; bin.mimeType = 'application/pdf'; }
  out.push({ json: job, binary: { resume_pdf: bin } });
}
return out;
```

The binary property is renamed from `data` to `resume_pdf` so the second parallel branch (cover letter) can coexist with its own `cover_pdf` property after merging.

---

## 13. Claude Cover Letter

- **Type:** `n8n-nodes-base.httpRequest` (v4.2)
- **Role:** Generate a focused cover letter as a complete HTML document that visually matches the resume.

**Body**

Same shape as the resume node: model `claude-sonnet-5`, `max_tokens: 5000`. The prompt asks for a focused 250–350 word cover letter and instructs the model to **reuse the resume's CSS, colour palette, fonts, and header** so the cover letter and resume read as one matching set (same letterhead, same type). Job context is read via `$('Resume Binary to Text').item.json` to share the same upstream payload as the resume call (this is the upstream node both branches see).

---

## 14. Extract Letter HTML

Symmetrical to the resume extractor — produces an `index.html` binary plus a `cover_html` JSON field. It carries the **same critical fix** as `Extract Resume HTML` (node 10): because `claude-sonnet-5` emits a thinking block first, it selects the response block via `(content || []).find(b => b.type === 'text')` rather than reading `content[0]`, then strips the ```` ```html ```` fences.

---

## 15. Gotenberg Letter PDF

Identical configuration to the resume Gotenberg call, on the parallel branch.

---

## 16. Rename Letter PDF

```js
const fname = `CoverLetter_${(job.company||'co').replace(/[^a-z0-9]+/gi,'_')}.pdf`;
```

Output binary property is `cover_pdf` so the merge step can hold both PDFs side-by-side.

---

## 17. Merge Resume+Letter

- **Type:** `n8n-nodes-base.merge` (v3.2)
- **Mode:** `combine`, `combineBy: combineByPosition`

Brings the two parallel branches (resume PDF / cover letter PDF) back onto a single execution path. Position-based combine is correct because both branches process the same job item in lock-step.

---

## 18. Combine Binaries

- **Type:** `n8n-nodes-base.code` (v2)
- **Role:** Build the single downstream item carrying both PDFs.

```js
const resumeItem = $('Rename Resume PDF').item;
const letterItem = $('Rename Letter PDF').item;
const job = resumeItem.json;
return [{
  json: job,
  binary: {
    resume_pdf: resumeItem.binary?.resume_pdf,
    cover_pdf:  letterItem.binary?.cover_pdf
  }
}];
```

This collapses both branches' binary payloads onto a single item. Downstream Drive uploads pick the property by name.

---

## 19. Drive Create Folder

- **Type:** `n8n-nodes-base.googleDrive` (v3)
- **Role:** Create a per-job folder at the Drive root.

**Folder name expression**

```text
={{ ($json.title || 'Job').replace(/[^a-zA-Z0-9 ]+/g,'_')
   + '_' + ($json.company || 'Co').replace(/[^a-zA-Z0-9 ]+/g,'_')
   + '_' + new Date().toISOString().slice(0,10) }}
```

Renders as e.g. `Senior_Backend_Engineer_Acme_Co_2026-06-03`. The regex strips slashes, colons, and other characters Google Drive treats specially.

**Drive / Folder resource locators**

| Field | Value |
|-------|-------|
| `driveId` | `My Drive` (default user drive) |
| `folderId` | `root` (top of Drive) |

After OAuth, in the n8n UI you should re-select these from the live dropdown so `cachedResultName` is populated and the dropdowns render correctly.

---

## 20. Drive Upload Resume

- **Type:** `n8n-nodes-base.googleDrive` (v3)
- **Role:** Upload the renamed resume PDF into the folder created above.

**Key fields**

| Field | Value |
|-------|-------|
| `name` | `Resume_{Company}.pdf` (expression) |
| `folderId` | `={{ $json.id }}` (folder ID from previous node) |
| `inputDataFieldName` | `resume_pdf` |

`inputDataFieldName` tells the node which binary property holds the file to upload.

---

## 21. Drive Upload Letter

Symmetrical to the resume upload, but uses:

- `inputDataFieldName: cover_pdf`
- `folderId: ={{ $('Drive Create Folder').item.json.id }}` (cannot use `$json.id` here because this branch's input is the folder-create result on one side, but the binary on the other — explicit reference is safer)

---

## 22. Merge Uploads

- **Type:** `n8n-nodes-base.merge` (v3.2)
- Reunites the two upload branches so the next node sees one item.

---

## 23. Build Sheet Row

- **Type:** `n8n-nodes-base.code` (v2)
- **Role:** Assemble the final tabular payload.

```js
const job    = $('Combine Binaries').item.json;
const folder = $('Drive Create Folder').item.json;
const resume = $('Drive Upload Resume').item.json;
const letter = $('Drive Upload Letter').item.json;
return [{ json: {
  date: new Date().toISOString().slice(0,10),
  source: job.source,
  title: job.title,
  company: job.company,
  location: job.location,
  url: job.url,
  score: job.score,
  fit_summary: job.fit_summary,
  requirements: (job.requirements || []).join('; '),
  drive_folder: folder.webViewLink || folder.id,
  resume_link: resume.webViewLink || resume.id,
  cover_letter_link: letter.webViewLink || letter.id,
  status: 'to_review'
} }];
```

The fallback `|| folder.id` covers the case where Drive does not return a `webViewLink` (rare, but safer than emitting an empty cell).

---

## 24. Sheets Append Row

- **Type:** `n8n-nodes-base.googleSheets` (v4.5)
- **Operation:** `append`
- **Mapping:** `autoMapInputData`

`documentId` is set to `REPLACE_WITH_YOUR_SHEET_URL` as a placeholder; before activation you must paste the actual sheet URL/ID in the UI. The sheet name defaults to `Sheet1` and should also be re-selected from the dropdown after OAuth so the column schema is fetched.

`autoMapInputData` maps the keys produced by `Build Sheet Row` 1:1 to the spreadsheet's header row.

---

## 25. Postgres Insert Seen

- **Type:** `n8n-nodes-base.postgres` (v2.6)
- **Role:** Record the processed job so tomorrow's run skips it.

**Operation**

`resource: database`, `operation: upsert`, on table `seen_jobs`, matching column `job_hash`. Each column is mapped **discretely** to its own expression:

| Column | Source expression |
|--------|-------------------|
| `job_hash` | `$('Combine Binaries').item.json.job_hash` |
| `source` | `$('Combine Binaries').item.json.source` |
| `title` | `$('Combine Binaries').item.json.title` |
| `company` | `$('Combine Binaries').item.json.company` |
| `url` | `$('Combine Binaries').item.json.url` |
| `score` | `$('Combine Binaries').item.json.score` |
| `drive_folder` | `$('Drive Create Folder').item.json.webViewLink \|\| $('Drive Create Folder').item.json.id` |

On a `job_hash` conflict the upsert updates in place rather than erroring, keeping the write idempotent within a day.

**Why upsert replaced the old `executeQuery` + comma-joined `queryReplacement`**

The previous node ran a raw `INSERT ... ON CONFLICT DO NOTHING` and fed all seven values as a **single comma-joined `queryReplacement` string**. That broke whenever a `title` or `company` itself contained a comma: the extra comma shifted every following value one position to the left, pushing a **URL string into the integer `score` column** and throwing `invalid input syntax for type integer`. Mapping each column to its own expression via the upsert operation removes the positional coupling entirely, so commas in text fields are harmless.

---

## 26. Email Notify

- **Type:** `n8n-nodes-base.emailSend` (v2.1)
- **Role:** Send one HTML email per accepted job. This is the **terminal node of the sub-workflow** (the full success path). Its output is not wired anywhere — once the email is sent, this job's sub-execution completes and control returns to the main workflow's `Process One Job` node, which fetches the next job. No loopback (each job is its own sub-execution).

**Subject**

```text
=Job match {{ $('Combine Binaries').item.json.score }}: {{ $('Combine Binaries').item.json.title }} @ {{ $('Combine Binaries').item.json.company }}
```

**Body (HTML)**

```html
<h2>{{ title }} @ {{ company }}</h2>
<p><b>Score:</b> {{ score }} | <b>Source:</b> {{ source }} | <b>Location:</b> {{ location }}</p>
<p><b>Fit:</b> {{ fit_summary }}</p>
<p><a href="{{ url }}">View job</a> | <a href="{{ drive_folder.webViewLink }}">Drive folder</a></p>
```

**Credentials**

SMTP credential pointing to `smtp.gmail.com:465` with SSL on, or `:587` with SSL off (Gmail accepts both). Authentication uses a Gmail App Password — Google blocks regular passwords on SMTP for accounts with 2FA enabled.

---

## Cross-Cutting Concerns

### Error handling — per-job isolation via the sub-workflow

- Sources are individually wrapped in try/catch and emit `[]` on failure.
- The Code nodes that depend on upstream named-node references (`$('Foo').item.json`) will throw if the upstream node didn't execute. This is intentional — we want the job to fail rather than write a malformed row.
- HTTP nodes do not have automatic retry. If Anthropic or Gotenberg returns 5xx, that call throws — but the failure is now **contained to a single job** (see below).
- **Per-job isolation (the former "single node error aborts the whole run" gap is now FIXED).** Processing was moved out of a single shared `Loop Over Jobs` batch loop and into a dedicated **sub-workflow** (`Job Bot — Process One Job`, id `4nmCCacM8B8nfYwZ`). The main workflow's `Process One Job` Execute Workflow node runs it with `mode: each` (one sub-execution per job) and `onError: continueRegularOutput`. As a result, an unhandled error **anywhere** in a job's 26-node pipeline (e.g. a 5xx from Anthropic or Gotenberg) errors only **that job's sub-execution** — the parent Execute Workflow node skips it and continues with the remaining jobs, and the main run still finishes successfully. One bad job no longer kills the batch.
- **Verified with a forced-failure test.** A deliberately failing job's sub-execution errored while every other job completed normally and the main run succeeded — confirming the isolation boundary works as intended.

### Models

- **Scoring** (`Claude Score Fit`) uses `claude-haiku-4-5-20251001` — cheap, runs on every prefiltered job.
- **Tailoring** (`Claude Tailor Resume`, `Claude Cover Letter`) uses `claude-sonnet-5` — only runs on jobs that clear the score threshold, so the higher per-token cost is bounded.

### Idempotence

- Dedupe + Hash guarantees no two items with the same hash within a single run.
- Postgres unique constraint on `job_hash` plus `ON CONFLICT DO NOTHING` guarantees no duplicate rows across runs.
- Drive uploads are not deduped at the Drive level — re-running the same job (if dedupe were bypassed) would create a second folder. Don't bypass dedupe.

### Privacy

- Resume content stays on disk (`./resume/resume.html`) and is only sent to Anthropic's `messages` API. Job descriptions are sent to Anthropic. No other LLM provider receives any of your content.
- Drive uploads happen under your OAuth — files are private by default. If you want shareable links, change the sharing settings on the parent folder.

### Cost

- Adzuna: 1000 calls/month free, one call per day = well within free tier.
- Anthropic: roughly $0.01–0.05 per accepted job (depends on resume length). For 5 accepted jobs/day, expect under $10/month even at the high end.
- Google Drive / Sheets / Gmail: free tier.
- Gotenberg / Postgres / n8n: self-hosted, no external cost.

### Extending

If you want to add a source (e.g., We Work Remotely RSS, Wellfound), the right place is inside `Fetch All Sources`. Add another `tryFetch('newsource', ...)` entry that returns a list of `norm('newsource', { ... })` items. The rest of the pipeline picks them up automatically.

If you want to add a destination (e.g., Notion, Trello), branch off after `Build Sheet Row` rather than before — the row is the canonical record of an accepted job.
