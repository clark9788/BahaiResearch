# AI Search Pipeline Cleanup — Implementation Plan

Based on [AISearchEval2.md](AISearchEval2.md) and code review of the four critical files:
- `src/main/java/com/bahairesearch/ai/GeminiClient.java`
- `src/main/java/com/bahairesearch/corpus/LocalCorpusSearchService.java`
- `src/main/java/com/bahairesearch/research/ResearchService.java`
- `src/main/java/com/bahairesearch/config/ConfigLoader.java`

This plan is phased so each phase can be implemented and tested independently.

---

## Phase 1 — Remove Dead External-Source Code (Clean, low-risk)

The simplest, most defensible change. Eliminates config/surface area that could cause confusion during later phases.

### Files Touched

**`ResearchService.java`** — Remove the `localOnlyMode` branch (lines 42-47). Always return `localReport`:

```diff
- if (!localReport.quotes().isEmpty() || appConfig.localOnlyMode()) {
-     return localReport;
- }
- GeminiClient geminiClient = new GeminiClient(appConfig);
- return geminiClient.generateReport(topic.trim(), appConfig);
+ return localReport;
```

**`GeminiClient.java`** — Remove the following methods:
- `generateReport()` (line 56-69)
- `parseReport()` (line 204-252)
- `buildPrompt()` (line 254-293)
- `enforceRequestedAuthor()` (line 362-377)
- `inferRequiredAuthor()` (line 379-395, the private Gemini one — note: `LocalCorpusSearchService` has its own `inferRequiredAuthor` at line 576 that must NOT be removed)

**`ConfigLoader.java`** — Remove or deprecate these config keys:
- `localOnlyMode` — becomes always-true; remove the key or keep as a no-op with a comment
- `requiredSite` — was only used in `buildPrompt()`
- `promptBoilerplate` — was only used in `buildPrompt()`
- `noResultsText` for AI fallback — note that `noResultsText` is still used in `LocalCorpusSearchService` for the local search path, so keep the config key but remove references in dead Gemini code

### What to Test
- Build compiles without errors
- A search returns local corpus results exactly as before
- The `geminiClient.generateReport()` path no longer exists
- Config file without `requiredSite`/`promptBoilerplate` still loads

---

## Phase 2 — Enable Structured Output in `generateText()` (Reliability)

The Gemini API supports `response_mime_type: "application/json"` which eliminates the `stripMarkdownCodeFence()` heuristic entirely. All three AI touchpoints (`resolveLocalQueryIntent`, `rerankLocalCandidates`, and previously `generateReport`) parse JSON from Gemini responses — structured output mode guarantees clean JSON.

### File
`GeminiClient.java` — `generateText()` method (~line 142-202)

### Change

Add `response_mime_type` to the request body root object:

```java
private String generateText(String prompt, AppConfig appConfig) {
    var root = objectMapper.createObjectNode();
    root.putArray("contents")
        .addObject()
        .put("role", "user")
        .putArray("parts")
        .addObject()
        .put("text", prompt);
    root.put("response_mime_type", "application/json");  // NEW
    // ... rest unchanged
}
```

Then **remove** `stripMarkdownCodeFence()` calls:
- `resolveLocalQueryIntent()` line 82: remove `String cleaned = stripMarkdownCodeFence(raw);` → parse `raw` directly
- `rerankLocalCandidates()` line 122: same removal

The `stripMarkdownCodeFence()` method itself can be removed in Phase 6 after confirming structured output works reliably.

### What to Test
- Run several searches with `research.debugIntent=true`
- Verify intent JSON and reranker JSON parse correctly
- Confirm the API no longer wraps responses in markdown fences
- Edge case: empty/bad prompt should still fail gracefully (existing try/catch)

### Notes
- `gemini-flash-latest` supports `response_mime_type: "application/json"` at no additional cost
- This is a single field in the request body
- Backward-compatible: the API returns `200` with `application/json` Content-Type

---

