import 'dart:async';

import 'cache_entry_metadata.dart';

typedef CleanupLease = void Function();

enum CacheEvictionResult { removed, changed, skipped }

/// Coordinates cleanup sweeps and protects entries recently handed to callers.
final class CleanupCoordinator {
  CleanupCoordinator({
    required this.servedEntryGracePeriod,
    required this.servedEntryPruneThreshold,
  });

  final Duration servedEntryGracePeriod;
  final int servedEntryPruneThreshold;

  final Map<String, DateTime> _recentlyServed = {};
  final Map<String, Map<Completer<void>, String?>> _pendingStores = {};
  final Map<String, Completer<void>> _evictions = {};
  final Map<String, Set<Object>> _activePaths = {};
  final Map<String, Completer<void>> _pathDeletions = {};
  Future<void>? _cleanupFuture;
  bool _fullSweepInFlight = false;
  _QueuedSweep? _queuedFullSweep;
  Timer? _capacityRetryTimer;
  DateTime? _capacityRetryAt;
  bool _capacityCleanupPending = false;

  bool capacityCleanupEnabled = false;
  bool byteLimitEvictionEnabled = false;

  Future<void>? get cleanupFuture => _cleanupFuture;

  int get recentlyServedCount => _recentlyServed.length;

  void markServed(String key, DateTime now) {
    _recentlyServed[key] = now;
    if (_recentlyServed.length > servedEntryPruneThreshold) {
      pruneRecentlyServed(now);
    }
  }

  void pruneRecentlyServed(DateTime now) {
    _recentlyServed.removeWhere(
      (_, servedAt) => now.difference(servedAt) >= servedEntryGracePeriod,
    );
  }

  bool protects(String key) =>
      _recentlyServed.containsKey(key) || _pendingStores.containsKey(key);

  bool isStoring(String key, {String? path}) {
    final stores = _pendingStores[key];
    if (stores == null) return false;
    if (path == null) return true;
    return stores.values.any((target) => target == null || target == path);
  }

  Future<CleanupLease> beginStore(
    String key, {
    String? path,
    bool exclusive = false,
  }) async {
    while (true) {
      final eviction = _evictions[key];
      if (eviction != null) {
        await eviction.future;
        continue;
      }
      final stores = _pendingStores.putIfAbsent(key, () => {});
      // Web commits metadata and bytes to separate boxes.
      if (exclusive && stores.isNotEmpty) {
        await stores.keys.first.future;
        continue;
      }
      final claim = Completer<void>();
      stores[claim] = path;
      return () {
        if (!stores.containsKey(claim)) return;
        stores.remove(claim);
        if (stores.isEmpty) _pendingStores.remove(key);
        claim.complete();
      };
    }
  }

  CleanupLease? beginEviction(String key) {
    if (protects(key) || _evictions.containsKey(key)) return null;
    final eviction = Completer<void>();
    _evictions[key] = eviction;
    return () {
      if (!identical(_evictions[key], eviction)) return;
      _evictions.remove(key);
      if (!eviction.isCompleted) eviction.complete();
    };
  }

  bool isEvicting(String key) => _evictions.containsKey(key);

  Future<CleanupLease> beginPathUse(String path) async {
    final token = Object();
    while (true) {
      final deletion = _pathDeletions[path];
      if (deletion == null) {
        _activePaths.putIfAbsent(path, () => {}).add(token);
        return () => _releasePath(path, token);
      }
      await deletion.future;
    }
  }

  void _releasePath(String path, Object token) {
    final users = _activePaths[path];
    if (users == null) return;
    users.remove(token);
    if (users.isEmpty) _activePaths.remove(path);
  }

  CleanupLease? beginPathDeletion(String path) {
    if (_activePaths.containsKey(path) || _pathDeletions.containsKey(path)) {
      return null;
    }
    final deletion = Completer<void>();
    _pathDeletions[path] = deletion;
    return () {
      if (!identical(_pathDeletions[path], deletion)) return;
      _pathDeletions.remove(path);
      if (!deletion.isCompleted) deletion.complete();
    };
  }

