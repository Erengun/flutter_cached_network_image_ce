# Cache Size Limit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional byte limit (`maxCacheSizeInBytes`) to `DefaultCacheManager` (IO + web), enforced at store time with eviction only. Oversized entries are delivered but never cached.

**Architecture:** The total size is the sum of stored `CacheEntryMetadata.length` values. A byte-only eviction pass reuses `CleanupCoordinator.schedule` / `evictOverCapacity` with a byte-only predicate. The full sweep's `_isOverCapacity()` grows to count-over || byte-over. The coordinator's retry gate learns that byte-limit eviction is a runtime eviction source too.

**Tech Stack:** Dart/Flutter, hive_ce, `package:clock` (`withClock`), flutter_test, `http/testing.dart` `MockClient`.

**Spec:** `docs/superpowers/specs/2026-11-22-cache-size-limit-design.md`

## Global Constraints

- Parameter: `int? maxCacheSizeInBytes`, default `null` (no limit). It must be > 0 when set (`assert`).
- Apps that don't set the limit: no new runtime work, no behavior change. All existing tests stay green.
- A byte-triggered eviction must never enforce `maxNrOfCacheObjects`. Count enforcement at runtime stays opt-in via `startCleanup()`.
- The store-time byte path does no orphan scan and no expiry pass.
- Eviction order is the configured `cleanupStrategy`.
- Oversized means `length > maxCacheSizeInBytes`. A size exactly equal to the limit is cacheable.
- Follow `analysis_options.yaml` (`prefer_final_locals`). Don't add `// ignore`. Commits use Conventional Commits, no co-author trailer, and need user confirmation.

## Review Focus

1. **Entries without a stored `length`** (`fromMap` defaults to 0) count as 0 bytes. They must not crash the size sum. → Task 2 test `entries without length count as zero bytes`.
2. **Many concurrent stores crossing the limit at once:** expect one coalesced pass and a total ≤ limit when it settles. → Task 2 test `concurrent stores over the limit settle under it`.
3. **`dispose()` right after an over-limit store:** expect no unhandled async error, and no retry firing after dispose. → Task 2 test `dispose during byte eviction is clean`.
4. **An overwrite of the same key with larger bytes:** the total reflects the new length, not old + new. → Task 2 test `overwriting a key counts only the new length`.
5. **Download whose size equals the limit:** it is cached (strict `>`). → Task 3 test `entry exactly at the limit is cached`.

---

### Task 1: Coordinator retry gate covers byte-limit eviction

**Files:**
- Modify: `cached_network_image/lib/src/cache/cleanup_coordinator.dart` (`capacityCleanupEnabled` field, `scheduleCapacityRetry`, `reset`)
- Test: `cached_network_image/test/deferred_cleanup_test.dart` (group `CleanupCoordinator`)

**Interfaces:**
- Produces: `bool byteLimitEvictionEnabled = false;` on `CleanupCoordinator`. `scheduleCapacityRetry` schedules when `capacityCleanupEnabled || byteLimitEvictionEnabled` (and served entries exist). `reset()` sets `byteLimitEvictionEnabled = false`.

- [ ] **Step 1: Write failing tests** in group `CleanupCoordinator`:
  - `byte-limit eviction schedules a retry while capacity cleanup is off`: build a coordinator with `servedEntryGracePeriod: Duration(milliseconds: 20)`, `byteLimitEvictionEnabled = true`, `capacityCleanupEnabled = false`. Call `markServed('a', clock.now())`, then `scheduleCapacityRetry(clock.now(), () async => retried++)`. Wait 50 ms and expect `retried == 1`.
  - `reset disables byte-limit eviction`: set the flag true, call `reset()`, and expect `byteLimitEvictionEnabled` to be `isFalse`. Then do the same markServed + scheduleCapacityRetry as above, wait 50 ms, and expect `retried == 0`.
- [ ] **Step 2: Run, expect FAIL** (`byteLimitEvictionEnabled` undefined):
  `flutter test test/deferred_cleanup_test.dart --plain-name 'byte-limit'`
- [ ] **Step 3: Implement** the field and the gate change; reset it in `reset()`.
- [ ] **Step 4: Run** `flutter test test/deferred_cleanup_test.dart`. Expect all to PASS.
- [ ] **Step 5: Commit** `feat(cache): let byte-limit eviction schedule protection retries`

