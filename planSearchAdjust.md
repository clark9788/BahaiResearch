# Search Adjustment Plan — Exact Quote Preservation (Cross-Project)

**Affected projects:** BahaiResearch (Desktop) and BahaiResearchA (Android)  
**Scope:** Fixes the `!nearFired` gate that prevents exact quotes from receiving priority scoring

---

## 1. Problem — Exact Quotes Lost After Retrieval

Users have observed that NEAR search successfully retrieves the exact passage matching
their query, but the passage does not appear in the final results. This happens on both
platforms, though the downstream manifestation differs.

### Desktop (with AI reranker)

The Gemini reranker receives a pool of BM25-scored candidates. NEAR hits receive only
a modest BM25 boost via `applyNearBoost()`. The exact-quote passage competes against
other BM25-scored candidates and the reranker may rank it below the display threshold
(typically top 3–5 of `requestedQuotes`).

### Android (no AI, deterministic ranking)

`rankForDisplay()` sorts by:

| Priority | Signal | Score |
|---|---|---|
| 1 | Phrase LIKE hit | **-99,999** (always first) |
| 2 | Source priority | UHJ > compilations > other |
| 3 | Quality band | ~200-900 char passages preferred |
| 4 | BM25 score | Breaks ties within same band |

Without phrase LIKE assigning -99,999, the exact quote competes on BM25 alone. A longer
passage from a more authoritative source that happens to match the NEAR keywords can
outrank the exact quote that the user was looking for.

---

## 2. Root Cause — The `!nearFired` Gate

In `findHits()` (both projects), the phrase-LIKE query is gated by a boolean that
signals whether the NEAR query returned hits:

```
// Current code (simplified):
boolean nearFired = hitsResult.effectiveQuery().startsWith("NEAR(");

if (topicFtsTokens.size() >= 2 && !nearFired) {          // ← LINE 177
    // run phrase LIKE for topic
}

if (intent.knownPhrase() != null && !intent.knownPhrase().isBlank() && !nearFired) {  // ← LINE 184
    // run phrase LIKE for AI-detected known phrase
}
```

### Why this breaks exact-quote priority

1. **NEAR succeeds** → `nearFired = true` → phrase LIKE is **completely skipped**
2. The NEAR hit only has a BM25 score (slightly boosted by `applyNearBoost`)
3. Phrase LIKE is the **only** code path that assigns the `-99,999` guaranteed-first score
4. Result: the exact quote never receives the priority it deserves

### The AND supplement doesn't help

AND search adds more BM25-scored candidates to the pool. It has no `-99,999` mechanism
either. Adding more candidates can actually dilute the reranker's attention, making the
exact quote *less* likely to surface — the opposite of the intended effect.

---

## 3. Two Independent Failure Modes

The exact quote can be lost at two different stages:

### Mode A — Content-term filtering elimination

At line 170 (after merge but before phrase LIKE):
```java
topical = SearchCore.filterByContentTerms(bookScoped, conceptTerms);
```

This checks whether the passage text contains concept terms as **exact substrings**.
The originally suspected cause — FTS prefix stemming (`belov*`) not matching the literal
word `"beloved"` — does not actually apply here: `extractFtsTokens` appends `*` to the
**whole normalized word** (`"beloved*"`, not a truncated stem), the FTS5 table uses the
default `unicode61` tokenizer with no Porter/stemming, and `containsAnyContentTerm` already
does a lenient `token.startsWith(term)` comparison. So this specific word-mismatch scenario
doesn't occur in the current code. Mode A may still have a real but different failure mode
(e.g. an AI-inferred concept term that legitimately isn't present in the passage's literal
text even though NEAR matched on other words) — that needs its own investigation with a
verified real example, not the stemming hypothesis below.

### Mode B — BM25 score lost in rerank