## Phase 3 — Gate Intent Resolver Behind Token Count (Performance/Cost)

Both evals note the intent resolver fires unconditionally on every search, including short 3-keyword queries where the user has already selected optimal tokens. A simple gate skips the API call when it adds no value.

### File
`LocalCorpusSearchService.java` — `search()` method (~lines 73-76)

### Current Code (lines 73-76)
```java
List<String> knownWorkTitles = loadKnownWorkTitles(corpusPaths);
GeminiClient geminiClient = new GeminiClient(appConfig);
GeminiClient.LocalQueryIntent intent =
    geminiClient.resolveLocalQueryIntent(topic, knownWorkTitles, appConfig);
```

### Change
```java
// Extract FTS tokens first to decide whether AI intent resolution is worthwhile
List<String> topicFtsTokens = SearchCore.extractFtsTokens(topic, manualRequiredAuthor);
boolean skipAiIntent = topicFtsTokens.size() <= 3 || appConfig.geminiApiKey().isBlank();

GeminiClient geminiClient = new GeminiClient(appConfig);
GeminiClient.LocalQueryIntent intent;

if (skipAiIntent) {
    // For short/none keyword queries, the user has already done the work
    // of selecting optimal tokens. Skip the API call entirely.
    intent = new GeminiClient.LocalQueryIntent("", "", "", List.of());
    logCount(appConfig, "AI intent skipped (tokens=" + topicFtsTokens.size() + ")", 0);
} else {
    List<String> knownWorkTitles = loadKnownWorkTitles(corpusPaths);
    intent = geminiClient.resolveLocalQueryIntent(topic, knownWorkTitles, appConfig);
}
```

Move `knownWorkTitles` loading inside the `else` block so it's also skipped when AI is not needed. This avoids an unnecessary database call.

### What to Test
- 3-keyword query (e.g., "obligatory prayer fasting") → no Gemini API call for intent resolution, no `loadKnownWorkTitles` DB query
- Long sentence query (e.g., "What does the Bahá'í Faith teach about the role of consultation in community decision-making?") → intent resolver fires normally
- Reranker still fires regardless (gated separately on candidate pool size)
- Verify via debug logging: `[PipelineCount] AI intent skipped (tokens=3)=0`

---

## Phase 4 — Feed AI Concepts into NEAR/AND Query Building (Core Improvement)

This is the highest-leverage change. When the user types a long sentence and the AI extracts 2-3 semantic concepts, use *those* concepts as the FTS tokens instead of the raw sentence's first-3-positional tokens.

### Problem
Currently, a sentence like *"What does the Bahá'í Faith say about the relationship between science and religion?"* generates a NEAR query of `NEAR(what does the, 5)` — which is useless because "what", "does", "the" are all noise tokens and 3 tokens never triggers NEAR anyway (NEAR requires 2-3 meaningful tokens). The AND fallback uses `universal* AND house* AND justice* ...` because positional first-3 includes author tokens.

### Solution
Use AI-extracted concepts like `["science", "religion", "harmony"]` to build the FTS query, producing `NEAR(science religion harmony, 5)` — dramatically better precision.

### File
`LocalCorpusSearchService.java` — `search()` method (~lines 66-68)

### Current Code (lines 66-68)
```java
String nearQuery = SearchCore.toFtsQueryNear(topic, manualRequiredAuthor);
String ftsQuery = SearchCore.toFtsQuery(topic, manualRequiredAuthor);
String orFtsQuery = SearchCore.toFtsQueryOr(topic, manualRequiredAuthor);
```

