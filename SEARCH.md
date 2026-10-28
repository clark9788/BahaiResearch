# Search Algorithm

Documents the full-text search pipeline in `LocalCorpusSearchService.java`, including AI handoff points and platform-specific behavior.

---

## Quick Reference — Core Behaviors

| Aspect | Behavior |
|---|---|
| Query tiers | NEAR → AND → OR (stop at first that returns results) |
| Phrase LIKE | **Always runs** — not gated by NEAR success (fixed 2026-08-03) |
| Phrase hit score | `-99,999` — guarantees first position in ranking |
| AI modes | `full` (default), `rerank-only`, `none` |
| AI author inference | Suppressed — UI dropdown only |
| AI work-title inference | Suppressed when author selected but title is "All Titles" |
| AI concept FTS | Concepts replace raw topic for NEAR/AND/OR when available (4+ tokens) |
| Reranker | Gemini receives top N×6 candidates; falls back to score order on failure |
| Semantic fallback | Concept-terms as OR query when main pipeline produces zero candidates |

---

## 1. End-to-End Runtime Flow

```
User clicks "Begin Research"
    │
    ▼
ResearchService.conductResearch(topic, selectedAuthor, selectedTitle)
    │
    ├─ Load config
    ├─ Bootstrap corpus (if needed)
    ├─ Run ingest (if configured)
    │
    ▼
LocalCorpusSearchService.search(topic, author, title, config)
    │
    ├─ A. Determine AI mode & resolve intent
    ├─ B. Build FTS queries (NEAR / AND / OR)
    ├─ C. Candidate retrieval from SQLite FTS5
    ├─ D. Phrase LIKE search (always runs)
    ├─ E. Post-retrieval filtering (author, book, content terms)
    ├─ F. Additional book-scoped hits (gated by !nearFired)
    ├─ G. Boilerplate removal + ranking
    ├─ H. Semantic fallback (if pool empty)
    ├─ I. AI rerank (except mode=none)
    │
    ▼
ResearchReport with QuoteResult list
```

---

## 2. AI Mode Gating

Three modes controlled by `research.aiMode`:

| Mode | Intent Resolver | Reranker | Behavior |
|---|---|---|---|
| `full` (default) | Runs | Runs | All AI features enabled |
| `rerank-only` | Skipped | Runs | Pure FTS query, AI only selects final results |
| `none` | Skipped | Skipped | Pure FTS + `rankForDisplay` — deterministic |

