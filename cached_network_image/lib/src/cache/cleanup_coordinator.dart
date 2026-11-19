import 'dart:async';

typedef CleanupLease = void Function();

/// Coordinates cleanup sweeps and protects entries recently handed to callers.
final class CleanupCoordinator {
  CleanupCoordinator({
    required this.servedEntryGracePeriod,
    required this.servedEntryPruneThreshold,
  });

  final Duration servedEntryGracePeriod;
  final int servedEntryPruneThreshold;

  final Map<String, DateTime> _recentlyServed = {};
  final Map<String, Map<Object, String?>> _pendingStores = {};
  final Map<String, Completer<void>> _evictions = {};
  final Map<String, Set<Object>> _activePaths = {};
  final Map<String, Completer<void>> _pathDeletions = {};
  Future<void>? _cleanupFuture;
  Timer? _capacityRetryTimer;
  DateTime? _capacityRetryAt;
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

  bool isStoring(String key, {String? path}) {
    final stores = _pendingStores[key];
    if (stores == null) return false;
    if (path == null) return true;
    return stores.values.any((target) => target == null || target == path);
  }

  Future<CleanupLease> beginStore(String key, {String? path}) async {
    final token = Object();
    while (true) {
      final eviction = _evictions[key];
      if (eviction == null) {
        _pendingStores.putIfAbsent(key, () => {})[token] = path;
        return () => _releaseStore(key, token);
      }
      await eviction.future;
    }
  }

  void _releaseStore(String key, Object token) {
    final stores = _pendingStores[key];
    if (stores == null) return;
    stores.remove(token);
    if (stores.isEmpty) _pendingStores.remove(key);
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
    if (!capacityCleanupEnabled || _recentlyServed.isEmpty) return;
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
    cancelCapacityRetry();
    _recentlyServed.clear();
    // Active claims survive manager reuse and release only their own identity.
  }
}
