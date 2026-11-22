import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_ce/hive.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/hive_impl.dart';
import 'package:http/http.dart' as http;

import 'cache_entry_metadata.dart';
import 'cleanup_coordinator.dart';
import 'cleanup_strategy.dart';
import 'shared_http_client.dart';

export 'cache_entry_metadata.dart';

const _kMetaBoxName = 'cached_network_image_cache';
const _kDataBoxName = 'cached_network_image_data';
const _kDefaultMaxAge = Duration(days: 30);
const _kDefaultMaxCacheObjects = 200;
const _kDefaultStalePeriod = Duration(days: 7);
const _kServedEntryGracePeriod = Duration(seconds: 30);
const _kServedEntryPruneThreshold = 64;

/// Sanitizes a key so it doesn't exceed Hive's 255-character limit for string keys.
String _sanitizeBoxKey(String key) {
  if (key.length <= 255) return key;
  final hash = sha256.convert(utf8.encode(key)).toString();
  // 255 max limit. 255 - 64 (sha256 hex length) - 1 (underscore) = 190
  return '${key.substring(0, 190)}_$hash';
}

/// Web-specific [DefaultCacheManager] that stores both metadata and raw
/// image bytes in Hive boxes (backed by IndexedDB on web).
///
/// Because there is no real file system on the web, cached "files" are
/// materialised as in-memory [File] objects using [MemoryFileSystem].
class DefaultCacheManager extends CacheManager with ImageCacheManager {
  /// Creates a [DefaultCacheManager] for the web platform.
  ///
  /// [stalePeriod] controls how long a cached entry remains valid.
  /// [maxNrOfCacheObjects] caps the number of entries before cleanup.
  /// [maxIdleDuration] removes entries that have not been accessed for that
  /// duration instead of removing entries based on expiry.
  /// [maxCacheSizeInBytes] caps the total size of cached entries. When a
  ///   store pushes the cache over it, entries are evicted in
  ///   [cleanupStrategy] order. Entries handed to callers in the last 30
  ///   seconds are protected, so the cache can briefly exceed the limit until
  ///   they can be evicted. Defaults to null (no byte limit).
  /// [cleanupOnInitialize] can defer cleanup until [startCleanup] is called.
  /// [httpClientFactory] allows injecting a custom HTTP client for testing.
  /// [hiveInstance] allows injecting a pre-initialised Hive instance
  /// (useful for VM tests that need `Hive.init(path)` called first).
  DefaultCacheManager({
    this.stalePeriod = _kDefaultStalePeriod,
    this.maxNrOfCacheObjects = _kDefaultMaxCacheObjects,
    this.maxIdleDuration,
    this.maxCacheSizeInBytes,
    this.cleanupOnInitialize = true,
    this.connectionParameters,
    http.Client Function()? httpClientFactory,
    @visibleForTesting HiveInterface? hiveInstance,
    CleanupStrategy? cleanupStrategy,
  })  : _httpClient = SharedHttpClient(httpClientFactory ?? http.Client.new),
        _hive = hiveInstance ?? HiveImpl(),
        _cleanupStrategy = cleanupStrategy ?? const TtlCleanupStrategy(),
        assert(maxCacheSizeInBytes == null || maxCacheSizeInBytes > 0);

  /// Duration before cached files are considered stale.
  final Duration stalePeriod;

  /// Maximum number of objects in the cache before cleanup.
  final int maxNrOfCacheObjects;

  /// Maximum time an entry may remain unaccessed before cleanup removes it.
  ///
  /// When null, cleanup keeps the legacy expiry-based behavior.
  final Duration? maxIdleDuration;

  /// Maximum total size in bytes of cached entries.
  ///
  /// When null (the default), the cache has no byte limit.
  final int? maxCacheSizeInBytes;

  /// Whether cleanup is enabled during initialization.
  final bool cleanupOnInitialize;

