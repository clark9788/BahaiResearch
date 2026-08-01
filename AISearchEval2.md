# Second Opinion: AI Search Handoffs & External-Source Path

## Scope

This is an independent review of the AI usage in the BahaiResearch search pipeline, written as a second opinion on `AISearchEval.md`. I have read all the same source files and reached the same two core conclusions — but with different emphasis on several points, a few additional observations, and one additional recommendation.

---

## Core Agreement

I concur with both foundational findings from the original evaluation:

1. **The AI's `concepts` do not drive FTS retrieval.** The FTS query (NEAR/AND/OR) is built from the raw topic sentence at `LocalCorpusSearchService.java:66-68`. The AI's intent resolution (`resolveLocalQueryIntent`) feeds into post-retrieval filtering (`filterByContentTerms`, `:127`) and a semantic fallback that only activates when the primary pipeline produces zero candidates (`:171-191`). The NEAR path — arguably the most precision-oriented retrieval mode — caps at 2–3 tokens (`SearchCore.java:59`), which means a full sentence never triggers it. The observation that "your manual 3-keyword searches beat sentence input" is explained by exactly this: you hand-select the 3 tokens that make NEAR fire.

2. **The external-source path is dead code.** With the default `localOnlyMode=true` (`ConfigLoader.java:42`), the branch at `ResearchService.java:42-47` that calls `geminiClient.generateReport()` is unreachable. Even if reached, no actual HTTP fetch to oceanlibrary.com occurs — it is only a prose instruction in the Gemini prompt (`GeminiClient.java:262`), and `generateContent` without grounding tools cannot browse the web. The `generateReport` path would produce unverifiable, model-weight-based responses dressed as "citations."

---

## Where I Add Nuance

### 1. The reranker is more valuable than "modest polish"

The original eval calls the reranker's contribution "modest, inconsistent value" and says it "can only reorder/select from whatever the retrieval produced." That is technically true, but understates the actual gap between BM25 ranking and what the reranker provides.

BM25 is a bag-of-words scorer. For Bahá'í research queries that touch on theological nuance ("the relationship between free will and divine decree," "the role of consultation in community decision-making"), BM25 has no mechanism to distinguish between a passage that coincidentally contains the right words and one that actually *addresses* the intent. The reranker prompt (`buildCandidateRerankPrompt`, `GeminiClient.java:323`) asks Gemini to evaluate across author attribution, work relevance, and semantic fit to the query — three dimensions BM25 cannot access. With a candidate pool of 60–120 passages (`retrievalPoolSize = max(quotes * 12, 60)`), the difference between the #1 BM25 result and a Gemini-selected #1 result can be the difference between a superficial keyword match and a theologically relevant passage.

This doesn't change the verdict on whether AI is "necessary," but it does mean the reranker is the most *defensible* piece of the AI pipeline — and the one I'd keep even if the intent resolver were removed.

### 2. The `knownPhrase` field is a real retrieval contribution (overlooked)

The original eval states the AI's "main contribution (search words) is disconnected from retrieval." But the `knownPhrase` field from `resolveLocalQueryIntent` (`GeminiClient.java:87`) *does* drive actual database retrieval:

```java
// LocalCorpusSearchService.java:141-148
if (intent.knownPhrase() != null && !intent.knownPhrase().isBlank() && !nearFired) {
    List<CorpusSearchHit> aiPhraseHits = fetchPhraseHits(
        corpusPaths, intent.knownPhrase(), retrievalPoolSize,
        requiredAuthor, explicitTitle, requestedBookTokens);
    combinedPhraseHits = SearchCore.mergeHits(combinedPhraseHits, aiPhraseHits);
}
```

This runs a `LIKE '%normalizedPhrase%'` SQL query against the passages table (`buildPhraseSql`, `LocalCorpusSearchService.java:261-278`) and merges the results ahead of the FTS results (`topical = SearchCore.mergeHits(combinedPhraseHits, topical)` at `:151`). Phrase hits are ranked first in display order because `rankForDisplay` prioritizes the sentinel `-99999.0` score tier.

This is a genuine retrieval pathway driven by AI output — it activates for queries like "The earth is but one country" where the user is quoting a known passage. It's a narrow use case (only fires when NEAR didn't fire and the phrase is non-empty), but it's a real one, and it's worth acknowledging in any assessment of the AI's retrieval role.

