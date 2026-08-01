# Assessment: AI Search Handoffs & External-Source Path

## Context

This responds to `Prompt.md`. Two questions:

1. Evaluate the AI-assisted search pipeline (sentence → search words, and results → prominent-quote selection), and judge whether the AI is even worth keeping given that the non-AI local search already works well and is what the Android app (`BahaiResearchA`) relies on.
2. Diagnose whether the external-source path (`localOnlyMode=false` → `requiredSite` = oceanlibrary.com) is actually used, and recommend what to do with it.

Architecture confirmed: pure search logic lives in the shared `../BahaiSearchCommon` (`SearchCore.java`, FTS5 over SQLite: NEAR/AND/OR + BM25 ranking). Both desktop and Android consume it via a Gradle composite build. The AI is **Google Gemini** (`gemini-2.5-flash`), desktop-only, in `src/main/java/com/bahairesearch/ai/GeminiClient.java`. Orchestration is `corpus/LocalCorpusSearchService.java`.

---

## Part 1 — The AI pipeline

### What actually happens (three AI touch points, not two)

1. **Intent resolver** — `GeminiClient.resolveLocalQueryIntent()` (`GeminiClient.java:74`). Sentence → JSON `{author, workTitle, knownPhrase, concepts[]}`.
2. **Candidate reranker** — `GeminiClient.rerankLocalCandidates()` (`GeminiClient.java:109`). Numbers the local candidate pool and asks Gemini to return `selectedIds` (evidence-only; cannot invent text).
3. **Web-synthesis fallback** — `GeminiClient.generateReport()` (`GeminiClient.java:56`). Only reachable when `localOnlyMode=false` AND local search returns zero quotes (see Part 2).

### The core finding — why the "search words" feel ineffective

**The AI's generated search words do not drive retrieval.** The actual FTS query (NEAR/AND/OR) is built from the **raw topic sentence**, not from the AI's `concepts`:

- `LocalCorpusSearchService.java:66-68` builds all three queries via `SearchCore.toFtsQueryNear/toFtsQuery/toFtsQueryOr(topic, author)` — operating on `topic`, the raw sentence.
- The AI `intent.concepts()` are used only for **post-retrieval filtering** (`filterByContentTerms`, `:127`) and a **last-resort semantic fallback** that fires *only when the pool is already empty* (`:171-191`).

So the first handoff's headline value — turning a sentence into good search words — is largely bypassed for the primary search. Consequences, given `SearchCore.extractFtsTokens` (`SearchCore.java:97`) and NEAR firing only for **exactly 2–3 tokens** (`:59`):

- A **full sentence** yields many tokens → NEAR never fires → falls to AND, where only the **first 3 positional tokens** are required (`buildAndQuery`, `:116`) and the rest become optional OR. "First 3 as they appear in the sentence" ≠ "3 most meaningful," which is exactly why your **manual 3-keyword** searches beat sentence input: you hand-pick the 3 that make NEAR fire and the rating surface the right quote.
- This is the mechanism behind your observation. The AI is positioned as a filter/fallback, not as the token source, so it can't reproduce the quality of your manual keyword selection where it matters most (the FTS query itself).

### Reranker (handoff 2)

Structurally sound and safe (evidence-only, validates IDs in range, dedupes, back-fills from the ranked pool on partial/empty AI response — `LocalCorpusSearchService.java:767-818`). But it can only reorder/select from whatever the retrieval produced. If retrieval missed the best quote (per the token issue above), the reranker cannot recover it. Good ceiling, limited by a weak floor.

### Robustness notes (minor)

- `buildPrompt()` has a duplicated list item numbered "2)" (`GeminiClient.java:263,265`) and mislabeled numbering — cosmetic, low risk.
- All AI calls degrade silently to non-AI defaults on blank key / any exception (`:75-77, :101-103, :115-117, :137-139`). Good for resilience, but failures are invisible unless `research.debugIntent=true`.
- `generateText` uses plain `generateContent` with only `contents` — no structured-output/JSON mode, no grounding tools (`:142-152`).