  /// Optional connection parameters for HTTP timeouts.
  ///
  /// When `null` (the default), no timeouts are applied and downloads may
  /// wait indefinitely — preserving the existing behaviour.
  ///
  /// **Note:** On the web platform, timeouts only apply when using
  /// [ImageRenderMethodForWeb.HttpGet]. The [ImageRenderMethodForWeb.HtmlImage]
  /// render path bypasses the cache manager's HTTP layer entirely and is
  /// handled by the browser.
  final ConnectionParameters? connectionParameters;

  final SharedHttpClient _httpClient;

  /// In-memory file system used to materialise cached bytes as [File] objects.
  final MemoryFileSystem _memFs = MemoryFileSystem();

  /// Private Hive instance to avoid conflicts with the host app's Hive usage.
  final HiveInterface _hive;

  final CleanupStrategy _cleanupStrategy;

  Box<Map>? _metaBox;
  LazyBox<List<int>>? _dataBox;
  final _storedVersions = Expando<Object>();

  /// Guards [_doInit] so concurrent callers share one init future.
  Completer<void>? _initCompleter;

  final CleanupCoordinator _cleanup = CleanupCoordinator(
    servedEntryGracePeriod: _kServedEntryGracePeriod,
    servedEntryPruneThreshold: _kServedEntryPruneThreshold,
  );

  Future<void> _ensureInitialized() {
    final currentCompleter = _initCompleter;
    if (currentCompleter != null) return currentCompleter.future;

    final completer = Completer<void>();
    _initCompleter = completer;

    _doInit().then((_) {
      if (!completer.isCompleted) completer.complete();
    }).catchError((Object e, StackTrace s) {
      if (identical(_initCompleter, completer)) _initCompleter = null;
      if (!completer.isCompleted) completer.completeError(e, s);
    });

    return completer.future;
  }

  Future<void> _doInit() async {
    // On web, Hive uses IndexedDB — no path argument needed.
    // We use a private HiveImpl instance to avoid conflicts with the
    // host app's own Hive boxes.
    try {
      _metaBox = await _hive.openBox<Map>(_kMetaBoxName);
      _dataBox = await _hive.openLazyBox<List<int>>(_kDataBoxName);
    } on HiveError catch (e) {
      // Box corruption (e.g. "Cannot read, unknown typeId: 121").
      // Since this is a cache, we can safely delete the corrupted boxes
      // and start fresh. Cached images will simply be re-downloaded.
      cacheLogger.log(
        'CacheManager: Hive box corrupted, resetting cache: $e',
        CacheManagerLogLevel.warning,
      );
      await _safeDeleteBox(_kMetaBoxName);
      await _safeDeleteBox(_kDataBoxName);
      _metaBox = await _hive.openBox<Map>(_kMetaBoxName);
      _dataBox = await _hive.openLazyBox<List<int>>(_kDataBoxName);
    }
    _cleanup.byteLimitEvictionEnabled = maxCacheSizeInBytes != null;

    if (cleanupOnInitialize) {
      unawaited(_scheduleCleanup());
    }
  }

  /// Attempts to delete a Hive box from disk, tolerating missing files.
  ///
  /// [HiveImpl.deleteBoxFromDisk] can throw [PathNotFoundException] when
  /// auxiliary files (e.g. `.lock`) are already gone. We swallow the error
  /// since we're already in a corruption-recovery path.
  Future<void> _safeDeleteBox(String boxName) async {
    try {
      await _hive.deleteBoxFromDisk(boxName);
    } on Object catch (_) {
      // Best-effort: if the box files are already gone, that's fine.
    }
  }