Intent resolution is also skipped when the topic produces ≤3 FTS tokens (short keyword queries don't need AI disambiguation) or when no API key is configured.

---

## 3. AI Interaction Points

### 3.1 Intent Resolution (`resolveLocalQueryIntent`)

One API call at the start of search. Input: topic + known work titles. Output JSON:
- `author` — **suppressed** (UI dropdown drives author filtering)
- `workTitle` — **suppressed** when author selected but title is "All Titles"
- `knownPhrase` — a known scriptural phrase the user appears to be quoting
- `concepts[]` — e.g. `["assisted suicide", "death with dignity", "euthanasia"]`

### 3.2 Concept-to-FTS Optimization

When AI returns concepts and they produce ≥2 FTS tokens, the concept text **replaces** the raw topic for building FTS queries. This improves NEAR precision — concepts like `["science","religion","harmony"]` produce much tighter proximity queries than raw sentence text like `"what does the bahai faith say about science and religion"`.

### 3.3 Candidate Reranking (`rerankLocalCandidates`)

One API call after ranking. Receives top `max(20, requestedQuotes × 6)` candidates. Returns `selectedIds[]`. If the API fails or returns empty, the pipeline falls back to top-N by score order.

The reranker prompt strips BM25 scores — Gemini sees only `ID / Author / Book / Locator / URL / Quote`. The phrase hit's `-99,999` score guarantees it appears first in the list Gemini reads, but does not force Gemini to select it.

---

## 4. Query Tiers — NEAR → AND → OR

### 4.1 NEAR (proximity, 2-token queries only)

Fires only when the FTS query produces **exactly 2 tokens**.

```
NEAR(token1* token2*, 15)
```

Both terms must appear within 15 words of each other. The tightest possible FTS match — for queries that explicitly connect two concepts (e.g. "prayer unity").

When NEAR fires, it **supplements** with AND results:
1. Run NEAR query
2. Run AND query separately
3. Boost NEAR hit scores via `applyNearBoost()`
4. Merge: NEAR hits first, AND fills in non-duplicates

This ensures tight proximity matches rank above looser AND matches while still providing a full candidate pool.

### 4.2 AND (all terms required)

- **1–3 tokens**: all required — `token1* AND token2* AND token3*`
- **4+ tokens**: first 3 required AND, remaining OR'd — `token1* AND token2* AND token3* AND (token4* OR token5*)`

### 4.3 OR Fallback

All tokens optional. Triggered only when AND returns nothing. Summary message includes a tip to try fewer keywords.

---

## 5. Phrase / LIKE Search

**Always runs** — independent of whether NEAR, AND, or OR fired. Two passes:

1. **Topic phrase** — `%keyword1%keyword2%...%` against `text_content`, using the raw query text with spaces converted to wildcards. Fires when the topic produces ≥2 significant FTS tokens.

2. **AI known-phrase** — Same LIKE pattern using a known scriptural phrase extracted by Gemini. Supports multi-word exact-quote lookups (e.g. a famous passage the user is quoting verbatim).

Phrase hits receive a fixed score of `-99,999` — they always sort first in `rankForDisplay`, ahead of all BM25-scored FTS results. Among multiple phrase hits, shorter passages rank above longer ones (a short passage where the query covers most of the text is more precise).

Phrase hits are merged into the candidate list **before** FTS hits — deduplication preserves the phrase score when the same passage appears in both.

### Why phrase LIKE always runs (2026-08-03 fix)

Previously, phrase LIKE was gated by `!nearFired` — if NEAR returned results, phrase LIKE was skipped entirely. This meant exact quotes retrieved by NEAR only had a BM25 score, and the Gemini reranker could drop them below the display threshold. The fix removes the gate so phrase LIKE always assigns `-99,999` to exact matches, guaranteeing they appear in the candidate pool and rank first.

---

## 6. Author and Title Filtering

- **Author** — `lower(d.author) = lower(?)` exact match in SQL WHERE clause. Canonical values: `Baha'u'llah`, `Bab`, `'Abdu'l-Baha`, `Shoghi Effendi`, `Universal House of Justice`, `Compilation`. Author tokens are excluded from FTS queries (handled by SQL WHERE instead). Author is resolved from: typed author names in the query text (`inferRequiredAuthor`), or the explicit UI dropdown. **AI-inferred author is suppressed** — prevents "All Authors" queries from being falsely restricted to one author based on topic themes.

- **Title** — `lower(d.title) = lower(?)` exact match in SQL WHERE clause. Populated from DB dynamically when an author is selected — only shows titles that author has in the corpus. Title filtering comes from three sources merged together: manual `"from X"` / `"in book X"` patterns in the query, the explicit Title dropdown, and AI work-title inference (only when no author is selected AND a manual book pattern is already present — pure AI title inference is suppressed).

- **AI author/title suppression**: When the user selects an author but leaves Title as "All Titles", AI work-title inference is suppressed — prevents queries like "unity" from being artificially restricted to "Tabernacle of Unity".

---

## 7. Book Token Filtering

After SQL retrieval, passages are filtered by `filterByRequestedBook`:
- Passage title and URL must contain required book tokens
- 1–2 tokens: all must match
- 3+ tokens: ≥2 must match
- Filtering applies both to FTS hits and phrase hits

---

## 8. Content Term Filtering

Post-FTS filter: `filterByContentTerms` checks that passage text contains at least one significant topic word (≥4 chars, non-noise) as an exact substring. AI-extracted concept terms are merged in to catch synonym matches. The check is lenient — `token.startsWith(term)` — so inflected forms pass.

Applied to FTS hits **before** phrase merge (phrase hits bypass this filter since LIKE already guarantees the text contains the query words).

---

## 9. Additional Book-Scoped Hits

When a Title filter is active and the candidate count after filtering/merge is still below `requestedQuotes`, `findAdditionalBookScopedHits` runs a broader SQL scan of all passages in the target book/author scope. It applies book-token and content-term filters directly against the raw passage text.

**Retains the `!nearFired` gate** (line 197): when NEAR already returned tight proximity results, supplementing with unfiltered book passages would dilute precision. This is a pool-size concern, not a scoring concern — intentionally left gated.

---

## 10. Ranking (`rankForDisplay`)

Sort order before the final `requestedQuotes` limit:

1. **Phrase hits** (score ≤ −99,990) — always first. Sorted among themselves by passage length ascending (shortest = most precise match).

2. **Source priority** — For Universal House of Justice queries, official Messages rank above compilations. Compilations and secondary sources are deprioritized into separate buckets.

3. **Quality band** — Medium-length passages preferred:
   - Band 0: ~200–900 chars (best)
   - Band 1: ~120–1,100 chars (acceptable)
   - Band 2: very short or very long (last resort)

4. **BM25 score** — Within the same band, lower (more negative) BM25 = better relevance.

---

## 11. Boilerplate Filter

Passages removed before ranking (checked in `removeBoilerplateAndDuplicates`):

| Filter | Pattern |
|---|---|
| `too-long` | Over 15,000 characters (entire-book ingest accident) |
| `bahai-ref-lib` | Contains "bahai reference library" (site header) |
| `collection-header` | Starts with "a collection of" or "a selection of" |
| `found-here` | Contains "can be found here" (navigation link) |
| `nav-element` | Navigation/download/copyright UI text, "read online", "bahai org home", "copyright and terms of use" |
| `see-also` | Contains "see also" |

---

## 12. Semantic Fallback

Triggered when `candidatePool` is empty after the full pipeline. Covers two scenarios:
- FTS finds nothing (e.g. modern words like "empathy" not in scripture)
- FTS found hits but all were eliminated by content/book filters

Fallback behavior:
- AI-extracted concept terms (e.g. "love", "compassion", "unity") used as **OR** FTS query
- Uses OR (not AND) — AND concept queries typically return only 1–2 narrow passages that then get boilerplate-filtered, leaving the pool empty again
- Does **not** apply `filterByContentTerms` — exact-token filtering causes false negatives when inflected forms match FTS but fail exact-word comparison
- Book tokens from the main pipeline are **not** carried forward
- Respects the explicit Title dropdown SQL constraint

---

## 13. SQLite Details

- FTS5 with `unicode61` tokenizer (default, no Porter stemming)
- Tokens get wildcard suffix (`*`) for prefix matching
- Noise tokens excluded from FTS: `by`, `for`, `with`, `and`, `the`, `from`, `or`, `not`, `has`, `had`, `can`, `all`, `are`, `was`, `were`, `will`, `have`, `been`, `its`, `that`, `this`, `into`, `such`, `than`, `upon`, `shall`, `unto`
- Generic query tokens excluded: `what`, `does`, `say`, `about`, `said`, `says`, `like`, `how`, `why`, `who`, `when`, `where`, `which`, `these`, `those`, `there`, `their`, `they`, `them`, `would`, `could`, `should`, `other`, `some`, `many`, `more`, `most`, `much`, `very`, `also`, `only`, `just`, `then`, `now`, `here`, `still`, `well`, `even`, `over`, `each`, `every`, `between`, `through`, `under`, `above`, `below`, `after`, `before`, `during`
- SQLite busy/lock errors trigger up to 3 retries (200ms × attempt)

---

## 14. Platform Differences

| Aspect | Desktop | Android |
|---|---|---|
| AI modes | `full` / `rerank-only` / `none` | N/A (no AI) |
| Intent resolver | Yes | No |
| Reranker | Gemini | No — `rankForDisplay` is final |
| Known-phrase LIKE | Yes (AI-detected) | N/A |
| `!nearFired` removal | Lines 177, 184 | Line 83 (topic gate only) |
| `SearchCore` | Shared via `BahaiSearchCommon` | Same shared module |

---

## 15. Debug Logging

Set `research.debugIntent=true` to enable:

| Log prefix | Content |
|---|---|
| `[IntentDebug]` | Topic, FTS query, AI intent fields (author, workTitle, knownPhrase, concepts), resolved constraints |
| `[PipelineCount]` | Hit counts at each stage: NEAR, AND supplement, AND, OR, phrase topic, phrase AI, after merge, candidatePool (main), semantic fallback, post-rerank |
| `[BoilerplateFilter]` | Each removed passage with reason + 120-character snippet |

---

## Revision History

| Date | Changes |
|---|---|
| 2026-08-04 | Combined `SEARCH.md`, `Search_flow.md`, and `planSearchAdjust.md` into single comprehensive document. Documented `!nearFired` removal (lines 177/184), NEAR+AND supplement merge, AI concept-to-FTS optimization, AI mode gating, and AI author/title suppression rules. |
| 2026-08-03 | `!nearFired` gate removed from topic phrase (line 177) and known-phrase (line 184) conditions — phrase LIKE now always runs. Third gate at line 197 (book-scoped supplement) intentionally retained. |