### Change
```java
// Build FTS queries from either the raw topic or AI-inferred concepts
String queryForFts = topic;
if (!skipAiIntent && intent.concepts() != null && !intent.concepts().isEmpty()) {
    String conceptText = String.join(" ", intent.concepts());
    // Only use AI concepts if they produce at least 2 FTS tokens
    // (single-token concepts would bypass NEAR entirely)
    List<String> conceptTokens = SearchCore.extractFtsTokens(conceptText, manualRequiredAuthor);
    if (conceptTokens.size() >= 2) {
        queryForFts = conceptText;
        logCount(appConfig, "Using AI concepts for FTS query: " + conceptText, 0);
    }
}
String nearQuery = SearchCore.toFtsQueryNear(queryForFts, manualRequiredAuthor);
String ftsQuery = SearchCore.toFtsQuery(queryForFts, manualRequiredAuthor);
String orFtsQuery = SearchCore.toFtsQueryOr(queryForFts, manualRequiredAuthor);
```

### What to Test

**Good case — sentence input:**
- Query: *"What does the Bahá'í Faith say about the relationship between science and religion?"*
- AI concepts: `["science", "religion", "harmony"]`
- NEAR query becomes: `NEAR(science religion harmony, 5)` — fires correctly
- AND query becomes: `science* AND religion* AND harmony*`
- Result: significantly more relevant passages than the original positional approach

**Regression case — short keywords:**
- Query: `"obligatory prayer fasting"`
- Phase 3 gate: `topicFtsTokens.size()` = 3 → `skipAiIntent = true`
- FTS uses raw tokens as before — no behavior change

**Edge case — AI returns single concept:**
- AI concepts: `["unity"]`
- `conceptTokens.size()` = 1 → falls back to raw topic tokens
- Avoids degrading NEAR (which requires 2+ tokens)

---

## Phase 4b — Distinguish Empty Concepts from API Errors (Observability) ✅ DONE

When the intent resolver returns empty concepts it's ambiguous: did the model genuinely find nothing (correct), or did the API fail silently (bug)? This adds debug logging to distinguish the two cases.

### Files
- `GeminiClient.java` — `resolveLocalQueryIntent()` catch block
- `LocalCorpusSearchService.java` — after intent resolver runs

### Changes

**`GeminiClient.java`:**
- Added `LOGGER` instance
- In the `catch` block: logs API error when `-Dresearch.debugIntent=true` is set

**`LocalCorpusSearchService.java`:**
- After `resolveLocalQueryIntent()` returns (non-skip path): logs `"AI intent ran — returned empty concepts"` when `aiConcepts` is empty

### Commit
`f6e1cec` — Phase 4b: Add debug logging for empty/errored intent resolver calls

---

## Phase 5 — Add A/B Testing Mode Toggle (Verification)

Add a runtime config flag to compare search modes without rebuilding. This enables the 10-query A/B verification strategy described in `AISearchEval2.md`.

### File
`LocalCorpusSearchService.java` and `ConfigLoader.java`

### Approach

**`ConfigLoader.java`** — Add a new config key:

```java
// research.aiMode values:
//   "full"         — current behavior (intent + concepts as filter + reranker)
//   "none"         — skip all AI (no intent resolver, no reranker)
//   "rerank-only"  — skip intent resolver, keep reranker
//   "concept-fts"  — full AI with concepts feeding FTS query (Phase 4 behavior)
// Default: "full"
public String aiMode() {
    return getString("research.aiMode", "full");
}
```

**`LocalCorpusSearchService.java`** — Add mode gating after the intent/query section:

```java
// --- AI mode gating ---
String aiMode = appConfig.aiMode().toLowerCase(Locale.ROOT);

if ("none".equals(aiMode)) {
    // Skip reranker too — return raw BM25-ranked results
    return buildReport(topic, candidatePool, requestedQuotes, appConfig, hitsResult);
}

GeminiClient geminiClientRerank = new GeminiClient(appConfig);
if ("rerank-only".equals(aiMode)) {
    // Skip intent resolver entirely for rerank-only mode
    // (already handled by Phase 3 gate, but explicit for clarity)
}
// ... rest of reranker pipeline
```

