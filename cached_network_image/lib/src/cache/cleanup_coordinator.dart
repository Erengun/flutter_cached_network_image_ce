/// Coordinates cleanup sweeps and protects entries recently handed to callers.
final class CleanupCoordinator {
  CleanupCoordinator({
    required this.servedEntryGracePeriod,
    required this.servedEntryPruneThreshold,
  });

  final Duration servedEntryGracePeriod;
  final int servedEntryPruneThreshold;

  final Map<String, DateTime> _recentlyServed = {};
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

  bool protects(String key) => _recentlyServed.containsKey(key);

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
  }
}