  /// Gets the file extension from a URL.
  String _getFileExtensionFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final pathSegment =
          uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
      if (pathSegment.contains('.')) {
        return pathSegment.split('.').last.toLowerCase();
      }
    } on Object catch (_) {
      // Ignore parse errors
    }
    return 'file';
  }

  /// Materialises raw [bytes] as an in-memory [File].
  File _bytesToFile(String relativePath, List<int> bytes) {
    final file = _memFs.file('/$relativePath');
    file.writeAsBytesSync(bytes);
    return file;
  }

  // ---------------------------------------------------------------
  // BaseCacheManager
  // ---------------------------------------------------------------

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    final controller = StreamController<FileResponse>();
    _pushFileToStream(controller, url, key ?? url, headers, withProgress);
    return controller.stream;
  }

  Future<void> _pushFileToStream(
    StreamController<FileResponse> controller,
    String url,
    String key,
    Map<String, String>? headers,
    bool withProgress,
  ) async {
    try {
      await _ensureInitialized();
    } on Object catch (e, stackTrace) {
      if (controller.hasListener) {
        controller.addError(e, stackTrace);
      }
      await controller.close();
      return;
    }

    FileInfo? cachedFile;
    try {
      cachedFile = await getFileFromCache(key);
      if (cachedFile != null) {
        controller.add(cachedFile);
        withProgress = false;
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to load cached file for $url with error:\n$e',
        CacheManagerLogLevel.debug,
      );
    }

    if (cachedFile == null || cachedFile.validTill.isBefore(clock.now())) {
      try {
        await for (final response
            in _downloadFile(url, key, headers, withProgress)) {
          if (response is DownloadProgress && withProgress) {
            controller.add(response);
          }
          if (response is FileInfo) {
            controller.add(response);
          }
        }
      } on Object catch (e) {
        cacheLogger.log(
          'CacheManager: Failed to download file from $url with error:\n$e',
          CacheManagerLogLevel.debug,
        );
        if (cachedFile == null && controller.hasListener) {
          controller.addError(e);
        }
        if (cachedFile != null &&
            e is HttpExceptionWithStatus &&
            e.statusCode == 404) {
          if (controller.hasListener) {
            controller.addError(e);
          }
          await removeFile(key);
        }
      }
    }
    await controller.close();
  }

  Stream<FileResponse> _downloadFile(
    String url,
    String key,
    Map<String, String>? headers,
    bool withProgress,
  ) async* {
    cacheLogger.log(
      'CacheManager: Downloading $url',
      CacheManagerLogLevel.verbose,
    );

    SharedHttpClientResponse? clientResponse;
    try {
      clientResponse = await _httpClient.send(
        uri: Uri.parse(url),
        headers: headers,
        connectionTimeout: connectionParameters?.connectionTimeout,
      );
      final response = clientResponse.response;

      if (response.statusCode != 200 && response.statusCode != 202) {
        throw HttpExceptionWithStatus(
          response.statusCode,
          'Invalid statusCode: ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }

      final contentLength = response.contentLength;
      final allBytes = <int>[];
      var receivedBytes = 0;

      final requestTimeout = connectionParameters?.requestTimeout;
      final stream = requestTimeout != null
          ? response.stream.timeout(requestTimeout)
          : response.stream;

      await for (final chunk in stream) {
        receivedBytes += chunk.length;
        allBytes.addAll(chunk);
        if (withProgress) {
          yield DownloadProgress(url, contentLength, receivedBytes);
        }
      }

      // Store metadata + data in Hive.
      final validTill = clock.now().add(stalePeriod);
      final cacheHeaders = response.headers;
      final eTag = cacheHeaders['etag'];
      final fileExtension = _getFileExtensionFromUrl(url);
      final relativePath =
          '${key.hashCode.toUnsigned(32).toRadixString(16)}.$fileExtension';
      final file = await _storeFile(
        _sanitizeBoxKey(key),
        CacheEntryMetadata(
          url: url,
          relativePath: relativePath,
          validTill: validTill,
          eTag: eTag,
          length: receivedBytes,
        ),
        allBytes,
      );
      yield FileInfo(file, FileSource.Online, validTill, url);
    } finally {
      clientResponse?.release();
    }
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    await _ensureInitialized();

    final sanitizedKey = _sanitizeBoxKey(key);
    if (_cleanup.isEvicting(sanitizedKey) || _cleanup.isStoring(sanitizedKey)) {
      return null;
    }

    final metaBox = _metaBox!;
    final dataBox = _dataBox!;
    final raw = metaBox.get(sanitizedKey);
    if (raw == null) return null;

    final metadata = CacheEntryMetadata.fromMap(raw);
    final version = _storedVersions[raw] ??= Object();

    final bytes = await dataBox.get(sanitizedKey);
    if (!metaBox.isOpen ||
        _cleanup.isEvicting(sanitizedKey) ||
        _cleanup.isStoring(sanitizedKey)) {
      return null;
    }
    final current = metaBox.get(sanitizedKey);
    if (current == null || !identical(version, _storedVersions[current])) {
      return null;
    }
    if (bytes == null) {
      // The lazy read may have started before a replacement finished.
      if (!dataBox.containsKey(sanitizedKey)) {
        await metaBox.delete(sanitizedKey);
      }
      return null;
    }

    final file = _bytesToFile(metadata.relativePath, bytes);
    _markServed(sanitizedKey);
    unawaited(_touchEntry(sanitizedKey));
    return FileInfo(
      file,
      FileSource.Cache,
      metadata.validTill,
      metadata.url,
    );
  }

  @override
  Future<File> putFile(
    String url,
    List<int> fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = _kDefaultMaxAge,
    String fileExtension = 'file',
  }) async {
    await _ensureInitialized();

    key ??= url;
    final relativePath =
        '${key.hashCode.toUnsigned(32).toRadixString(16)}.$fileExtension';
    return _storeFile(
      _sanitizeBoxKey(key),
      CacheEntryMetadata(
        url: url,
        relativePath: relativePath,
        validTill: clock.now().add(maxAge),
        eTag: eTag,
        length: fileBytes.length,
      ),
      fileBytes,
    );
  }

  Future<File> _storeFile(
    String key,
    CacheEntryMetadata metadata,
    List<int> bytes,
  ) async {
    final metaBox = _metaBox!;
    final dataBox = _dataBox!;
    final releaseStore = await _cleanup.beginStore(key, exclusive: true);
    try {
      final previousPath = metaBox.get(key)?['relativePath'];
      if (_exceedsByteLimit(metadata.length)) {
        // Delivered but not cached; it replaces any entry stored for [key].
        await _deleteEntry(
          metaBox,
          dataBox,
          key,
          previousPath is String ? previousPath : null,
        );
        // A throwaway file system keeps the bytes only while the caller
        // holds the file.
        return MemoryFileSystem().file('/${metadata.relativePath}')
          ..writeAsBytesSync(bytes);
      }
      final stored = metadata.toMap()
        ..['touchedAt'] = clock.now().millisecondsSinceEpoch;
      try {
        await metaBox.put(key, stored);
        await dataBox.put(key, bytes);
      } on Object catch (_) {
        // A failed overwrite must not pair the new metadata with old bytes.
        for (final box in <BoxBase<dynamic>>[metaBox, dataBox]) {
          try {
            await box.delete(key);
          } on Object catch (e) {
            cacheLogger.log(
              'CacheManager: Failed to discard incomplete store for $key: $e',
              CacheManagerLogLevel.warning,
            );
          }
        }
        if (previousPath is String) {
          _deleteMaterializedFile(key, previousPath);
        }
        rethrow;
      }
      _markServed(key);
      return _bytesToFile(metadata.relativePath, bytes);
    } finally {
      releaseStore();
      _scheduleCapacityCleanup();
    }
  }

  @override
  Future<void> removeFile(String key) async {
    await _ensureInitialized();
    final sanitizedKey = _sanitizeBoxKey(key);
    final metaBox = _metaBox!;
    final dataBox = _dataBox!;
    final releaseRemoval =
        await _cleanup.beginStore(sanitizedKey, exclusive: true);
    try {
      final raw = metaBox.get(sanitizedKey);
      final relativePath =
          raw == null ? null : CacheEntryMetadata.fromMap(raw).relativePath;
      await _deleteEntry(metaBox, dataBox, sanitizedKey, relativePath);
    } finally {
      releaseRemoval();
      _scheduleCapacityCleanup();
    }
  }

  Future<void> _deleteEntry(
    Box<Map> metaBox,
    LazyBox<List<int>> dataBox,
    String key,
    String? relativePath,
  ) async {
    await dataBox.delete(key);
    if (relativePath != null) {
      _deleteMaterializedFile(key, relativePath);
    }
    await metaBox.delete(key);
  }

  void _deleteMaterializedFile(String key, String relativePath) {
    try {
      final file = _memFs.file('/$relativePath');
      if (file.existsSync()) file.deleteSync();
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error deleting materialized file for $key: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  @override
  Future<void> emptyCache() async {
    await _ensureInitialized();
    for (final raw in _metaBox!.values) {
      final metadata = CacheEntryMetadata.fromMap(raw);
      try {
        final file = _memFs.file('/${metadata.relativePath}');
        if (file.existsSync()) {
          await file.delete();
        }
      } on Object catch (e) {
        cacheLogger.log(
          'CacheManager: Error deleting materialized file during emptyCache: $e',
          CacheManagerLogLevel.warning,
        );
      }
    }
    await _metaBox!.clear();
    await _dataBox!.clear();
  }

  /// Returns the total size in bytes of the images stored in IndexedDB.
  ///
  /// Counts only entries tracked by the cache, not Flutter's in-memory
  /// [ImageCache]. Returns 0 when the cache is empty.
  Future<int> getCacheSize() async {
    await _ensureInitialized();
    final metaBox = _metaBox!;
    final dataBox = _dataBox!;
    var total = 0;
    for (final key in metaBox.keys) {
      // Ignore incomplete entries without stored bytes.
      if (!dataBox.containsKey(key)) continue;
      try {
        total += CacheEntryMetadata.fromMap(metaBox.get(key)!).length;
      } on Object catch (_) {
        // Malformed entry: never served from the cache, so not counted.
      }
    }
    return total;
  }

  @override
  Future<void> dispose() async {
    _cleanup.capacityCleanupEnabled = false;
    _cleanup.byteLimitEvictionEnabled = false;
    _cleanup.cancelCapacityRetry();
    final inFlightInit = _initCompleter;
    if (inFlightInit != null) {
      try {
        await inFlightInit.future;
      } on Object catch (_) {
        // Ignore init errors during dispose.
      }
    }

    final inFlightCleanup = _cleanup.cleanupFuture;
    if (inFlightCleanup != null) {
      try {
        await inFlightCleanup;
      } on Object catch (_) {
        // Already logged inside _cleanupOldEntries; ignore here.
      }
    }

    _httpClient.dispose();

    if (_metaBox != null && _metaBox!.isOpen) {
      await _metaBox!.close();
    }
    if (_dataBox != null && _dataBox!.isOpen) {
      await _dataBox!.close();
    }

    _metaBox = null;
    _dataBox = null;
    _initCompleter = null;
    _cleanup.reset();
  }

  /// Runs the eviction sweep synchronously, for tests that need to observe
  /// its result without racing the unawaited sweep started by [_doInit].
  @visibleForTesting
  Future<void> debugRunCleanup() async {
    await _ensureInitialized();
    await _scheduleCleanup();
  }

  /// Enables cleanup and waits for one cleanup sweep to finish.
  ///
  /// Concurrent calls share the same in-flight sweep. Once enabled, cleanup
  /// remains enabled and stores above [maxNrOfCacheObjects] schedule a
  /// coalesced background sweep.
  Future<void> startCleanup() async {
    await _ensureInitialized();
    _cleanup.capacityCleanupEnabled = true;
    await _scheduleCleanup();
  }

  Future<void> _scheduleCleanup({bool capacity = false}) {
    return _cleanup.schedule(
      _cleanupOldEntries,
      _isOverCapacity,
      capacity: capacity,
    );
  }

  /// Only a store above [maxNrOfCacheObjects] needs the full sweep; byte
  /// overflow alone is handled by the lighter byte pass.
  void _scheduleCapacityCleanup() {
    if (_cleanup.capacityCleanupEnabled && _isOverCount()) {
      unawaited(_scheduleCleanup(capacity: true));
    } else if (_isOverByteLimit()) {
      unawaited(_scheduleByteLimitEviction());
    }
  }

  /// Retries capacity eviction once protected entries become evictable,
  /// choosing the pass the same way as [_scheduleCapacityCleanup].
  Future<void> _retryCapacityCleanup() =>
      _cleanup.capacityCleanupEnabled && _isOverCount()
          ? _scheduleCleanup(capacity: true)
          : _scheduleByteLimitEviction();

  Future<void> _scheduleByteLimitEviction() {
    return _cleanup.schedule(
      _evictOverByteLimit,
      _isOverByteLimit,
      capacity: true,
      fullSweep: false,
    );
  }

  bool _isOverCapacity() => _isOverCount() || _isOverByteLimit();

  bool _isOverCount() {
    final box = _metaBox;
    try {
      return box != null && box.isOpen && box.length > maxNrOfCacheObjects;
    } on Object catch (_) {
      return false;
    }
  }

  bool _exceedsByteLimit(int length) {
    final limit = maxCacheSizeInBytes;
    return limit != null && length > limit;
  }

  bool _isOverByteLimit() {
    final limit = maxCacheSizeInBytes;
    if (limit == null) return false;
    try {
      return _cachedBytes() > limit;
    } on Object catch (_) {
      return false;
    }
  }

  /// Sum of the stored lengths of all entries. Entries without a length
  /// count as zero bytes.
  int _cachedBytes() {
    final box = _metaBox;
    if (box == null || !box.isOpen) return 0;
    var total = 0;
    for (final raw in box.values) {
      total += raw['length'] as int? ?? 0;
    }
    return total;
  }

  /// Evicts entries in strategy order until the cache fits the byte limit.
  ///
  /// Unlike [_cleanupOldEntries], this skips the expiry sweep and does not
  /// enforce [maxNrOfCacheObjects].
  Future<void> _evictOverByteLimit() async {
    try {
      _cleanup.pruneRecentlyServed(clock.now());
      await _cleanup.evictOverCapacity(
        now: clock.now,
        isOverCapacity: _isOverByteLimit,
        candidates: () => _cleanupStrategy.sortForEviction(_snapshotEntries()),
        evict: _evictEntry,
        retry: _retryCapacityCleanup,
      );
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error during byte limit eviction: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  bool _isSweepable(CacheEntryMetadata metadata, DateTime now) {
    final idleDuration = maxIdleDuration;
    if (idleDuration == null) return metadata.validTill.isBefore(now);
    return now.difference(metadata.effectiveTouchedAt) >= idleDuration;
  }

  void _markServed(String key) {
    _cleanup.markServed(key, clock.now());
  }

  /// Whether the shared in-memory file system holds a file at [path].
  /// Test-only.
  @visibleForTesting
  bool debugIsMaterialized(String path) => _memFs.file(path).existsSync();

  /// Number of entries currently protected from eviction. Test-only.
  @visibleForTesting
  int get debugRecentlyServedCount => _cleanup.recentlyServedCount;

  Future<void> _touchEntry(String key) async {
    final box = _metaBox;
    if (box == null || !box.isOpen) return;
    try {
      final raw = box.get(key);
      if (raw == null) return;
      final current = CacheEntryMetadata.fromMap(raw);
      final updated = CacheEntryMetadata(
        url: current.url,
        relativePath: current.relativePath,
        validTill: current.validTill,
        eTag: current.eTag,
        length: current.length,
        touchedAt: clock.now(),
      ).toMap();
      // Access-time updates preserve the version of the stored bytes.
      _storedVersions[updated] = _storedVersions[raw] ??= Object();
      await box.put(key, updated);
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to update touchedAt for $key: $e',
        CacheManagerLogLevel.debug,
      );
    }
  }

  /// Clean up entries that have expired.
  Future<void> _cleanupOldEntries() async {
    try {
      final now = clock.now();
      _cleanup.pruneRecentlyServed(now);
      final entries = _snapshotEntries();

      // Remove expired entries.
      for (final entry in entries) {
        if (_isSweepable(entry.value, now) && !_cleanup.protects(entry.key)) {
          await _evictEntry(entry);
        }
      }

      await _cleanup.evictOverCapacity(
        now: clock.now,
        isOverCapacity: _isOverCapacity,
        candidates: () => _cleanupStrategy.sortForEviction(_snapshotEntries()),
        evict: _evictEntry,
        retry: _retryCapacityCleanup,
      );
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error during cleanup: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  Future<CacheEvictionResult> _evictEntry(
    MapEntry<String, CacheEntryMetadata> entry,
  ) async {
    final releaseEviction = _cleanup.beginEviction(entry.key);
    if (releaseEviction == null) return CacheEvictionResult.skipped;
    try {
      final box = _metaBox;
      if (box == null || !box.isOpen) return CacheEvictionResult.skipped;
      final raw = box.get(entry.key);
      if (raw == null) return CacheEvictionResult.changed;
      final current = _legacyAwareMetadata(CacheEntryMetadata.fromMap(raw));
      if (!_sameMetadata(current, entry.value)) {
        return CacheEvictionResult.changed;
      }
      await _deleteEntry(box, _dataBox!, entry.key, current.relativePath);
      return CacheEvictionResult.removed;
    } finally {
      releaseEviction();
    }
  }

  List<MapEntry<String, CacheEntryMetadata>> _snapshotEntries() => [
        for (final key in _metaBox!.keys)
          MapEntry(
            key as String,
            _legacyAwareMetadata(
              CacheEntryMetadata.fromMap(_metaBox!.get(key)!),
            ),
          ),
      ];

  CacheEntryMetadata _legacyAwareMetadata(CacheEntryMetadata metadata) =>
      metadata.touchedAt == null
          ? CacheEntryMetadata(
              url: metadata.url,
              relativePath: metadata.relativePath,
              validTill: metadata.validTill,
              eTag: metadata.eTag,
              length: metadata.length,
              touchedAt: DateTime.fromMillisecondsSinceEpoch(0),
            )
          : metadata;

  bool _sameMetadata(CacheEntryMetadata a, CacheEntryMetadata b) =>
      a.url == b.url &&
      a.relativePath == b.relativePath &&
      a.validTill == b.validTill &&
      a.eTag == b.eTag &&
      a.length == b.length &&
      a.touchedAt == b.touchedAt;

  // ---------------------------------------------------------------
  // ImageCacheManager
  // ---------------------------------------------------------------

  final Map<String, Stream<FileResponse>> _runningResizes = {};

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) async* {
    // On web, we don't support disk-based image resizing.
    // Just forward to getFileStream.
    if (maxHeight == null && maxWidth == null) {
      yield* getFileStream(
        url,
        key: key,
        headers: headers,
        withProgress: withProgress,
      );
      return;
    }

    key ??= url;
    var resizedKey = 'resized';
    if (maxWidth != null) resizedKey += '_w$maxWidth';
    if (maxHeight != null) resizedKey += '_h$maxHeight';
    resizedKey += '_$key';

    final fromCache = await getFileFromCache(resizedKey);
    if (fromCache != null) {
      yield fromCache;
      if (fromCache.validTill.isAfter(clock.now())) {
        return;
      }
      withProgress = false;
    }

    // On web we can't resize images on disk, so we store the original
    // under the resized key so that the cache-key system still works.
    var runningResize = _runningResizes[resizedKey];
    if (runningResize == null) {
      runningResize = _fetchAndStoreAsResized(
        url,
        key,
        resizedKey,
        headers,
        withProgress,
      ).asBroadcastStream();
      _runningResizes[resizedKey] = runningResize;
    }
    try {
      yield* runningResize;
    } finally {
      if (_runningResizes[resizedKey] == runningResize) {
        _runningResizes.remove(resizedKey);
      }
    }
  }

  Stream<FileResponse> _fetchAndStoreAsResized(
    String url,
    String originalKey,
    String resizedKey,
    Map<String, String>? headers,
    bool withProgress,
  ) async* {
    await for (final response in getFileStream(
      url,
      key: originalKey,
      headers: headers,
      withProgress: withProgress,
    )) {
      if (response is DownloadProgress) {
        yield response;
      }
      if (response is FileInfo) {
        // Store the original bytes under the resized key.
        final bytes = await response.file.readAsBytes();
        final file = await putFile(
          url,
          bytes,
          key: resizedKey,
          maxAge: response.validTill.difference(clock.now()),
        );
        yield FileInfo(
          file,
          response.source,
          response.validTill,
          response.originalUrl,
        );
      }
    }
  }
}