### 3. The semantic fallback is the only place AI concepts build FTS queries

The semantic fallback at `LocalCorpusSearchService.java:171-191` deserves more emphasis. When the *entire* pipeline (NEAR, AND, OR, phrase LIKE, book-scoped retrieval) yields zero candidates, the AI's `intent.concepts()` are fed into `toFtsQueryOr()`:

```java
String conceptQuery = String.join(" ", intent.concepts());
String conceptOrFtsQuery = SearchCore.toFtsQueryOr(conceptQuery, requiredAuthor);
```

This is the *sole* code path where AI-generated terms become an FTS query. It's a last resort, not a primary strategy, and it's gated on an empty candidate pool. But it's architecturally significant — it proves that the pattern of "AI concepts → FTS query" already works in one place and could be promoted to the primary retrieval path.

### 4. The lack of structured-output mode is more than a "minor robustness note"

The original eval notes that `generateText` uses plain `generateContent` "no structured-output/JSON mode." I'd elevate this to a **medium concern**. All three AI touchpoints parse JSON from the response text, and all three rely on `stripMarkdownCodeFence()` (`GeminiClient.java:397`) to remove markdown wrappers Gemini may hallucinate:

```java
private String stripMarkdownCodeFence(String value) {
    String trimmed = value.trim();
    if (trimmed.startsWith("```") && trimmed.endsWith("```")) {
        int firstNewline = trimmed.indexOf('\n');
        if (firstNewline > 0) {
            return trimmed.substring(firstNewline + 1, trimmed.length() - 3).trim();
        }
    }
    return trimmed;
}
```

