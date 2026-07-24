import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hive_ce/hive.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/hive_impl.dart';
import 'package:http/http.dart' as http;

import 'cache_entry_metadata.dart';

export 'cache_entry_metadata.dart';

const _kMetaBoxName = 'cached_network_image_cache';
const _kDataBoxName = 'cached_network_image_data';
const _kDefaultMaxAge = Duration(days: 30);
const _kDefaultMaxCacheObjects = 200;
const _kDefaultStalePeriod = Duration(days: 7);

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
  /// [httpClientFactory] allows injecting a custom HTTP client for testing.
  /// [hiveInstance] allows injecting a pre-initialised Hive instance
  /// (useful for VM tests that need `Hive.init(path)` called first).
  DefaultCacheManager({
    this.stalePeriod = _kDefaultStalePeriod,
    this.maxNrOfCacheObjects = _kDefaultMaxCacheObjects,
    this.connectionParameters,
    http.Client Function()? httpClientFactory,
    @visibleForTesting HiveInterface? hiveInstance,
  })  : _httpClientFactory = httpClientFactory ?? http.Client.new,
        _hive = hiveInstance ?? HiveImpl();

  /// Duration before cached files are considered stale.
  final Duration stalePeriod;

  /// Maximum number of objects in the cache before cleanup.
  final int maxNrOfCacheObjects;

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

  /// Factory for lazily creating the shared HTTP client.
  final http.Client Function() _httpClientFactory;

  http.Client? _httpClient;

  http.Client get _client => _httpClient ??= _httpClientFactory();

  /// In-memory file system used to materialise cached bytes as [File] objects.
  final MemoryFileSystem _memFs = MemoryFileSystem();

  /// Private Hive instance to avoid conflicts with the host app's Hive usage.
  final HiveInterface _hive;

  Box<Map>? _metaBox;
  LazyBox<List<int>>? _dataBox;

  /// Guards [_doInit] so concurrent callers share one init future.
  Completer<void>? _initCompleter;

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

    // Run cleanup in background.
    unawaited(_cleanupOldEntries());
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

    if (cachedFile == null || cachedFile.validTill.isBefore(DateTime.now())) {
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

    final abortCompleter = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      Uri.parse(url),
      abortTrigger: abortCompleter.future,
    );
    if (headers != null) {
      request.headers.addAll(headers);
    }

    try {
      final connectionTimeout = connectionParameters?.connectionTimeout;
      final sendFuture = _client.send(request);
      final response = connectionTimeout != null
          ? await sendFuture.timeout(
              connectionTimeout,
              onTimeout: () {
                if (!abortCompleter.isCompleted) {
                  abortCompleter.complete();
                }
                throw TimeoutException(
                  'Connection timed out after $connectionTimeout',
                  connectionTimeout,
                );
              },
            )
          : await sendFuture;

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
      final validTill = DateTime.now().add(stalePeriod);
      final cacheHeaders = response.headers;
      final eTag = cacheHeaders['etag'];
      final fileExtension = _getFileExtensionFromUrl(url);
      final relativePath =
          '${key.hashCode.toUnsigned(32).toRadixString(16)}.$fileExtension';

      await _metaBox!.put(
        _sanitizeBoxKey(key),
        CacheEntryMetadata(
          url: url,
          relativePath: relativePath,
          validTill: validTill,
          eTag: eTag,
          length: receivedBytes,
        ).toMap(),
      );
      await _dataBox!.put(_sanitizeBoxKey(key), allBytes);

      final file = _bytesToFile(relativePath, allBytes);
      yield FileInfo(file, FileSource.Online, validTill, url);
    } finally {
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
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

    final file = _bytesToFile(metadata.relativePath, bytes);
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
    final validTill = DateTime.now().add(maxAge);

    await _metaBox!.put(
      _sanitizeBoxKey(key),
      CacheEntryMetadata(
        url: url,
        relativePath: relativePath,
        validTill: validTill,
        eTag: eTag,
        length: fileBytes.length,
      ).toMap(),
    );
    await _dataBox!.put(_sanitizeBoxKey(key), fileBytes);

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

    final client = _httpClient;
    _httpClient = null;
    client?.close();

    if (_metaBox != null && _metaBox!.isOpen) {
      await _metaBox!.close();
    }
    if (_dataBox != null && _dataBox!.isOpen) {
      await _dataBox!.close();
    }

    _metaBox = null;
    _dataBox = null;
    _initCompleter = null;
  }

  /// Clean up entries that have expired.
  Future<void> _cleanupOldEntries() async {
    try {
      final now = DateTime.now();
      final entries = <MapEntry<dynamic, CacheEntryMetadata>>[];

      for (final key in _metaBox!.keys.toList()) {
        final raw = _metaBox!.get(key);
        if (raw != null) {
          entries.add(MapEntry(key, CacheEntryMetadata.fromMap(raw)));
        }
      }

      // Remove expired entries.
      for (final entry in entries) {
        if (entry.value.validTill.isBefore(now)) {
          await _metaBox!.delete(entry.key);
          await _dataBox!.delete(entry.key);
          try {
            final file = _memFs.file('/${entry.value.relativePath}');
            if (file.existsSync()) {
              await file.delete();
            }
          } on Object catch (_) {}
        }
      }

      // If cache is still too large, remove oldest entries.
      if (_metaBox!.length > maxNrOfCacheObjects) {
        final sortedEntries = entries
            .where((e) => _metaBox!.containsKey(e.key))
            .toList()
          ..sort((a, b) => a.value.validTill.compareTo(b.value.validTill));

        final toRemove = sortedEntries.length - maxNrOfCacheObjects;
        for (var i = 0; i < toRemove; i++) {
          final entry = sortedEntries[i];
          await _metaBox!.delete(entry.key);
          await _dataBox!.delete(entry.key);
          try {
            final file = _memFs.file('/${entry.value.relativePath}');
            if (file.existsSync()) {
              await file.delete();
            }
          } on Object catch (_) {}
        }
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error during cleanup: $e',
        CacheManagerLogLevel.warning,
      );
    }
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
      if (fromCache.validTill.isAfter(DateTime.now())) {
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
          maxAge: response.validTill.difference(DateTime.now()),
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
