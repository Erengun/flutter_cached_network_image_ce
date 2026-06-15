import 'cache_entry_metadata.dart';

/// Defines the order in which cache entries are evicted when the cache
/// exceeds [DefaultCacheManager.maxNrOfCacheObjects].
///
/// Implement this class to provide a custom eviction policy. The first
/// entries in the returned list will be evicted first.
abstract class CleanupStrategy {
  const CleanupStrategy();

  /// Sorts [entries] so that the entries to evict first appear at the
  /// beginning of the returned list.
  ///
  /// Implementations may sort [entries] in-place and return the same list,
  /// or return a new sorted list. The caller uses the returned list to
  /// determine eviction order.
  List<MapEntry<String, CacheEntryMetadata>> sortForEviction(
    List<MapEntry<String, CacheEntryMetadata>> entries,
  );
}

/// Evicts entries with the earliest expiry date first (TTL-based).
///
/// This matches the original [DefaultCacheManager] behaviour and is the
/// default strategy when no [CleanupStrategy] is provided.
final class TtlCleanupStrategy extends CleanupStrategy {
  const TtlCleanupStrategy();

  @override
  List<MapEntry<String, CacheEntryMetadata>> sortForEviction(
    List<MapEntry<String, CacheEntryMetadata>> entries,
  ) {
    return entries
      ..sort((a, b) => a.value.validTill.compareTo(b.value.validTill));
  }
}

/// Evicts least-recently-used entries first (LRU-based).
///
/// Uses [CacheEntryMetadata.effectiveTouchedAt] as the access timestamp,
/// which falls back to [CacheEntryMetadata.validTill] for legacy entries
/// that pre-date the [touchedAt] field.
final class LruCleanupStrategy extends CleanupStrategy {
  const LruCleanupStrategy();

  @override
  List<MapEntry<String, CacheEntryMetadata>> sortForEviction(
    List<MapEntry<String, CacheEntryMetadata>> entries,
  ) {
    return entries
      ..sort(
        (a, b) => a.value.effectiveTouchedAt.compareTo(
          b.value.effectiveTouchedAt,
        ),
      );
  }
}