  void scheduleCapacityRetry(
    DateTime now,
    Future<void> Function() retry,
  ) {
    if (!(capacityCleanupEnabled || byteLimitEvictionEnabled) ||
        _recentlyServed.isEmpty) {
      return;
    }
    final retryAt = _recentlyServed.values
        .map((servedAt) => servedAt.add(servedEntryGracePeriod))
        .reduce((a, b) => a.isBefore(b) ? a : b);
    if (_capacityRetryAt case final scheduled?
        when !retryAt.isBefore(scheduled)) {
      return;
    }

    _capacityRetryTimer?.cancel();
    _capacityRetryAt = retryAt;
    final delay = retryAt.difference(now);
    _capacityRetryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _capacityRetryTimer = null;
      _capacityRetryAt = null;
      unawaited(retry());
    });
  }

  void cancelCapacityRetry() {
    _capacityRetryTimer?.cancel();
    _capacityRetryTimer = null;
    _capacityRetryAt = null;
  }

  Future<void> evictOverCapacity({
    required DateTime Function() now,
    required bool Function() isOverCapacity,
    required List<MapEntry<String, CacheEntryMetadata>> Function() candidates,
    required Future<CacheEvictionResult> Function(
      MapEntry<String, CacheEntryMetadata>,
    ) evict,
    required Future<void> Function() retry,
  }) async {
    while (isOverCapacity()) {
      var refresh = false;
      var skippedProtectedEntry = false;
      for (final candidate in candidates()) {
        if (!isOverCapacity()) break;
        if (protects(candidate.key)) {
          skippedProtectedEntry = true;
          continue;
        }
        final result = await evict(candidate);
        if (result == CacheEvictionResult.changed && !protects(candidate.key)) {
          refresh = true;
          break;
        }
      }
      if (refresh) continue;
      if (isOverCapacity() && skippedProtectedEntry) {
        scheduleCapacityRetry(now(), retry);
        return;
      }
      break;
    }
    if (!isOverCapacity()) cancelCapacityRetry();
  }

  /// Runs [sweep], or joins the sweep already in flight.
  ///
  /// A partial pass ([fullSweep] false) cannot stand in for a full sweep, so
  /// a full sweep requested while one is in flight runs, coalesced, right
  /// after it, and the returned future completes only once it has run.
  Future<void> schedule(
    Future<void> Function() sweep,
    bool Function() isOverCapacity, {
    bool capacity = false,
    bool fullSweep = true,
  }) {
    final inFlight = _cleanupFuture;
    if (inFlight != null) {
      if (fullSweep && !_fullSweepInFlight) {
        final queued = _queuedFullSweep ??= _QueuedSweep(sweep, isOverCapacity);
        if (!capacity) queued.capacity = false;
      } else if (capacity && _capacityRetryTimer == null) {
        _capacityCleanupPending = true;
      }
      return inFlight;
    }
    // The retry already covers stores made while candidates are protected.
    if (capacity && _capacityRetryTimer != null) return Future<void>.value();

    late final Future<void> cleanup;
    cleanup = () async {
      var nextSweep = sweep;
      var nextIsOverCapacity = isOverCapacity;
      _fullSweepInFlight = fullSweep;
      while (true) {
        do {
          _capacityCleanupPending = false;
          await nextSweep();
        } while (_capacityCleanupPending &&
            _capacityRetryTimer == null &&
            nextIsOverCapacity());
        final queued = _queuedFullSweep;
        if (queued == null) break;
        _queuedFullSweep = null;
        if (queued.capacity && _capacityRetryTimer != null) break;
        nextSweep = queued.sweep;
        nextIsOverCapacity = queued.isOverCapacity;
        _fullSweepInFlight = true;
      }
    }()
        .whenComplete(() {
      if (identical(_cleanupFuture, cleanup)) {
        _cleanupFuture = null;
        _fullSweepInFlight = false;
      }
    });
    _cleanupFuture = cleanup;
    return cleanup;
  }

  void reset() {
    capacityCleanupEnabled = false;
    byteLimitEvictionEnabled = false;
    _capacityCleanupPending = false;
    _cleanupFuture = null;
    _fullSweepInFlight = false;
    _queuedFullSweep = null;
    cancelCapacityRetry();
    _recentlyServed.clear();
    // Active claims survive manager reuse and release only their own identity.
  }
}

/// A full sweep waiting for the partial pass in flight to finish.
final class _QueuedSweep {
  _QueuedSweep(this.sweep, this.isOverCapacity);

  final Future<void> Function() sweep;
  final bool Function() isOverCapacity;

  /// Whether only capacity requests asked for this sweep.
  bool capacity = true;
}
