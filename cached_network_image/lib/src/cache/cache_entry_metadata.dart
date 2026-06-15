/// Typed metadata for a cached file entry, stored in Hive.
class CacheEntryMetadata {
  CacheEntryMetadata({
    required this.url,
    required this.relativePath,
    required this.validTill,
    this.eTag,
    this.length = 0,
    this.touchedAt,
  });

  /// Reconstructs a [CacheEntryMetadata] from a Hive-stored [Map].
  factory CacheEntryMetadata.fromMap(Map map) {
    final touchedAtMs = map['touchedAt'] as int?;
    return CacheEntryMetadata(
      url: map['url'] as String,
      relativePath: map['relativePath'] as String,
      validTill: DateTime.fromMillisecondsSinceEpoch(map['validTill'] as int),
      eTag: map['eTag'] as String?,
      length: (map['length'] as int?) ?? 0,
      touchedAt: touchedAtMs != null
          ? DateTime.fromMillisecondsSinceEpoch(touchedAtMs)
          : null,
    );
  }

  /// The original download URL.
  final String url;

  /// The path of the cached file relative to the cache directory.
  final String relativePath;

  /// When this cache entry expires.
  final DateTime validTill;

  /// The HTTP ETag for revalidation, if any.
  final String? eTag;

  /// The size of the cached file in bytes.
  final int length;

  /// When this entry was last written or explicitly accessed.
  ///
  /// Null for entries created before this field was introduced.
  final DateTime? touchedAt;

  /// Returns [touchedAt] if set, otherwise falls back to [validTill].
  DateTime get effectiveTouchedAt => touchedAt ?? validTill;

  /// Serializes this metadata to a [Map] for Hive storage.
  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'relativePath': relativePath,
      'validTill': validTill.millisecondsSinceEpoch,
      'eTag': eTag,
      'length': length,
      if (touchedAt != null) 'touchedAt': touchedAt!.millisecondsSinceEpoch,
    };
  }
}
