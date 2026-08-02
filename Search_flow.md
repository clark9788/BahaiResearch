# Search Flow (Current Build)

This document describes the **actual runtime flow** of the app based on current code in:

- `ResearchService`
- `LocalCorpusSearchService`
- `GeminiClient`
- `ConfigLoader`

---

## 1) End-to-end runtime flow after clicking **Begin Research**

### UI entrypoint

1. `BahaiResearch.runResearch(...)` starts a background task.
2. It calls `ResearchService.conductResearch(topic, selectedAuthor, selectedTitle)`.

### Service orchestration (`ResearchService`)

1. Load config with `ConfigLoader.load()` (from `KEY_PATH`).
2. Initialize corpus dirs/schema with `CorpusBootstrapService.initializeIfEnabled(...)`.
3. Run ingest if configured via `CorpusIngestService.ingestIfConfigured(...)`.
   - Reingest occurs here when `corpus.forceReingest=true`.
4. Run local retrieval first:
   - `LocalCorpusSearchService.search(topic, selectedAuthor, selectedTitle, appConfig)`
5. If local returns quotes → return local report.
   - If local returns no quotes → return configured `research.noResultsText`.

---

## 2) Local search pipeline (always first)

Inside `LocalCorpusSearchService.search(...)`, the flow is:

### A. Resolve query constraints

- Inputs considered:
  - Raw topic text
  - Optional explicit UI dropdown filters (`selectedAuthor`, `selectedTitle`)
  - AI intent hints from `GeminiClient.resolveLocalQueryIntent(...)`

- Effective constraints assembled:
  - `requiredAuthor` — priority order: explicit UI dropdown > typed author inferred from topic text.
    **AI-inferred author is suppressed entirely.** Without a UI selection or typed author name, the
    AI could falsely restrict "All Authors" queries to one author based on topic themes.
  - `requestedBookTokens` — derived from manual "from X" / "in book X" patterns in the topic text,
    supplemented by the Title dropdown when selected. **AI work-title inference is also suppressed**
    when an author is selected but no title is chosen — prevents queries like "unity" from being
    artificially restricted to "Tabernacle of Unity" across all of that author's works.
  - `conceptTerms` — topic terms merged with AI-extracted concepts (used for content filtering and
    semantic fallback).

- Key suppression rules:
  - When no "from X" / "in book X" pattern is present in the topic, `requestedBookTokens` is empty
    — AI work-title guessing does **not** activate.
  - When user selects an author but leaves Title as "All Titles", AI work-title inference is off.

### B. Build FTS queries

- AND-style query: `toFtsQuery(...)` — for precision
  - 1–3 terms: all required (`term1* AND term2* AND term3*`)
  - 4+ terms: first 3 required AND, remaining terms joined OR
- OR-style query: `toFtsQueryOr(...)` — fallback when AND returns nothing
- Tokens are normalized; noise tokens (`by`, `for`, `with`, `and`, `the`, `from`, etc.) and
  resolved author tokens are excluded from FTS (author handled by SQL WHERE clause instead).
- Each token gets a wildcard suffix (`*`) for prefix matching.

### C. Candidate retrieval from SQLite

- Main query via FTS5 (`passages_fts MATCH ?`) joined with `passages` + `documents`.
- Optional exact SQL filters: `lower(d.author) = lower(?)` and `lower(d.title) = lower(?)` when
  author/title are scoped.
- If AND query yields no rows, OR query is attempted automatically.
- SQLite busy/lock errors trigger up to 3 retries (200ms × attempt between retries).

### D. Phrase search (runs independently of FTS)

A separate SQL LIKE query is executed in parallel with the FTS pipeline:

- **Topic phrase search**: When the topic contains 2+ significant words, a `LIKE` query scans
  `text_content` for the full topic string (spaces converted to wildcards). This catches exact
  quotations where FTS tokenization might miss multi-word phrases.
- **AI-detected known phrase**: If `resolveLocalQueryIntent` identifies a `knownPhrase` (e.g., a
  famous quote the user is looking for), a second LIKE query runs for that phrase.
- Phrase hits receive a fixed score of `−99,999` so they **always rank first** in the final sort,
  ahead of all FTS-scored results.
- Among multiple phrase hits, shorter passages are preferred — a short passage where the query
  covers most of the text is a more precise match than a long passage that incidentally contains
  the same words.
- Phrase hits are merged into the candidate list **before** FTS hits, so deduplication preserves
  the phrase score rather than the FTS score when the same passage appears in both.

### E. Post-retrieval filtering

Applied to the FTS hits (before phrase merge):

1. **Author filter** — exact canonical author match (case-insensitive normalized comparison)
2. **Book-token filter** — passage title and URL must contain the required book tokens
   (requires matching all tokens for 1–2 tokens; ≥2 matches for 3+ tokens)