The NEAR hit survives Mode A but has only a BM25 score. Without the `-99,999` that
phrase LIKE would have assigned (if the `!nearFired` gate weren't blocking it), the
Gemini reranker treats it identically to any other BM25 candidate and may rank it
below the display threshold.

**The `!nearFired` gate fix addresses Mode B.** Mode A (content-term substring
filtering) is a separate issue requiring its own investigation.

---

## 4. The Fix — Remove `!nearFired` Gate

### Change

Remove `!nearFired` from **both** gate conditions so that phrase LIKE always runs
regardless of whether NEAR succeeded:

```
// Fixed:
boolean nearFired = hitsResult.effectiveQuery().startsWith("NEAR(");

if (topicFtsTokens.size() >= 2) {          // ← removed !nearFired
    // run phrase LIKE for topic
}

if (intent.knownPhrase() != null && !intent.knownPhrase().isBlank()) {  // ← removed !nearFired
    // run phrase LIKE for AI-detected known phrase
}
```

### What this achieves

| Before fix | After fix |
|---|---|
| NEAR hits: BM25 score only | NEAR hits: BM25 score + phrase LIKE assigns -99,999 |
| Reranker may drop exact quote | -99,999 guarantees exact quote ranks first |
| Known phrase LIKE also skipped | Known phrase LIKE always runs |

### Cost

One extra SQL `LIKE` query per search. No API calls, no network — just a local FTS5
index scan. Desktop and Android both handle this without perceptible latency change.

### Files to modify

- **BahaiResearch (Desktop):** `src/main/java/com/bahairesearch/corpus/LocalCorpusSearchService.java`,
  lines 177 and 184 — remove `&& !nearFired` conditions
- **BahaiResearchA (Android):** `LocalCorpusSearchService.java` copy — same change to the
  topic phrase gate (line 83). Android has no `knownPhrase` gate since there's no AI reranker.

Note: `SearchCore.java` itself (ranking, filtering, phrase-score sentinel) lives in the shared
`BahaiSearchCommon` module and does not need duplicated changes — only the two platform-specific
`LocalCorpusSearchService.java` copies contain the `!nearFired` gate.

### Out of scope — a third `!nearFired` gate

A third occurrence exists (desktop line 197, Android line 91) guarding
`findAdditionalBookScopedHits` — it tops up the candidate pool count when a specific book is
requested and results are thin. This is a different concern (pool size, not priority scoring)
and is **intentionally left unchanged** by this fix. Noting it here so it isn't mistaken for an
oversight during review.

---

## 5. Platform-specific Impact

### BahaiResearch (Desktop)

Actual modes (`research.aiMode`, see `LocalCorpusSearchService.java` lines 66–69): `full`
(default — intent resolver + reranker both run), `rerank-only` (intent resolver skipped,
reranker still runs on the FTS-built query), `none` (all AI skipped, pure FTS + rankForDisplay).
There is no `gemini` or `mock` mode — earlier drafts of this document used those names in error.

| AI Mode | Before fix | After fix |
|---|---|---|
| `full` | Exact quote often eliminated before the reranker ever sees it | Exact quote guaranteed a slot in the candidate pool, ranked first — final selection is still the reranker's judgment call |
| `rerank-only` | Same as `full` (same reranker call, just skips intent resolution) | Same improvement as `full` |
| `none` | Exact quote in pool but not guaranteed top | Exact quote guaranteed top (rankForDisplay honors -99,999) |

**On `full`/`rerank-only` specifically:** `buildCandidateRerankPrompt()` strips scores before
building the prompt — Gemini sees `ID / Author / Book / Locator / URL / Quote` only, with no
signal that ID 1 is a verified exact/phrase match. So the fix guarantees pool *inclusion*
(fixing Mode B's elimination problem) and top position in the list Gemini reads, but does not
force Gemini to select it. Decision: no changes to make the reranker selection itself
deterministic for now — the query wording alone should be enough of a signal for Gemini to pick
the exact match most of the time. Test with real queries and revisit (e.g. explicitly flagging
phrase-tier candidates in the prompt, or auto-including the top phrase-tier hit alongside
Gemini's picks) only if this turns out to be a real problem in practice.

### BahaiResearchA (Android)

- No AI reranker — `rankForDisplay()` is the final sort
- `-99,999` always places phrase hits first regardless of source priority, quality band, or BM25
- Fix prevents exact quotes from being outranked by longer passages or higher-priority sources

---

## 6. Implementation Steps

1. **Remove `!nearFired`** — desktop: line 177 topic gate and line 184 knownPhrase gate;
   Android: line 83 topic gate (no knownPhrase gate to change there)
2. **Test with queries** known to produce near-exact quotes via NEAR search:
   - Short topic queries (2–3 words)
   - Queries matching well-known passages verbatim
3. **Verify across all AI modes** (Desktop):
   - `research.aiMode=full` — exact quote appears first in final results
   - `research.aiMode=rerank-only` — same check, intent resolver skipped
   - `research.aiMode=none` — exact quote appears first in BM25-ranked list
4. **Verify Android** — exact quote ranks first in deterministic sort
5. **Run regression**: Confirm that no-query-match scenarios don't break (phrase LIKE returns 0 rows — fine, just merges nothing)

---

## 7. Related Observations (Future Work)

These issues were identified during analysis but are **out of scope** for this change:

1. **Content-term exact-substring filtering** (line 170) — `filterByContentTerms` may still
   eliminate legitimate NEAR hits in some cases, but not via the stemming mismatch originally
   suspected (see §3, Mode A — verified not to apply to the current tokenizer/token-building
   code). Needs a concrete failing example before further investigation; no fix proposed yet.

2. **Duplicate phrase paths** — The topic phrase LIKE and knownPhrase LIKE run as
   separate queries. If the same passage matches both, deduplication preserves the
   first score (-99,999 either way), so this is benign but worth noting.

3. **NEAR boost magnitude** — `applyNearBoost()` may be unnecessary after this fix
   since phrase LIKE provides a stronger guarantee. Could simplify by removing the
   boost and letting -99,999 handle exact-quote priority exclusively.

---

## Revision History

| Date | Author | Changes |
|---|---|---|
| 2026-08-03 | AI assistant | Initial document — `!nearFired` gate fix, cross-project impact analysis |
| 2026-08-03 | AI assistant | Review pass verified against code: corrected Android scope (no knownPhrase gate, `SearchCore` is shared so no duplication needed there), flagged the third `!nearFired` gate (line 197/91) as intentionally out of scope, softened the `gemini`-mode "guaranteed" claim since score info isn't passed to the reranker prompt (decision: rely on query wording for now, test and revisit only if Gemini drops the exact match in practice), and corrected the Mode A stemming example (no Porter tokenizer/stemming exists in this codebase, so it doesn't apply) |
| 2026-08-03 | AI assistant | Fix implemented (desktop lines 177/184, Android line 83) and both projects compile clean via Gradle. Corrected AI mode names throughout this doc — the real modes are `full`/`rerank-only`/`none` (`research.aiMode`), not the invented `gemini`/`mock` names used in earlier drafts; `full` and `rerank-only` both invoke the reranker so share the same "guaranteed pool inclusion, not guaranteed selection" caveat |