---

### Task 2: IO byte limit with store-time eviction

**Files:**
- Modify: `cached_network_image/lib/src/cache/default_cache_manager.dart` (constructor and fields, `_doInit`, `dispose`, `_scheduleCapacityCleanup`, `_isOverCapacity`)
- Create: `cached_network_image/test/cache_size_limit_test.dart` (IO tests; reuse the `_temporaryDirectory` pattern from `deferred_cleanup_test.dart`)

**Interfaces:**
- Consumes: `CleanupCoordinator.byteLimitEvictionEnabled` (Task 1).
- Produces:
  - `final int? maxCacheSizeInBytes;` constructor param `this.maxCacheSizeInBytes` with `assert(maxCacheSizeInBytes == null || maxCacheSizeInBytes > 0)`.
  - `int _cachedBytes()`: sum of `raw['length'] as int? ?? 0` over the open box's values. Returns 0 when the box is null or closed.
  - `bool _isOverByteLimit()`: limit set and `_cachedBytes() > limit`. Guard against a null or closed box like `_isOverCapacity`.
  - `_isOverCapacity()` returns count-over || `_isOverByteLimit()`.
  - `Future<void> _evictOverByteLimit()`: calls `_cleanup.evictOverCapacity` with `isOverCapacity: _isOverByteLimit`, `candidates: () => _cleanupStrategy.sortForEviction(_snapshotEntries())`, `evict: _evictEntry`, and `retry: _scheduleByteLimitEviction`. Wrap it in try/catch with logging, like `_cleanupOldFiles`.
  - `Future<void> _scheduleByteLimitEviction()`: `_cleanup.schedule(_evictOverByteLimit, _isOverByteLimit, capacity: true)`.
  - `_scheduleCapacityCleanup()`: if `capacityCleanupEnabled && _isOverCapacity()`, keep the existing full sweep; else if `_isOverByteLimit()`, call `unawaited(_scheduleByteLimitEviction())`.
  - In `_doInit`, after the box opens: `_cleanup.byteLimitEvictionEnabled = maxCacheSizeInBytes != null`. In `dispose()`, next to `capacityCleanupEnabled = false`, set `byteLimitEvictionEnabled = false`.

Tests use `putFile` with `List.filled(n, 0)` bytes, `withClock(Clock.fixed(t))` for ordering, and `cleanupStrategy: const LruCleanupStrategy()` unless stated. "Wait for eviction" means `await Future<void>.delayed(const Duration(milliseconds: 20))`.

- [ ] **Step 1: Write failing tests** in `cache_size_limit_test.dart`, group `IO byte limit`:
  - `defaults to no byte limit`: `DefaultCacheManager().maxCacheSizeInBytes` is null.
  - `rejects a non-positive limit`: `expect(() => DefaultCacheManager(maxCacheSizeInBytes: 0), throwsA(isA<AssertionError>()))`.
  - `a store over the limit evicts in strategy order without startCleanup`: limit 100. Put `a` (40 bytes, t0) and `b` (40 bytes, t0+1 min). Under the clock at t0+2 min (past the 30 s protection of `a` and `b`), put `c` (40 bytes). Wait for eviction. Expect `a` evicted, `b` and `c` present, and total ≤ 100. Read totals with `getCacheSize()`.
  - `byte eviction does not enforce the count cap`: `maxNrOfCacheObjects: 2`, limit 1000. Put 4 × 10 bytes, spaced past protection, and wait. Expect all 4 present.
  - `protected entries keep the cache over the limit until cleanup after expiry`: limit 50. Put `a` (40) and `b` (40) at the same instant t0, both protected. Wait, and expect both present. Then run `withClock(t0 + 31 s, manager.debugRunCleanup)` and expect exactly one of them evicted.
  - `startup sweep enforces the byte limit`: a writer with no limit puts 3 × 40 bytes and is disposed. A reader with limit 100 is created on the same dir with the default `cleanupOnInitialize`. Call `debugRunCleanup()` under the clock at t0+1 h and expect total ≤ 100.
  - `entries without length count as zero bytes`: a writer (no limit) runs `putFile('https://example.com/legacy', 50 bytes, key: 'legacy')` and is disposed. Reopen the box the way `default_cache_manager_test.dart` (~line 348) does, with `HiveImpl().openBox<Map>('cached_network_image_cache', path: '<dir>/cached_network_image_ce/hive')`. Re-put `'legacy'` with its map minus `'length'`, then close. A reader with limit 10 and `cleanupOnInitialize: false` runs `putFile` of 5 bytes for key `new` without throwing. After waiting, both `legacy` and `new` are present.
  - `concurrent stores over the limit settle under it`: limit 100. `Future.wait` 10 × 30-byte puts at t0, then advance to t0+31 s and run `debugRunCleanup()`. Expect total ≤ 100.
  - `dispose during byte eviction is clean`: limit 10. Put 2 × 10 bytes, then call `dispose()` immediately. Expect it completes without error, then wait 50 ms. flutter_test fails the test on any uncaught async error, so no extra assertion is needed.
  - `overwriting a key counts only the new length`: limit 100. Put key `k` with 30 bytes, then again with 60. Wait. Expect `k` present and `getCacheSize() == 60`.
  - `no limit: stores above the count cap trigger no runtime sweep`: keep the existing behavior. Use the `_CountingLruCleanupStrategy` pattern and expect `calls == 0` after 3 puts with `maxNrOfCacheObjects: 2`.
