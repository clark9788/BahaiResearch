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
FTS5 prefix matching may find the passage via `best* AND belov*`, but the individual
word `"beloved"` might not match the token `"belov"` or `"beloved"` as an exact
substring in this filter. The NEAR hit gets eliminated **before the reranker even
sees it**.

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
- **BahaiResearchA (Android):** Equivalent `SearchCore` or `LocalCorpusSearchService` copy —
  same changes to the `!nearFired` gate(s)

---

## 5. Platform-specific Impact

### BahaiResearch (Desktop)

| AI Mode | Before fix | After fix |
|---|---|---|
| `gemini` | Exact quote may be lost in reranker | Exact quote guaranteed in final results (-99,999 beats all BM25) |
| `none` | Exact quote in pool but not guaranteed top | Exact quote guaranteed top (rankForDisplay honors -99,999) |
| `mock` | Same as `none` | Same improvement |

### BahaiResearchA (Android)

- No AI reranker — `rankForDisplay()` is the final sort
- `-99,999` always places phrase hits first regardless of source priority, quality band, or BM25
- Fix prevents exact quotes from being outranked by longer passages or higher-priority sources

---

## 6. Implementation Steps

1. **Remove `!nearFired`** from both platform codebases (line 177 topic gate, line 184 knownPhrase gate)
2. **Test with queries** known to produce near-exact quotes via NEAR search:
   - Short topic queries (2–3 words)
   - Queries matching well-known passages verbatim
3. **Verify across all AI modes** (Desktop):
   - `ai.mode=gemini` — exact quote appears first in final results
   - `ai.mode=none` — exact quote appears first in BM25-ranked list
   - `ai.mode=mock` — same as none
4. **Verify Android** — exact quote ranks first in deterministic sort
5. **Run regression**: Confirm that no-query-match scenarios don't break (phrase LIKE returns 0 rows — fine, just merges nothing)

---

## 7. Related Observations (Future Work)

These issues were identified during analysis but are **out of scope** for this change:

1. **Content-term exact-substring filtering** (line 170) — `filterByContentTerms` may
   eliminate NEAR hits because FTS prefix tokens (`belov*`) don't match exact words
   (`beloved`). Investigate separately. Possible approaches:
   - Stem tokens before comparison
   - Relax content-term filtering for NEAR-sourced hits
   - Use the same normalization pipeline as FTS

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