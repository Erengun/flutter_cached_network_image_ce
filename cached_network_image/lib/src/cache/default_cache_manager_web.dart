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
  /// [cleanupOnInitialize] can defer cleanup until [startCleanup] is called.
  /// [httpClientFactory] allows injecting a custom HTTP client for testing.
  /// [hiveInstance] allows injecting a pre-initialised Hive instance
  /// (useful for VM tests that need `Hive.init(path)` called first).
  DefaultCacheManager({
    this.stalePeriod = _kDefaultStalePeriod,
    this.maxNrOfCacheObjects = _kDefaultMaxCacheObjects,
    this.maxIdleDuration,
    this.cleanupOnInitialize = true,
    this.connectionParameters,
    http.Client Function()? httpClientFactory,
    @visibleForTesting HiveInterface? hiveInstance,
    CleanupStrategy? cleanupStrategy,
  })  : _httpClient = SharedHttpClient(httpClientFactory ?? http.Client.new),
        _hive = hiveInstance ?? HiveImpl(),
        _cleanupEnabled = cleanupOnInitialize,
        _cleanupStrategy = cleanupStrategy ?? const TtlCleanupStrategy();

  /// Duration before cached files are considered stale.
  final Duration stalePeriod;

  /// Maximum number of objects in the cache before cleanup.
  final int maxNrOfCacheObjects;

  /// Maximum time an entry may remain unaccessed before cleanup removes it.
  ///
  /// When null, cleanup keeps the legacy expiry-based behavior.
  final Duration? maxIdleDuration;

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

  /// Guards [_doInit] so concurrent callers share one init future.
  Completer<void>? _initCompleter;

  Future<void>? _cleanupFuture;

  bool _cleanupEnabled;
  bool _capacityCleanupPending = false;

  final Map<String, DateTime> _recentlyServed = {};

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

    if (_cleanupEnabled) {
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
      final sanitizedKey = _sanitizeBoxKey(key);
      _markServed(sanitizedKey);

      await _metaBox!.put(
        sanitizedKey,
        CacheEntryMetadata(
          url: url,
          relativePath: relativePath,
          validTill: validTill,
          eTag: eTag,
          length: receivedBytes,
          touchedAt: clock.now(),
        ).toMap(),
      );
      await _dataBox!.put(sanitizedKey, allBytes);
      _scheduleCapacityCleanup();

      final file = _bytesToFile(relativePath, allBytes);
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

    final raw = _metaBox!.get(_sanitizeBoxKey(key));
    if (raw == null) return null;

    final metadata = CacheEntryMetadata.fromMap(raw);

    final bytes = await _dataBox!.get(_sanitizeBoxKey(key));
    if (bytes == null) {
      // Metadata exists but data is missing — clean up.
      await _metaBox!.delete(_sanitizeBoxKey(key));
      return null;
    }

    final sanitizedKey = _sanitizeBoxKey(key);
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
    final validTill = clock.now().add(maxAge);
    final sanitizedKey = _sanitizeBoxKey(key);
    _markServed(sanitizedKey);

    await _metaBox!.put(
      sanitizedKey,
      CacheEntryMetadata(
        url: url,
        relativePath: relativePath,
        validTill: validTill,
        eTag: eTag,
        length: fileBytes.length,
        touchedAt: clock.now(),
      ).toMap(),
    );
    await _dataBox!.put(sanitizedKey, fileBytes);
    _scheduleCapacityCleanup();

    return _bytesToFile(relativePath, fileBytes);
  }

  @override
  Future<void> removeFile(String key) async {
    await _ensureInitialized();
    final raw = _metaBox!.get(_sanitizeBoxKey(key));
    if (raw != null) {
      final metadata = CacheEntryMetadata.fromMap(raw);
      try {
        final file = _memFs.file('/${metadata.relativePath}');
        if (file.existsSync()) {
          await file.delete();
        }
      } on Object catch (e) {
        cacheLogger.log(
          'CacheManager: Error deleting materialized file for $key: $e',
          CacheManagerLogLevel.warning,
        );
      }
    }
    await _metaBox!.delete(_sanitizeBoxKey(key));
    await _dataBox!.delete(_sanitizeBoxKey(key));
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

  @override
  Future<void> dispose() async {
    final inFlightInit = _initCompleter;
    if (inFlightInit != null) {
      try {
        await inFlightInit.future;
      } on Object catch (_) {
        // Ignore init errors during dispose.
      }
    }

    final inFlightCleanup = _cleanupFuture;
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
    _cleanupFuture = null;
    _recentlyServed.clear();
  }

  /// Enables cleanup and waits for one cleanup sweep to finish.
  ///
  /// Concurrent calls share the same in-flight sweep. Once enabled, cleanup
  /// remains enabled and stores above [maxNrOfCacheObjects] schedule a
  /// coalesced background sweep.
  Future<void> startCleanup() async {
    await _ensureInitialized();
    _cleanupEnabled = true;
    await _scheduleCleanup();
  }

  Future<void> _scheduleCleanup({bool capacity = false}) {
    final inFlight = _cleanupFuture;
    if (inFlight != null) {
      if (capacity) _capacityCleanupPending = true;
      return inFlight;
    }

    late final Future<void> cleanup;
    cleanup = () async {
      do {
        _capacityCleanupPending = false;
        await _cleanupOldEntries();
      } while (
          _capacityCleanupPending && _metaBox!.length > maxNrOfCacheObjects);
    }()
        .whenComplete(() {
      if (identical(_cleanupFuture, cleanup)) {
        _cleanupFuture = null;
      }
    });
    _cleanupFuture = cleanup;
    return cleanup;
  }

  void _scheduleCapacityCleanup() {
    if (_cleanupEnabled && _metaBox!.length > maxNrOfCacheObjects) {
      unawaited(_scheduleCleanup(capacity: true));
    }
  }

  bool _isSweepable(CacheEntryMetadata metadata, DateTime now) {
    final idleDuration = maxIdleDuration;
    if (idleDuration == null) return metadata.validTill.isBefore(now);
    return now.difference(metadata.effectiveTouchedAt) >= idleDuration;
  }

  void _markServed(String key) {
    final now = clock.now();
    _recentlyServed[key] = now;
    if (_recentlyServed.length > _kServedEntryPruneThreshold) {
      _pruneRecentlyServed(now);
    }
  }

  void _pruneRecentlyServed(DateTime now) {
    _recentlyServed.removeWhere(
      (_, servedAt) => now.difference(servedAt) >= _kServedEntryGracePeriod,
    );
  }

  /// Number of entries currently protected from eviction. Test-only.
  @visibleForTesting
  int get debugRecentlyServedCount => _recentlyServed.length;

  Future<void> _touchEntry(String key) async {
    final box = _metaBox;
    if (box == null || !box.isOpen) return;
    try {
      final raw = box.get(key);
      if (raw == null) return;
      final current = CacheEntryMetadata.fromMap(raw);
      await box.put(
        key,
        CacheEntryMetadata(
          url: current.url,
          relativePath: current.relativePath,
          validTill: current.validTill,
          eTag: current.eTag,
          length: current.length,
          touchedAt: clock.now(),
        ).toMap(),
      );
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
      _pruneRecentlyServed(now);
      final entries = <MapEntry<String, CacheEntryMetadata>>[];

      for (final key in _metaBox!.keys.toList()) {
        final raw = _metaBox!.get(key);
        if (raw != null) {
          entries.add(MapEntry(key as String, CacheEntryMetadata.fromMap(raw)));
        }
      }

      // Remove expired entries.
      for (final entry in entries) {
        if (_isSweepable(entry.value, now) &&
            !_recentlyServed.containsKey(entry.key)) {
          await _evictEntry(entry);
        }
      }

      // If cache is still too large, remove oldest entries.
      if (_metaBox!.length > maxNrOfCacheObjects) {
        final sortedEntries = _cleanupStrategy.sortForEviction(
          entries.where((e) => _metaBox!.containsKey(e.key)).toList(),
        );

        final toRemove = sortedEntries.length - maxNrOfCacheObjects;
        var removed = 0;
        for (final entry in sortedEntries) {
          if (removed >= toRemove) break;
          if (_recentlyServed.containsKey(entry.key)) continue;
          await _evictEntry(entry);
          removed++;
        }
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error during cleanup: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  Future<void> _evictEntry(
    MapEntry<String, CacheEntryMetadata> entry,
  ) async {
    await _metaBox!.delete(entry.key);
    await _dataBox!.delete(entry.key);
    try {
      final file = _memFs.file('/${entry.value.relativePath}');
      if (file.existsSync()) {
        await file.delete();
      }
    } on Object catch (_) {}
  }

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
