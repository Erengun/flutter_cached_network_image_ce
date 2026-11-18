import 'dart:async';

/// Coordinates cleanup sweeps and protects entries recently handed to callers.
final class CleanupCoordinator {
  CleanupCoordinator({
    required this.servedEntryGracePeriod,
    required this.servedEntryPruneThreshold,
  });

  final Duration servedEntryGracePeriod;
  final int servedEntryPruneThreshold;

  final Map<String, DateTime> _recentlyServed = {};
  final Map<String, int> _pendingStores = {};
  final Map<String, Completer<void>> _evictions = {};
  Future<void>? _cleanupFuture;
  bool _capacityCleanupPending = false;

  bool capacityCleanupEnabled = false;

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

  Future<void> beginStore(String key) async {
    while (true) {
      final eviction = _evictions[key];
      if (eviction == null) {
        _pendingStores.update(key, (count) => count + 1, ifAbsent: () => 1);
        return;
      }
      await eviction.future;
    }
  }

  void endStore(String key) {
    final count = _pendingStores[key];
    if (count == null || count == 1) {
      _pendingStores.remove(key);
    } else {
      _pendingStores[key] = count - 1;
    }
  }

  bool beginEviction(String key) {
    if (protects(key) || _evictions.containsKey(key)) return false;
    _evictions[key] = Completer<void>();
    return true;
  }

  bool isEvicting(String key) => _evictions.containsKey(key);

  void endEviction(String key) {
    final eviction = _evictions.remove(key);
    if (eviction != null && !eviction.isCompleted) eviction.complete();
  }

  Future<void> schedule(
    Future<void> Function() sweep,
    bool Function() isOverCapacity, {
    bool capacity = false,
  }) {
    final inFlight = _cleanupFuture;
    if (inFlight != null) {
      if (capacity) _capacityCleanupPending = true;
      return inFlight;
    }

    late final Future<void> cleanup;
    cleanup = () async {
      do {
        _capacityCleanupPending = false;
        await sweep();
      } while (_capacityCleanupPending && isOverCapacity());
    }()
        .whenComplete(() {
      if (identical(_cleanupFuture, cleanup)) {
        _cleanupFuture = null;
      }
    });
    _cleanupFuture = cleanup;
    return cleanup;
  }

  void reset() {
    capacityCleanupEnabled = false;
    _capacityCleanupPending = false;
    _cleanupFuture = null;
    _recentlyServed.clear();
    _pendingStores.clear();
    for (final eviction in _evictions.values) {
      if (!eviction.isCompleted) eviction.complete();
    }
    _evictions.clear();
  }
}
