# Cache size limit (issue #93): design

## Intent

Let apps cap the disk/IndexedDB space the image cache uses, in bytes, next to
the existing `maxNrOfCacheObjects` entry cap. Requested in #93: when a new
image would push the cache over the limit, evict until it fits; an image larger
than the whole limit is shown but not cached.

## Goals

- New optional `DefaultCacheManager` parameter `maxCacheSizeInBytes` (`int?`,
  default `null` = no byte limit). Native (IO) and web; the stub accepts it.
- With a limit set, the limit is enforced when entries are stored, not only at
  startup.
- An entry larger than the limit is delivered to the caller but never stored.

## Non-goals

- No change for apps that don't set the limit (no new runtime work, no new
  writes).
- No change to when the entry-count cap is enforced (startup sweep, plus
  runtime only after `startCleanup()`, as shipped in #87).
- No hard real-time guarantee (see "Soft limit").

## Anti-goals

- Running the full cleanup sweep (orphan directory scan, file stats, expiry
  pass) on every store. #87's review rejected exactly that cost.
- A running byte counter that can drift from the stored metadata.

## Approaches

1. **Byte limit enforced at store time with eviction only (chosen).** When a
   store pushes the total over the limit, evict in `cleanupStrategy` order until
   it fits. No orphan scan or expiry pass on that path.
2. **Byte limit follows the count-cap rules.** Enforced at startup, and at
   runtime only after `startCleanup()`. Rejected: the cache can exceed a "50 MB"
   limit for a whole session, which defeats the point of a byte limit.
3. **Byte limit triggers the full cleanup sweep at store time.** Rejected: the
   per-store cost #87's review objected to, during scroll bursts.

## Design

- **Total size:** sum of `CacheEntryMetadata.length` over the metadata box,
  computed on demand. It's in memory and O(entries); a running counter only if
  profiling shows a need.
- **Over-limit check:** `_isOverByteLimit()` = limit set && total > limit.
  The existing `_isOverCapacity()` becomes count-over || byte-over, so the
  startup sweep and `startCleanup()` enforce both limits.
- **Store-time path:** after a successful store (download and `putFile`), if
  `_isOverByteLimit()`, schedule a coalesced eviction through
  `CleanupCoordinator`. It loops `evictOverCapacity` with the *byte* predicate
  only. A byte trigger must not quietly enforce the count cap at runtime.
- **Eviction order:** the configured `cleanupStrategy` (default TTL = soonest
  `validTill` first; LRU = least recently accessed first). Existing per-entry
  safety holds: served-entry protection, store/eviction leases, unchanged-
  metadata check.
- **Soft limit:** entries served within the last 30 s are protected. If that
  blocks enough eviction, the existing retry runs when protection expires.
  Documented in the README.
- **Oversized entry** (`length > maxCacheSizeInBytes`): not stored. The caller
  still gets the image. On IO this reuses the "interceptor rejected storage"
  temp-copy path; on web the in-memory file is returned without writing to
  Hive. Any existing entry for that key is removed, since it is outdated and
  can't be replaced.
- **Validation:** `maxCacheSizeInBytes` must be > 0 when set (assert).
- **Docs:** README cleanup section and CHANGELOG "Unreleased".

## Tests (TDD, IO and web)

- No limit set: behavior and stored entries are unchanged.
- A store that crosses the limit evicts in strategy order until under it,
  without `startCleanup()`.
- A byte-triggered eviction does not enforce the count cap.
- An oversized download is delivered as a non-cached file. Nothing is stored,
  and any previous entry for the key is removed. The same holds for `putFile`.
- Protected entries keep the cache over the limit until the retry evicts them.
- Startup sweep / `startCleanup()` enforce the byte limit too.

## Left to the builder

- Exact coordinator API shape for a byte-only eviction pass. Reuse
  `schedule` / `evictOverCapacity` with a predicate rather than new machinery.
- Parameter name `maxCacheSizeInBytes` is my call, chosen for clarity next to
  `maxNrOfCacheObjects`.
- IO `getCacheSize()` reads file sizes from disk, while the limit uses stored
  lengths. They can differ slightly if the OS removes files. Accepted.