### What to Test
- Set `research.aiMode=none` → no Gemini API calls at all, pure FTS results
- Set `research.aiMode=rerank-only` → no intent resolver call, reranker still fires
- Set `research.aiMode=concept-fts` → intent fires, concepts feed FTS queries
- Same search in each mode, compare results side by side
- Run the 10-query A/B test suite described below
- With `research.debugIntent=true`, GeminiClient logs "Gemini API: calling intent resolver" / "Gemini API: calling reranker" before each API call

### A/B Test Suite (from AISearchEval2.md, Section 8)

1. Select 10 long-form queries (full sentences that currently produce poor results)
2. Run each three ways:
   - (A) `aiMode=full` — current behavior
   - (B) `aiMode=none` — pure FTS, no AI
   - (C) `aiMode=concept-fts` — AI concepts drive NEAR/AND queries
3. Compare: result count, relevance of top 3 passages, whether the most relevant passage appears
4. Also measure: number of Gemini API calls per search in each mode

---

## Phase 6 — Cleanup & Polish

After Phases 1-5 are confirmed working:

1. **Remove `stripMarkdownCodeFence()`** from `GeminiClient.java` — no longer needed after Phase 2
2. **Audit `ConfigLoader.java`** — remove any remaining references to dead config keys (`requiredSite`, `promptBoilerplate`, `localOnlyMode`)
3. **Update `AISearchEval.md`** or add a changelog/commit message documenting what changed and why
4. **Remove unused imports** — `GeminiClient` import in `ResearchService.java` if no longer used after Phase 1

---

## Implementation Order Summary

| Order | Phase | Risk | Reward |
|-------|-------|------|--------|
| 1 | Phase 1 — Remove dead external-source code | Very low | Cleaner codebase |
| 2 | Phase 2 — Structured output | Low | Eliminates JSON parse failure class |
| 3 | Phase 3 — Token-count gate | Low | Fewer API calls, no regression |
| 4 | Phase 4 — AI concepts → FTS | Medium | **Highest user-facing improvement** |
| 5 | Phase 5 — A/B mode toggle | Low | Enables data-driven validation |
| 6 | Phase 6 — Cleanup | Very low | Polish |

### Suggested Grouping for PRs

- **PR 1:** Phases 1 + 2 + 3 (cleanup + reliability + gating — low risk, no behavior change to search results)
- **PR 2:** Phase 4 (AI concepts → FTS — changes search behavior, deserves its own review)
- **PR 3:** Phase 5 (A/B toggle — enables testing PR 2 against original)
- **PR 4:** Phase 6 (final cleanup)

---

## Testing Strategy for Windows vs. Linux Comparison

Since you have:
- The original app running on Windows
- This GitHub repo representing the codebase before changes

1. Make the changes in this repo
2. Build and run on Linux (current environment)
3. Run the same 10 long-form queries on both:
   - Windows original app
   - Linux modified build (with `aiMode=full` first to confirm parity, then `aiMode=concept-fts`)
4. Track per-query:
   - Number of results returned
   - Relevance of top 3 passages (subjective 1-5 rating)
   - Number of Gemini API calls
   - Whether the most relevant passage appears in results at all
5. Iterate on Phase 4 if needed based on A/B results
   - __`research.aiMode=none`__ — verify pure BM25 returns results with zero Gemini calls (check network or debug logs)
   - __`research.aiMode=rerank-only`__ — intent resolver skipped, reranker still fires
   - __`research.aiMode=full`__ (default, or omit) — should match pre-Phase-5 behavior exactly


---

## Critical Files Reference

- `src/main/java/com/bahairesearch/ai/GeminiClient.java` — all AI touchpoints (intent resolver, reranker, text generation)
- `src/main/java/com/bahairesearch/corpus/LocalCorpusSearchService.java` — orchestration; FTS query building at `:66-68`, phrase search at `:141-148`, semantic fallback at `:171-191`, reranker at `:767-818`
- `src/main/java/com/bahairesearch/research/ResearchService.java` — top-level orchestration; `localOnlyMode` branch at `:42-47`
- `src/main/java/com/bahairesearch/config/ConfigLoader.java` — defaults and config key definitions