3. **Content-term filter** — passage must contain at least one content term from the merged
   topic + AI concept terms
4. **Phrase merge** — phrase hits prepended; FTS hits fill in non-duplicates after

### F. Book-scoped supplement

If `requestedBookTokens` is non-empty and the candidate count is still below `requestedQuotes`
after filtering, `findAdditionalBookScopedHits(...)` runs a broader SQL scan of all passages in
the target book/author scope, applying book and content-term filters directly. This supplements
the candidate pool when FTS misses passages that are topically relevant but use unusual vocabulary.

### G. Boilerplate removal and ranking

- **Boilerplate removal**: passages are filtered out if they match any of these patterns:
  - `too-long`: over 15,000 characters (entire-book ingest accidents)
  - `bahai-ref-lib`: contains "bahai reference library"
  - `collection-header`: starts with "a collection of" or "a selection of"
  - `found-here`: contains "can be found here"
  - `nav-element`: navigation/download/copyright UI text
  - `see-also`: contains "see also" (checked separately for easier diagnosis)
- **Ranking** (`rankForDisplay`):
  1. **Phrase hits first** — score ≤ −99,990 always sort before all FTS results; shorter
     phrase hits rank above longer ones
  2. **Source priority** — UHJ direct messages ranked highest for UHJ queries; compilations
     and secondary buckets deprioritized
  3. **Quality band** — medium-length passages (~200–900 chars) are band 0 (preferred);
     near-range (~120–1100 chars) is band 1; very short/very long is band 2
  4. **BM25 score** — SQLite FTS relevance score breaks ties within the same band

### H. Semantic fallback (local still)

Triggered when `candidatePool` is empty after the full pipeline above. Two scenarios this covers:

- Raw-text FTS finds nothing — e.g., query uses modern words like "empathy" not in scripture
- OR FTS found hits but all were eliminated by content/book filters

Fallback behavior:
- AI-extracted concept terms (e.g., "love", "compassion", "unity") are used as FTS terms
  instead of the raw topic text
- Uses an **OR** concept query directly — not AND — because AND concept queries (e.g.,
  `love* AND empathy* AND unity*`) typically return only 1–2 narrow passages that then get
  boilerplate-filtered, leaving the pool empty again. OR retrieves a broad thematic pool for
  the Gemini reranker to select from.
- Does **not** apply `filterByContentTerms` — FTS prefix matching already ensures topical
  relevance, and exact-token filtering causes false negatives when inflected forms (`"beloved"`,
  `"loveth"`) matched FTS but fail exact-word comparison
- Book tokens from the main pipeline are **not** carried forward — if AI guessed a wrong title
  it should not persist into the fallback
- Respects the explicit Title dropdown SQL constraint

### I. AI rerank of local candidates

- `GeminiClient.rerankLocalCandidates(...)` receives up to `max(20, requestedQuotes × 6)`
  candidates and returns `selectedIds[]`.
- If reranker returns fewer than `requestedQuotes` selections, the pool fills in the rest in
  ranked order.
- Final quotes still come from local DB rows (`author/title/locator/url/text` from corpus).

---

## 3) AI handoff points in local-first mode

There are two AI calls during local retrieval:

1. **Intent resolution**: `resolveLocalQueryIntent(...)`
   - Input: topic + known work titles (loaded from DB)
   - Output JSON: `author`, `workTitle`, `knownPhrase`, `concepts[]`
   - Note: `author` and `workTitle` from this output are **conditionally suppressed** (see
     constraint resolution above) — the app uses them only when there is no UI-selected author
     or when the topic explicitly references a book title.

2. **Candidate rerank**: `rerankLocalCandidates(...)`
   - Input: topic + local candidate list (bounded pool)
   - Output JSON: `selectedIds[]`

So AI helps with interpretation/ranking, but citations are local unless full fallback is triggered.

---

## 4) Practical implications

- Local-only behavior is always active — there is no web search fallback.
- For deterministic/auditable results, the local corpus is the sole source of citations.
- All citations returned in local mode come directly from the local SQLite corpus — no AI
  synthesis of text. The AI only selects which passages to surface and how to order them.

---

## 5) Debugging aids

Set `research.debugIntent=true` to see:

- `[IntentDebug]` — topic, ftsQuery, full AI intent fields, resolved constraints
- `[PipelineCount]` — stage-by-stage candidate counts including FTS AND/OR results,
  phrase search hits, book-scoped supplement, semantic fallback counts
- `[BoilerplateFilter]` — each removed passage with reason and 120-character snippet

This is the fastest way to understand why a query returned specific quotes or no results.