- [ ] **Step 2: Run, expect FAIL** (no `maxCacheSizeInBytes` param):
  `flutter test test/cache_size_limit_test.dart`
- [ ] **Step 3: Implement** the Interfaces above.
- [ ] **Step 4: Run** `flutter test test/cache_size_limit_test.dart test/deferred_cleanup_test.dart test/default_cache_manager_test.dart`. Expect all to PASS.
- [ ] **Step 5: Commit** `feat(cache): enforce maxCacheSizeInBytes at store time on IO`

---

### Task 3: IO oversized entries are delivered, not cached

**Files:**
- Modify: `cached_network_image/lib/src/cache/default_cache_manager.dart` (download store path near `runOnStoreChain`, and `putFile`)
- Test: `cached_network_image/test/cache_size_limit_test.dart` (group `IO oversized entries`)

**Interfaces:**
- Consumes: `maxCacheSizeInBytes` (Task 2).
- Produces: `bool _exceedsByteLimit(int length)` = limit set && `length > limit`.
  - **Download path:** when `_exceedsByteLimit(receivedBytes)`, skip the rename into the cache. Move or copy the temp file to the same `systemTemp …nocache` path the interceptor-rejection branch uses, and yield a `FileInfo` with `FileSource.Online` pointing at it. Remove any existing metadata and file for the key the way `removeFile` does (under the store lease; don't call the public `removeFile` while holding the lease). Release all path leases on every path.
  - **`putFile`:** when `_exceedsByteLimit(fileBytes.length)`, write the bytes to a `systemTemp` `.nocache` file, remove any existing entry for the key, and return that file.
  - Interceptors' `onStore` is not run for oversized entries, because they are never stored.

Downloads in tests use `httpClientFactory: () => http_testing.MockClient((_) async => http.Response.bytes(bytes, 200))`.

- [ ] **Step 1: Write failing tests:**
  - `oversized download is delivered but not cached`: limit 10, response of 20 bytes. Take the `FileInfo` from `getFileStream(url)`: its file exists, has 20 bytes, and its path is not under the cache dir. `getFileFromCache(url)` is null and `getCacheSize()` is 0.
  - `oversized download removes the previous entry for the key`: limit 10. `putFile(url, 5 bytes)`, then expire it (`maxAge: Duration.zero`) and download 20 bytes through `getFileStream`. Expect `getFileFromCache(url)` null and no file left at the old cache path.
  - `oversized putFile is returned but not cached`: limit 10, `putFile(url, 20 bytes)`. The returned file exists with 20 bytes, and `getFileFromCache(url)` is null.
  - `entry exactly at the limit is cached`: limit 10, `putFile(url, 10 bytes)`. Expect `getFileFromCache(url)` not null.
- [ ] **Step 2: Run, expect FAIL:** `flutter test test/cache_size_limit_test.dart --plain-name 'IO oversized'`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test`. Expect the full package suite to PASS.
- [ ] **Step 5: Commit** `feat(cache): skip caching entries larger than maxCacheSizeInBytes on IO`

---

### Task 4: Web byte limit and oversized entries

**Files:**
- Modify: `cached_network_image/lib/src/cache/default_cache_manager_web.dart` (constructor and fields, init, `dispose`, `_scheduleCapacityCleanup`, `_isOverCapacity`, `_storeFile`)
- Test: `cached_network_image/test/default_cache_manager_web_test.dart` (new group `WebCacheManager byte limit`; use the existing `testHive` setup and the `withClock` pattern from group `WebCacheManager cleanup`)

**Interfaces:**
- Consumes: Task 1 coordinator flag.
- Produces: the same members as Task 2, with the same names and semantics, over `_metaBox`: `maxCacheSizeInBytes` (assert > 0), `_cachedBytes`, `_isOverByteLimit`, `_evictOverByteLimit`, `_scheduleByteLimitEviction`, the updated `_isOverCapacity` and `_scheduleCapacityCleanup`, and flag set/clear in init/dispose.
  - **Oversized on web:** handled once in `_storeFile`, covering both download and `putFile`. When `length > limit`, inside the exclusive store lease, `_deleteEntry` any existing entry for the key. Don't write either box, and return `_bytesToFile(metadata.relativePath, bytes)`. Don't `_markServed`.

- [ ] **Step 1: Write failing tests** mirroring Task 2 and Task 3 on web:
  - `a store over the limit evicts in strategy order without startCleanup`
  - `byte eviction does not enforce the count cap`
  - `startup sweep enforces the byte limit`
  - `oversized putFile is returned but not cached`, including that the previous entry for the key is removed
  - `oversized download is delivered but not cached`, using the file's existing `MockClient` setup from group `WebCacheManager getFileStream`
  - `entry exactly at the limit is cached`
- [ ] **Step 2: Run, expect FAIL:** `flutter test test/default_cache_manager_web_test.dart --plain-name 'byte limit'`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `flutter test test/default_cache_manager_web_test.dart`, then `flutter test --platform chrome test/default_cache_manager_api_test.dart`. Expect PASS.
- [ ] **Step 5: Commit** `feat(cache): add maxCacheSizeInBytes to the web cache manager`

---

### Task 5: Stub, docs, changelog, full verification

**Files:**
- Modify: `cached_network_image/lib/src/cache/default_cache_manager_stub.dart`. Add `int? maxCacheSizeInBytes` constructor param and field, matching how `maxIdleDuration` is declared there.
- Modify: `cached_network_image/test/default_cache_manager_api_test.dart`. Extend the existing constructor-shape test to pass `maxCacheSizeInBytes: 1024`.
- Modify: `cached_network_image/README.md`. Add a "Limiting Cache Size" subsection after "Deferred and Access-Based Cleanup", covering: the example `DefaultCacheManager(maxCacheSizeInBytes: 100 * 1024 * 1024)`; enforced on store and at startup; eviction order follows `cleanupStrategy`; soft limit (30 s protection, retry); oversized entries shown but not cached; sizes come from stored metadata, so `getCacheSize()` on IO can differ slightly.
- Modify: `cached_network_image/CHANGELOG.md`, under `## Unreleased`: `* **Feature:** \`DefaultCacheManager\` accepts \`maxCacheSizeInBytes\` to cap the cache by total bytes (#93). Stores that push the cache over the limit evict entries in \`cleanupStrategy\` order; entries larger than the limit are delivered but not cached. No change when unset.`

- [ ] **Step 1: Update the API test, run it, expect FAIL:** `flutter test test/default_cache_manager_api_test.dart`
- [ ] **Step 2: Implement the stub param; add the README and CHANGELOG text.**
- [ ] **Step 3: Verify the package:** run `flutter analyze` (expect no issues), `dart format --output=none --set-exit-if-changed .` (expect 0 changed), `flutter test` (expect all pass), and `flutter test --platform chrome test/default_cache_manager_api_test.dart` (expect pass).
- [ ] **Step 4: Commit** `docs(cache): document maxCacheSizeInBytes`