### Verdict on "is AI necessary?"

The non-AI search is the real engine and is strong. As currently wired, the AI adds **modest, inconsistent value**: the reranker can improve ordering, but the intent resolver's main contribution (search words) is disconnected from retrieval. Three honest options:

- **Drop it** — defensible. Parity with Android, no API key, one fewer moving part. You lose only the rerank polish and alias/work-title inference.
- **Keep + fix the wiring** (highest leverage) — feed `intent.concepts()` into token/NEAR selection so a sentence is reduced to the ~3 best keywords *before* the FTS query is built (i.e., let AI do what you do manually). This targets the exact complaint. Would live in `LocalCorpusSearchService` around `:66-68`, using `intent.concepts()` when present.
- **Keep as-is** — only if the rerank ordering alone justifies the key.

Recommendation to decide later: **evaluate option 2** before dropping — it's the change most likely to make AI clearly worth it, and it's small and localized.

---

## Part 2 — External source (oceanlibrary.com): diagnosis

**Your suspicion is correct: the external site is not used to fetch quotes.**

- Constants defined in `config/ConfigLoader.java:17,18,41,42`; default `localOnlyMode = true`.
- `localOnlyMode` is read in exactly two places: a startup validation (`ConfigLoader.java:97` — requires a Gemini key if false) and the branch in `research/ResearchService.java:42-47`.
- Branch behavior: local search runs first; the external/Gemini path (`generateReport`) is reached **only** if `localOnlyMode=false` **and** local returned zero quotes. With the shipped default (`true`), it is **unreachable — dead code**.
- Even when reached, **nothing fetches oceanlibrary.com.** `requiredSite` is only interpolated into the Gemini *prompt text* ("Limit research to site:%s only", `GeminiClient.java:262,287`). The only outbound HTTP goes to the Gemini API (`:36-37`), and the request body carries **no** `tools` / `google_search` / grounding config (`:143-151`). So Gemini is merely *told in prose* to use the site; a plain `generateContent` call cannot browse — it would answer from model weights (i.e., hallucinate citations), which is why `parseReport` enforces non-empty citation fields as a guard (`:228-231`).

**In short:** the "outside source" is a vestigial prompt instruction, orphaned by the refactor to the local-corpus model.

### Recommendation

**Remove or clearly quarantine it.** As written it is misleading — the config implies a live external source that does not exist, and if ever enabled it would surface unverifiable AI-generated citations. Options, in order of preference:

1. **Remove** `generateReport`/`buildPrompt`/`requiredSite` and the `localOnlyMode=false` branch; drop the keys from config. Cleanest, matches how the app actually works now.
2. **Repair properly** *only if* you genuinely want web sourcing — requires real retrieval (Gemini grounding/`google_search` tool, or an actual HTTP fetch + parse of oceanlibrary.com), plus citation verification against fetched text. This is a real feature build, not a config flip.
3. **Document as disabled** — leave code but mark keys deprecated/no-op in `bahai-research.properties` so no one is misled.

---

## Critical files (reference)

- `src/main/java/com/bahairesearch/ai/GeminiClient.java` — all AI handoffs + prompts.
- `src/main/java/com/bahairesearch/corpus/LocalCorpusSearchService.java` — orchestration; token/query building at `:66-68`, concept usage at `:100,127,171`.
- `../BahaiSearchCommon/.../search/SearchCore.java` — FTS query building, NEAR (2–3 tokens), ranking/BM25 boost.
- `src/main/java/com/bahairesearch/research/ResearchService.java:42-47` — the localOnlyMode branch.
- `src/main/java/com/bahairesearch/config/ConfigLoader.java` — constants/defaults.

## Verification (if any change is later pursued)

- Enable `research.debugIntent=true` to log the resolved intent, effective FTS query, and pool sizes per search — this is the fastest way to *see* the token/concept disconnect on a real sentence vs. a 3-keyword query.
- Compare, for the same query: (a) full sentence vs. (b) your manual 3 keywords, with and without an API key, watching which query string (`NEAR(...)` vs `AND`) actually fires.