This is a heuristic band-aid. If Gemini wraps the JSON in ```` ```json ```` but includes an explanatory sentence before the fence, or uses a non-standard fence variation, the JSON parse will fail — and all three callers silently degrade to empty/default results (`catch (Exception) { return empty; }`). The Gemini API supports `response_mime_type: "application/json"` which would eliminate this class of failure entirely. On `gemini-2.5-flash`, enabling structured output is a single field in the request body and carries no additional cost.

---

## Additional Observations (Not Covered in Original)

### 5. The intent resolver fires on every search with no gating

`resolveLocalQueryIntent()` is called unconditionally at `LocalCorpusSearchService.java:75-76`. There is no heuristic to skip it for short or already-optimal queries. A user typing three precise keywords (exactly what makes NEAR fire) still incurs:

- A Gemini API call (latency + cost)
- Token processing (the prompt includes up to 150 work titles from the database)

A simple token-count gate — e.g., skip AI intent resolution when `extractFtsTokens(topic, ...)` yields ≤3 meaningful tokens — would eliminate unnecessary API calls for the very queries that already work best.

### 6. Cost and latency profile

With `gemini-2.5-flash`, per-call cost is low. But the worst-case search involves **three** Gemini round-trips per query:

| Call | When | Latency Impact |
|------|------|----------------|
| `resolveLocalQueryIntent` | Every search | Always |
| `rerankLocalCandidates` | When candidates exist | Always |
| `generateReport` | `localOnlyMode=false` + zero local quotes | Dead path by default |

For the reranker, the prompt includes full quote text and metadata for up to `max(20, quotes * 6)` candidates (`LocalCorpusSearchService.java:778`), which at `maxQuotes=8` means up to 48 passages with author, title, locator, URL, and full quote text. This can produce a substantial prompt. The cost is modest per-search but accumulates across sessions.

### 7. The "first 3 positional tokens" issue is slightly less dire than stated

`SearchCore.buildAndQuery()` (`SearchCore.java:116`) requires only the first 3 tokens as AND; the rest become optional OR. The critique is that positional order ≠ semantic importance. However, `extractFtsTokens` (`SearchCore.java:97`) pre-filters noise tokens and deduplicates via `LinkedHashSet` before `buildAndQuery` ever sees the list. So the "first 3" are the first 3 *meaningful, non-noise, non-author, non-duplicate* tokens from the sentence — not raw words.

This is a meaningful qualification. The tokens are still positionally ordered (not semantically ranked), but they've been cleaned. A sentence like "What does the Universal House of Justice say about the role of women in society?" would yield tokens like `[universal*, house*, justice*, women*, society*]` — where the first three happen to be author tokens that would be excluded by the author filter, leaving `[women*, society*]`. The gap between positional order and semantic importance shrinks after filtering, but it doesn't disappear.

---

## Recommendations

### Part 1 — The AI Pipeline

The original eval offers three options: drop it, fix the wiring, or keep as-is. I agree with these but reorder and refine them:

**Recommended: Hybrid approach (new option).** Keep the reranker but gate the intent resolver behind a token-count heuristic:

1. **Skip AI intent resolution when ≤3 meaningful tokens** — the user has already done the keyword selection. This eliminates unnecessary API calls for the most common case (manual 3-keyword searches).
2. **For >3 tokens, feed `intent.concepts()` into NEAR/AND query building.** If the AI returns 2–3 concepts, use *those* as the FTS tokens instead of the raw sentence tokens. This is the highest-leverage change — it's the modification at `LocalCorpusSearchService.java:66-68` the original eval identified, and it directly targets the "sentence search feels worse than keyword search" complaint.
3. **Keep the reranker unconditionally** — it's the most valuable AI contribution and is gated on having a candidate pool anyway.
4. **Enable structured output (`response_mime_type: "application/json"`)** in `generateText` — trivially improves reliability across all three touchpoints.

This hybrid approach:
- Wastes no API calls on short/optimal queries
- Improves long-sentence queries by letting AI select the NEAR tokens
- Retains the reranker's semantic selection value
- Costs very little to implement (localized changes to `LocalCorpusSearchService` and `GeminiClient.generateText`)

**Fallback position:** If the concept-driven NEAR path doesn't justify the intent resolver, **drop only the intent resolver and keep the reranker.** The reranker's value (see point 1 above) is independent and defensible on its own.

**Only if the reranker alone doesn't justify the API key:** Drop all AI. This achieves parity with Android and removes the dependency entirely.

### Part 2 — External Source

**Recommendation: Remove it.** This is the cleanest option and matches how the app actually works. Specifically:

- Remove `generateReport()` and `buildPrompt()` from `GeminiClient.java`
- Remove the dead branch at `ResearchService.java:42-47`
- Remove `requiredSite`, `promptBoilerplate`, and `noResultsText` AI-fallback config keys
- Remove `localOnlyMode` (it becomes always-true) or keep it as a no-op for backward compatibility
- Update `ConfigLoader.java` validation accordingly

The original eval's "repair properly" option (real web sourcing with grounding tools) is a feature build, not a cleanup. It should be a separate design exercise if genuinely wanted — not something left as misleading config scaffolding.

---

## Verification Strategy

The original eval's suggestion to use `research.debugIntent=true` is sound. I'd add a specific A/B methodology:

1. **Select 10 long-form queries** (full sentences that currently produce poor results compared to keyword equivalents).
2. **Run each three ways:**
   - (A) Current behavior (AI intent resolution + concepts as post-filter + reranker)
   - (B) No AI (skip the Gemini API key entirely, rely on pure FTS)
   - (C) Concept-driven NEAR (feed `intent.concepts()` into `toFtsQueryNear`)
3. **Compare:** result count, relevance of the top 3 passages, and whether the most relevant passage appears in the candidate pool at all.
4. **Also measure:** the number of Gemini API calls per search in each configuration.

This gives a data-driven answer to "is AI necessary?" rather than relying on architectural analysis alone.

---

## Critical Files (same as original)

- `src/main/java/com/bahairesearch/ai/GeminiClient.java` — all AI touchpoints
- `src/main/java/com/bahairesearch/corpus/LocalCorpusSearchService.java` — orchestration; token/query building at `:66-68`, phrase search at `:141-148`, semantic fallback at `:171-191`
- `../BahaiSearchCommon/src/main/java/com/bahairesearch/common/search/SearchCore.java` — FTS query building, NEAR (2–3 tokens), AND (first-3-required), ranking/BM25
- `src/main/java/com/bahairesearch/research/ResearchService.java:42-47` — `localOnlyMode` branch
- `src/main/java/com/bahairesearch/config/ConfigLoader.java` — defaults and external-source config keys