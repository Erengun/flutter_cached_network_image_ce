import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_ce/hive.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/hive_impl.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'cache_entry_metadata.dart';
import 'cleanup_coordinator.dart';
import 'cleanup_strategy.dart';
import 'interceptors/cache_interceptor.dart';
import 'interceptors/http_interceptor.dart';
import 'interceptors/interceptor_runner.dart';
import 'shared_http_client.dart';

export 'cache_entry_metadata.dart';

const _kBoxName = 'cached_network_image_cache';
const _kDefaultMaxAge = Duration(days: 30);
const _kDefaultMaxCacheObjects = 200;
const _kDefaultStalePeriod = Duration(days: 7);
const _kOrphanFileGracePeriod = Duration(minutes: 5);
const _kServedEntryGracePeriod = Duration(seconds: 30);

/// Size at which recently served entries are swept for expired records.
/// Only a bound on bookkeeping, not on how many entries are guarded.
const _kServedEntryPruneThreshold = 64;

const _supportedFileNames = ['jpg', 'jpeg', 'png', 'tga', 'cur', 'ico', 'webp'];

/// Sanitizes a key so it doesn't exceed Hive's 255-character limit for string keys.
String _sanitizeBoxKey(String key) {
  if (key.length <= 255) return key;
  final hash = sha256.convert(utf8.encode(key)).toString();
  // 255 max limit. 255 - 64 (sha256 hex length) - 1 (underscore) = 190
  return '${key.substring(0, 190)}_$hash';
}

/// Signature for a function that returns a cache base directory.
///
/// Defaults to [getTemporaryDirectory] when not specified.
typedef CacheDirectoryProvider = Future<io.Directory> Function();

/// Default cache manager implementation using Hive CE for metadata storage,
/// the http package for downloads, and path_provider for file system access.
class DefaultCacheManager extends CacheManager with ImageCacheManager {
  /// Creates a [DefaultCacheManager] with optional configuration.
  ///
  /// [stalePeriod] is how long a file remains valid in the cache.
  /// [maxNrOfCacheObjects] is the maximum before cleanup triggers.
  /// [maxIdleDuration] removes files that have not been accessed for that
  /// duration instead of removing files based on [CacheEntryMetadata.validTill].
  /// [maxCacheSizeInBytes] caps the total size of cached files. When a store
  ///   pushes the cache over it, entries are evicted in [cleanupStrategy]
  ///   order. Entries handed to callers in the last 30 seconds are protected,
  ///   so the cache can briefly exceed the limit until they can be evicted.
  ///   Defaults to null (no byte limit).
  /// [cleanupOnInitialize] can defer cleanup until [startCleanup] is called.
  /// [httpClientFactory] allows injecting a custom HTTP client (useful for testing).
  /// [cacheDirectoryProvider] allows overriding where cache files are stored.
  ///   Defaults to [getTemporaryDirectory]. Pass [getApplicationSupportDirectory]
  ///   if you need a more persistent location (but note that files may be
  ///   backed up on iOS/Android).
  /// [metadataDirectoryProvider] allows overriding where Hive metadata is stored.
  ///   Defaults to [cacheDirectoryProvider] for backwards compatibility.
  DefaultCacheManager({
    this.stalePeriod = _kDefaultStalePeriod,
    this.maxNrOfCacheObjects = _kDefaultMaxCacheObjects,
    this.maxIdleDuration,
    this.maxCacheSizeInBytes,
    this.cleanupOnInitialize = true,
    this.connectionParameters,
    http.Client Function()? httpClientFactory,
    CacheDirectoryProvider? cacheDirectoryProvider,
    CacheDirectoryProvider? metadataDirectoryProvider,
    List<HttpInterceptor> httpInterceptors = const [],
    List<CacheInterceptor> cacheInterceptors = const [],
    CleanupStrategy? cleanupStrategy,
  })  : _httpClient = SharedHttpClient(httpClientFactory ?? http.Client.new),
        _cacheDirectoryProvider =
            cacheDirectoryProvider ?? getTemporaryDirectory,
        _metadataDirectoryProvider = metadataDirectoryProvider,
        _httpInterceptors = httpInterceptors,
        _cacheInterceptors = cacheInterceptors,
        _cleanupStrategy = cleanupStrategy ?? const TtlCleanupStrategy(),
        assert(maxCacheSizeInBytes == null || maxCacheSizeInBytes > 0);

  /// Duration before cached files are considered stale.
  final Duration stalePeriod;

  /// Maximum number of objects in the cache before cleanup.
  final int maxNrOfCacheObjects;

  /// Maximum time an entry may remain unaccessed before cleanup removes it.
  ///
  /// When null, cleanup keeps the legacy behavior of removing entries whose
  /// [CacheEntryMetadata.validTill] is in the past.
  final Duration? maxIdleDuration;

  /// Maximum total size in bytes of cached files.
  ///
  /// When null (the default), the cache has no byte limit.
  final int? maxCacheSizeInBytes;

  /// Whether cleanup is enabled during initialization.
  final bool cleanupOnInitialize;

  /// Optional connection parameters for HTTP timeouts.
  ///
  /// When `null` (the default), no timeouts are applied and downloads may
  /// wait indefinitely — preserving the existing behaviour.
  final ConnectionParameters? connectionParameters;

  final SharedHttpClient _httpClient;

  /// Provider for the base cache directory.
  final CacheDirectoryProvider _cacheDirectoryProvider;

  /// Provider for the base Hive metadata directory.
  final CacheDirectoryProvider? _metadataDirectoryProvider;

  /// HTTP interceptors that run for every download.
  final List<HttpInterceptor> _httpInterceptors;

  /// Cache interceptors that run on hit, miss, and store events.
  final List<CacheInterceptor> _cacheInterceptors;

  /// Strategy that determines the eviction order when the cache is over capacity.
  final CleanupStrategy _cleanupStrategy;

  /// Private Hive instance to avoid conflicts with the host app's global
  /// [Hive] singleton. Each [DefaultCacheManager] gets its own isolated
  /// Hive registry.
  final HiveInterface _hive = HiveImpl();

  Box<Map>? _cacheBox;
  String? _cacheDir;
  int _metadataPathRevision = 0;

  final CleanupCoordinator _cleanup = CleanupCoordinator(
    servedEntryGracePeriod: _kServedEntryGracePeriod,
    servedEntryPruneThreshold: _kServedEntryPruneThreshold,
  );

  /// Guards [_doInit] so that concurrent callers (e.g. multiple images
  /// loading at the same time on cold start) share the same init future.
  Completer<void>? _initCompleter;

  /// Initialize Hive and open the cache metadata box.
  ///
  /// Uses a [Completer] to ensure that only one initialization runs at a
  /// time, even when multiple callers invoke this concurrently.
  Future<void> _ensureInitialized() {
    final currentCompleter = _initCompleter;
    if (currentCompleter != null) return currentCompleter.future;

    final completer = Completer<void>();
    _initCompleter = completer;

    _doInit().then((_) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }).catchError((Object e, StackTrace s) {
      // Allow retry on next call by clearing the completer that initiated
      // this initialization sequence.
      if (identical(_initCompleter, completer)) {
        _initCompleter = null;
      }
      if (!completer.isCompleted) {
        completer.completeError(e, s);
      }
    });

    return completer.future;
  }

  Future<void> _doInit() async {
    final dir = await _cacheDirectoryProvider();
    final metadataDir = _metadataDirectoryProvider == null
        ? dir
        : await _metadataDirectoryProvider!();

    // When a distinct metadataDirectoryProvider is configured, namespace the
    // cache file directory by that location. Otherwise two DefaultCacheManager
    // instances could share the same cacheDirectoryProvider while keeping
    // separate, unaware-of-each-other Hive boxes — each instance's orphan
    // sweep would then see the other's files as unknown and delete them.
    final cacheSubDir = _metadataDirectoryProvider == null
        ? 'cached_network_image_ce'
        : path.join(
            'cached_network_image_ce',
            sha256
                .convert(utf8.encode(metadataDir.path))
                .toString()
                .substring(0, 16),
          );
    _cacheDir = path.join(dir.path, cacheSubDir);
    await io.Directory(_cacheDir!).create(recursive: true);

    final hivePath = path.join(
      metadataDir.path,
      'cached_network_image_ce',
      'hive',
    );
    await io.Directory(hivePath).create(recursive: true);

    // Open the box with an explicit path on the private Hive instance.
    // This avoids calling Hive.init() which would conflict with the
    // host application's own Hive initialization.
    try {
      _cacheBox = await _hive.openBox<Map>(_kBoxName, path: hivePath);
    } on HiveError catch (e) {
      // Box corruption (e.g. "Cannot read, unknown typeId: 121").
      // Since this is a cache, we can safely delete the corrupted box
      // and start fresh. Cached images will simply be re-downloaded.
      cacheLogger.log(
        'CacheManager: Hive box corrupted, resetting cache: $e',
        CacheManagerLogLevel.warning,
      );
      await _safeDeleteBox(_kBoxName, hivePath);
      _cacheBox = await _hive.openBox<Map>(_kBoxName, path: hivePath);

      // Also remove cached files since their metadata is gone.
      await _deleteCacheFiles();
    } on io.PathNotFoundException catch (e) {
      // The OS cleared the cache directory (e.g. Android low-storage
      // eviction) while Hive was opening the box files. Hive recreates a
      // missing box directory on open, so retry once.
      cacheLogger.log(
        'CacheManager: Cache directory removed during init, retrying: $e',
        CacheManagerLogLevel.warning,
      );
      _cacheBox = await _hive.openBox<Map>(_kBoxName, path: hivePath);
    }
    _metadataPathRevision++;
    _cleanup.byteLimitEvictionEnabled = maxCacheSizeInBytes != null;

    if (cleanupOnInitialize) {
      unawaited(_scheduleCleanup());
    }
  }

  /// Attempts to delete a Hive box from disk, tolerating missing files.
  ///
  /// [HiveImpl.deleteBoxFromDisk] can throw [PathNotFoundException] when
  /// auxiliary files (e.g. `.lock`) are already gone. In that case we
  /// fall back to manually deleting the `.hive` file.
  Future<void> _safeDeleteBox(String boxName, String boxPath) async {
    try {
      await _hive.deleteBoxFromDisk(boxName, path: boxPath);
    } on Object catch (_) {
      // Fallback: delete the .hive file directly.
      final boxFile = io.File(path.join(boxPath, '$boxName.hive'));
      if (await boxFile.exists()) {
        await boxFile.delete();
      }
    }
  }

  /// Deletes all cached image files in the cache directory.
  ///
  /// Called after a corruption recovery to remove orphaned files whose
  /// metadata has been lost.
  Future<void> _deleteCacheFiles() async {
    try {
      final cacheDir = io.Directory(_cacheDir!);
      if (await cacheDir.exists()) {
        await for (final entity in cacheDir.list()) {
          if (entity is io.File) {
            await entity.delete();
          }
        }
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error cleaning orphaned cache files: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  String _cacheFilePath(String relativePath) {
    return path.join(_cacheDir!, relativePath);
  }

  Future<void> _ensureCacheDirectoryExists() async {
    await io.Directory(_cacheDir!).create(recursive: true);
  }

  /// Builds a relative file path from key and extension.
  String _generateRelativePath(String key, String fileExtension) {
    final hash = key.hashCode.toUnsigned(32).toRadixString(16);
    return '$hash.$fileExtension';
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
    await _ensureInitialized();

    FileInfo? cachedFile;
    try {
      cachedFile = await getFileFromCache(key);
      if (cachedFile != null) {
        final isExpired = cachedFile.validTill.isBefore(clock.now());
        final hitOutcome = await runOnHitChain(
          _cacheInterceptors,
          CacheHitData(fileInfo: cachedFile, key: key, isExpired: isExpired),
        );
        if (hitOutcome is CacheHitReturn) {
          cachedFile = hitOutcome.fileInfo;
          controller.add(cachedFile);
          withProgress = false;
        } else {
          // CacheHitRejected — treat as a miss, force re-download.
          // withProgress stays as-is so progress events fire during re-download.
          cachedFile = null;
        }
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to load cached file for $url with error:\n$e',
        CacheManagerLogLevel.debug,
      );
    }

    if (cachedFile == null || cachedFile.validTill.isBefore(clock.now())) {
      if (cachedFile == null) {
        // Run onMiss chain — interceptor may provide a synthetic response
        final syntheticFile = await runOnMissChain(
          _cacheInterceptors,
          CacheMissData(key: key, url: url),
        );
        if (syntheticFile != null) {
          controller.add(syntheticFile);
          await controller.close();
          return;
        }
      }
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

    // Splice 1: run onRequest chain — may mutate url/headers or short-circuit
    final reqData = HttpRequestData(
      url: url,
      headers: Map<String, String>.from(headers ?? {}),
    );
    final reqOutcome = await runOnRequestChain(_httpInterceptors, reqData);
    if (reqOutcome is HttpRequestResolved) {
      // An interceptor short-circuited: skip client.send() entirely
      yield* _processResponse(url, key, withProgress, reqOutcome.response);
      return;
    }

    final proceed = reqOutcome as HttpRequestProceed;
    SharedHttpClientResponse? clientResponse;
    http.StreamedResponse? rawResponse;
    try {
      clientResponse = await _httpClient.send(
        uri: Uri.parse(proceed.data.url),
        headers: proceed.data.headers,
        connectionTimeout: connectionParameters?.connectionTimeout,
      );
      final response = clientResponse.response;
      rawResponse = response;

      // Splice 2: run onResponse chain — interceptors may replace the response
      final processedRes = await runOnResponseChain(
        _httpInterceptors,
        HttpResponseData(response: response, originalUrl: url),
      );
      if (!identical(processedRes.response, response)) {
        await _cancelResponseStream(response);
        rawResponse = null;
      }
      if (processedRes.response.statusCode != 200 &&
          processedRes.response.statusCode != 202) {
        // _processResponse owns cancellation for invalid responses.
        rawResponse = null;
      }

      // _processResponse reads the stream; client must remain open until done
      yield* _processResponse(url, key, withProgress, processedRes);
    } catch (e, st) {
      final response = rawResponse;
      if (response != null) {
        await _cancelResponseStream(response);
      }

      // Splice 3: run onError chain for all errors (network, status, stream)
      final errorOutcome = await runOnErrorChain(_httpInterceptors, e, st);
      if (errorOutcome is HttpErrorResolved) {
        yield* _processResponse(url, key, withProgress, errorOutcome.response);
        return;
      }
      final rethrow_ = errorOutcome as HttpErrorRethrow;
      Error.throwWithStackTrace(rethrow_.error, rethrow_.stackTrace);
    } finally {
      clientResponse?.release();
    }
  }

  Future<void> _cancelResponseStream(http.StreamedResponse response) async {
    try {
      final subscription = response.stream.listen(
        null,
        onError: (Object _, StackTrace __) {},
      );
      await subscription.cancel();
    } on StateError catch (_) {
      // A downstream owner may already have consumed the single-subscription
      // stream. Other cleanup failures should remain visible.
    }
  }

  /// Processes an [HttpResponseData] into cached [FileResponse] events.
  ///
  /// Shared by the normal download path, onRequest-resolve short-circuit,
  /// and onError-resolve recovery path.
  Stream<FileResponse> _processResponse(
    String url,
    String key,
    bool withProgress,
    HttpResponseData resData,
  ) async* {
    final response = resData.response;

    if (response.statusCode != 200 && response.statusCode != 202) {
      await _cancelResponseStream(response);
      throw HttpExceptionWithStatus(
        response.statusCode,
        'Invalid statusCode: ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }

    final contentLength = response.contentLength;
    final fileExtension = _getFileExtensionFromUrl(url);
    final relativePath = _generateRelativePath(key, fileExtension);
    final filePath = _cacheFilePath(relativePath);
    final sanitizedKey = _sanitizeBoxKey(key);

    await _ensureCacheDirectoryExists();

    final tempFilePath =
        '$filePath.${DateTime.now().microsecondsSinceEpoch}.tmp';
    final tempFile = io.File(tempFilePath);
    final tempRelativePath = path.relative(tempFilePath, from: _cacheDir!);
    final releaseTempPath = await _cleanup.beginPathUse(tempRelativePath);
    var tempPathReserved = true;
    late final io.IOSink sink;
    try {
      sink = tempFile.openWrite();
    } on Object catch (_) {
      releaseTempPath();
      tempPathReserved = false;
      rethrow;
    }

    final requestTimeout = connectionParameters?.requestTimeout;
    final stream = requestTimeout != null
        ? response.stream.timeout(requestTimeout)
        : response.stream;

    var receivedBytes = 0;
    var downloadFinished = false;
    try {
      await for (final chunk in stream) {
        receivedBytes += chunk.length;
        sink.add(chunk);
        if (withProgress) {
          yield DownloadProgress(url, contentLength, receivedBytes);
        }
      }
      await sink.flush();
      await sink.close();
      downloadFinished = true;
    } on Object catch (_) {
      await sink.close();
      rethrow;
    } finally {
      if (!downloadFinished) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } finally {
          releaseTempPath();
          tempPathReserved = false;
        }
      }
    }

    if (_exceedsByteLimit(receivedBytes)) {
      final File file;
      try {
        file = await _deliverUncached(
          sanitizedKey,
          relativePath,
          tempFile.copy,
        );
      } finally {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } finally {
          releaseTempPath();
        }
      }
      yield FileInfo(
          file, FileSource.Online, clock.now().add(stalePeriod), url);
      return;
    }

    final releaseStore = await _cleanup.beginStore(
      sanitizedKey,
      path: relativePath,
    );
    final releaseFinalPath = await _cleanup.beginPathUse(relativePath);
    late final String deliveryPath;
    late final DateTime validTill;
    var movedToFinalPath = false;
    try {
      final finalFile = io.File(filePath);
      try {
        await tempFile.rename(filePath);
        movedToFinalPath = true;
      } on Object catch (_) {
        io.File? backupFile;
        CleanupLease? backupPathRelease;
        try {
          if (await finalFile.exists()) {
            final backupPath =
                '$filePath.${DateTime.now().microsecondsSinceEpoch}.bak';
            final backupRelativePath =
                path.relative(backupPath, from: _cacheDir!);
            backupPathRelease = await _cleanup.beginPathUse(backupRelativePath);
            backupFile = await finalFile.rename(backupPath);
          }

          await tempFile.rename(filePath);
          movedToFinalPath = true;
        } on Object catch (_) {
          if (backupFile != null && await backupFile.exists()) {
            if (await finalFile.exists()) {
              await finalFile.delete();
            }
            await backupFile.rename(filePath);
          }
          rethrow;
        } finally {
          try {
            if (movedToFinalPath &&
                backupFile != null &&
                await backupFile.exists()) {
              await backupFile.delete();
            }
          } on Object catch (e) {
            cacheLogger.log(
              'CacheManager: Failed to delete backup file for $filePath with error:\n$e',
              CacheManagerLogLevel.warning,
            );
          } finally {
            backupPathRelease?.call();
          }
        }
      }

      // Store metadata in Hive
      validTill = clock.now().add(stalePeriod);
      final cacheHeaders = response.headers;
      final eTag = cacheHeaders['etag'];

      final metadata = CacheEntryMetadata(
        url: url,
        relativePath: relativePath,
        validTill: validTill,
        eTag: eTag,
        length: receivedBytes,
        touchedAt: clock.now(),
      );
      final storeOutcome = await runOnStoreChain(
        _cacheInterceptors,
        CacheStoreData(
          url: url,
          key: key,
          metadata: metadata,
          file: io.File(filePath),
        ),
      );
      if (storeOutcome) {
        await _storeMetadata(sanitizedKey, metadata);
        deliveryPath = filePath;
      } else {
        // Interceptor rejected storage: copy to a temp file for this delivery,
        // then delete the cache-directory copy so nothing is orphaned there.
        final tempPath = _noCachePath(path.basename(filePath));
        await io.File(filePath).copy(tempPath);
        final f = io.File(filePath);
        if (await f.exists()) await f.delete();
        deliveryPath = tempPath;
      }
      _markServed(sanitizedKey);
    } finally {
      releaseFinalPath();
      releaseStore();
      _scheduleCapacityCleanup();
      try {
        if (!movedToFinalPath && await tempFile.exists()) {
          await tempFile.delete();
        }
      } finally {
        if (tempPathReserved) releaseTempPath();
      }
    }

    final localFile = const LocalFileSystem().file(deliveryPath);
    yield FileInfo(localFile, FileSource.Online, validTill, url);
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    await _ensureInitialized();

    final sanitizedKey = _sanitizeBoxKey(key);
    if (_cleanup.isEvicting(sanitizedKey)) return null;

    final raw = _cacheBox!.get(sanitizedKey);
    if (raw == null) return null;

    final metadata = CacheEntryMetadata.fromMap(raw);
    if (_cleanup.isStoring(sanitizedKey, path: metadata.relativePath)) {
      return null;
    }

    final filePath = _cacheFilePath(metadata.relativePath);
    final file = io.File(filePath);
    if (!file.existsSync()) {
      // Metadata exists but file is missing, clean up
      await _cacheBox!.delete(sanitizedKey);
      _metadataPathRevision++;
      return null;
    }

    final localFile = const LocalFileSystem().file(filePath);
    _markServed(sanitizedKey);
    unawaited(_touchEntry(key));
    return FileInfo(
        localFile, FileSource.Cache, metadata.validTill, metadata.url);
  }

  /// Records that [sanitizedKey] was handed to a caller, and drops entries
  /// that have outlived the grace period once the map has grown enough to be
  /// worth sweeping.
  void _markServed(String sanitizedKey) {
    _cleanup.markServed(sanitizedKey, clock.now());
  }

  /// Number of entries currently protected from eviction. Test-only.
  @visibleForTesting
  int get debugRecentlyServedCount => _cleanup.recentlyServedCount;

  /// Updates the [touchedAt] timestamp for [key] in the cache box.
  ///
  /// Re-reads the current entry immediately before writing so a concurrent
  /// update to other fields (e.g. a re-download) isn't clobbered by a touch
  /// based on stale metadata. Fire-and-forget — callers should wrap with
  /// [unawaited].
  Future<void> _touchEntry(String key) async {
    // Capture _cacheBox before the first await to guard against a concurrent
    // dispose() nulling the field while this future is suspended.
    final box = _cacheBox;
    if (box == null || !box.isOpen) return;
    final sanitizedKey = _sanitizeBoxKey(key);
    try {
      final raw = box.get(sanitizedKey);
      if (raw == null) return;
      final current = CacheEntryMetadata.fromMap(raw);
      final updated = CacheEntryMetadata(
        url: current.url,
        relativePath: current.relativePath,
        validTill: current.validTill,
        eTag: current.eTag,
        length: current.length,
        touchedAt: clock.now(),
      );
      await box.put(sanitizedKey, updated.toMap());
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Failed to update touchedAt for $key: $e',
        CacheManagerLogLevel.debug,
      );
    }
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
    final sanitizedKey = _sanitizeBoxKey(key);
    final relativePath = _generateRelativePath(key, fileExtension);
    if (_exceedsByteLimit(fileBytes.length)) {
      return _deliverUncached(
        sanitizedKey,
        relativePath,
        (deliveryPath) => io.File(deliveryPath).writeAsBytes(fileBytes),
      );
    }
    final releaseStore = await _cleanup.beginStore(
      sanitizedKey,
      path: relativePath,
    );
    final releasePath = await _cleanup.beginPathUse(relativePath);
    try {
      final filePath = _cacheFilePath(relativePath);

      await _ensureCacheDirectoryExists();

      final file = io.File(filePath);
      await file.writeAsBytes(fileBytes);

      final validTill = clock.now().add(maxAge);
      await _storeMetadata(
          sanitizedKey,
          CacheEntryMetadata(
            url: url,
            relativePath: relativePath,
            validTill: validTill,
            eTag: eTag,
            length: fileBytes.length,
            touchedAt: clock.now(),
          ));

      _markServed(sanitizedKey);

      return const LocalFileSystem().file(filePath);
    } finally {
      releasePath();
      releaseStore();
      _scheduleCapacityCleanup();
    }
  }

  Future<void> _storeMetadata(String key, CacheEntryMetadata metadata) async {
    final box = _cacheBox!;
    CleanupLease? releasePreviousPath;
    while (true) {
      final previousPath = box.get(key)?['relativePath'];
      if (previousPath is! String || previousPath == metadata.relativePath) {
        break;
      }
      final release = await _cleanup.beginPathUse(previousPath);
      if (box.isOpen && box.get(key)?['relativePath'] == previousPath) {
        releasePreviousPath = release;
        break;
      }
      release();
    }

    // Hive exposes pending metadata and can restore the previous map on error.
    _metadataPathRevision++;
    try {
      await box.put(key, metadata.toMap());
    } finally {
      _metadataPathRevision++;
      releasePreviousPath?.call();
    }
  }

  @override
  Future<void> removeFile(String key) async {
    await _ensureInitialized();

    final sanitizedKey = _sanitizeBoxKey(key);
    final releaseRemoval = await _cleanup.beginStore(sanitizedKey);
    try {
      await _deleteEntry(sanitizedKey);
    } finally {
      releaseRemoval();
      _scheduleCapacityCleanup();
    }
  }

  /// Deletes the file and metadata stored for [sanitizedKey]. Callers must
  /// hold the store lease for the key.
  Future<void> _deleteEntry(String sanitizedKey) async {
    final box = _cacheBox!;
    final raw = box.get(sanitizedKey);
    if (raw == null) return;
    final metadata = CacheEntryMetadata.fromMap(raw);
    final file = io.File(_cacheFilePath(metadata.relativePath));
    if (await file.exists()) {
      await file.delete();
    }
    await box.delete(sanitizedKey);
    _metadataPathRevision++;
  }

  /// Returns a unique path outside the cache directory for a file that is
  /// delivered to the caller but not cached.
  String _noCachePath(String fileName) =>
      '${io.Directory.systemTemp.path}/$fileName'
      '.${DateTime.now().microsecondsSinceEpoch}.nocache';

  /// Delivers an entry larger than [maxCacheSizeInBytes] without caching it.
  ///
  /// [write] creates the file at a [_noCachePath]. Any entry already cached
  /// for [sanitizedKey] is removed, so the oversized response replaces it.
  Future<File> _deliverUncached(
    String sanitizedKey,
    String fileName,
    Future<void> Function(String deliveryPath) write,
  ) async {
    final releaseRemoval = await _cleanup.beginStore(sanitizedKey);
    try {
      final deliveryPath = _noCachePath(fileName);
      await write(deliveryPath);
      await _deleteEntry(sanitizedKey);
      return const LocalFileSystem().file(deliveryPath);
    } finally {
      releaseRemoval();
      _scheduleCapacityCleanup();
    }
  }

  @override
  Future<void> emptyCache() async {
    await _ensureInitialized();

    // Delete all cached files
    for (final key in _cacheBox!.keys.toList()) {
      final raw = _cacheBox!.get(key);
      if (raw != null) {
        final metadata = CacheEntryMetadata.fromMap(raw);
        final file = io.File(_cacheFilePath(metadata.relativePath));
        if (await file.exists()) {
          await file.delete();
        }
      }
    }

    await _cacheBox!.clear();
    _metadataPathRevision++;
  }

  /// Returns the total size in bytes of the images stored in the disk cache.
  ///
  /// Counts only entries tracked by the cache, not Flutter's in-memory
  /// [ImageCache]. Sizes are read from disk, so entries whose file was removed
  /// outside the cache (e.g. by the OS) count as 0. Returns 0 when the cache
  /// is empty.
  Future<int> getCacheSize() async {
    await _ensureInitialized();
    final cacheDir = _cacheDir!;
    final relativePaths = <String>{};
    for (final raw in _cacheBox!.values) {
      try {
        relativePaths.add(CacheEntryMetadata.fromMap(raw).relativePath);
      } on Object catch (_) {
        // Malformed entry: never served from the cache, so not counted.
      }
    }
    var total = 0;
    for (final relativePath in relativePaths) {
      try {
        total += await io.File(path.join(cacheDir, relativePath)).length();
      } on io.FileSystemException catch (_) {
        // File is gone; its metadata is cleaned up lazily elsewhere.
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
        // Already logged inside _cleanupOldFiles; ignore here.
      }
    }

    _httpClient.dispose();

    if (_cacheBox != null && _cacheBox!.isOpen) {
      try {
        await _cacheBox!.close();
      } on Object catch (_) {
        // Ignore errors when closing box (e.g. PathNotFoundException if the
        // cache directory was deleted before dispose was called).
      }
    }
    try {
      await _hive.close();
    } on Object catch (_) {
      // Ignore errors when closing Hive (e.g. residual lock file already gone).
    }

    _cacheBox = null;
    _cacheDir = null;
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
      _cleanupOldFiles,
      _isOverCapacity,
      capacity: capacity,
    );
  }

  void _scheduleCapacityCleanup() {
    if (_cleanup.capacityCleanupEnabled && _isOverCapacity()) {
      unawaited(_scheduleCleanup(capacity: true));
    } else if (_isOverByteLimit()) {
      unawaited(_scheduleByteLimitEviction());
    }
  }

  Future<void> _scheduleByteLimitEviction() {
    return _cleanup.schedule(
      _evictOverByteLimit,
      _isOverByteLimit,
      capacity: true,
    );
  }

  bool _isOverCapacity() {
    final box = _cacheBox;
    try {
      return (box != null && box.isOpen && box.length > maxNrOfCacheObjects) ||
          _isOverByteLimit();
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
    final box = _cacheBox;
    if (box == null || !box.isOpen) return 0;
    var total = 0;
    for (final raw in box.values) {
      total += raw['length'] as int? ?? 0;
    }
    return total;
  }

  /// Evicts entries in strategy order until the cache fits the byte limit.
  ///
  /// Unlike [_cleanupOldFiles], this skips the expiry and orphan sweep and
  /// does not enforce [maxNrOfCacheObjects].
  Future<void> _evictOverByteLimit() async {
    try {
      _cleanup.pruneRecentlyServed(clock.now());
      await _cleanup.evictOverCapacity(
        now: clock.now,
        isOverCapacity: _isOverByteLimit,
        candidates: () => _cleanupStrategy.sortForEviction(_snapshotEntries()),
        evict: _evictEntry,
        retry: _scheduleByteLimitEviction,
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

  /// Clean up files that haven't been used in a while.
  Future<void> _cleanupOldFiles() async {
    try {
      final now = clock.now();
      _cleanup.pruneRecentlyServed(now);
      final entries = _snapshotEntries();
      final pathSnapshotRevision = _metadataPathRevision;

      await _deleteOrphanedCacheFiles(
        entries.map((entry) => entry.value.relativePath).toSet(),
        pathSnapshotRevision,
        now,
      );

      // Remove expired entries
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
        // Without startCleanup, a retry may only enforce the byte limit.
        retry: () => _cleanup.capacityCleanupEnabled
            ? _scheduleCleanup(capacity: true)
            : _scheduleByteLimitEviction(),
      );
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error during cleanup: $e',
        CacheManagerLogLevel.warning,
      );
    }
  }

  /// Deletes the cached file for [entry] and then its metadata record.
  Future<CacheEvictionResult> _evictEntry(
    MapEntry<String, CacheEntryMetadata> entry,
  ) async {
    final releaseEviction = _cleanup.beginEviction(entry.key);
    if (releaseEviction == null) return CacheEvictionResult.skipped;
    CleanupLease? releasePathDeletion;
    try {
      final box = _cacheBox;
      if (box == null || !box.isOpen) return CacheEvictionResult.skipped;
      final raw = box.get(entry.key);
      if (raw == null) return CacheEvictionResult.changed;
      final current = CacheEntryMetadata.fromMap(raw);
      final candidate = entry.value;
      if (!_sameMetadata(current, candidate)) {
        return CacheEvictionResult.changed;
      }

      releasePathDeletion = _cleanup.beginPathDeletion(candidate.relativePath);
      if (releasePathDeletion == null) {
        return CacheEvictionResult.skipped;
      }

      final file = io.File(_cacheFilePath(candidate.relativePath));
      if (await file.exists()) {
        await file.delete();
      }
      await box.delete(entry.key);
      _metadataPathRevision++;
      return CacheEvictionResult.removed;
    } finally {
      releasePathDeletion?.call();
      releaseEviction();
    }
  }

  List<MapEntry<String, CacheEntryMetadata>> _snapshotEntries() => [
        for (final key in _cacheBox!.keys)
          MapEntry(
              key as String, CacheEntryMetadata.fromMap(_cacheBox!.get(key)!)),
      ];

  bool _sameMetadata(CacheEntryMetadata a, CacheEntryMetadata b) =>
      a.url == b.url &&
      a.relativePath == b.relativePath &&
      a.validTill == b.validTill &&
      a.eTag == b.eTag &&
      a.length == b.length &&
      a.touchedAt == b.touchedAt;

  Future<void> _deleteOrphanedCacheFiles(
    Set<String> knownRelativePaths,
    int knownPathsRevision,
    DateTime now,
  ) async {
    final cacheDir = io.Directory(_cacheDir!);
    if (!await cacheDir.exists()) return;

    var liveRelativePaths = knownRelativePaths;
    var livePathsRevision = knownPathsRevision;
    await for (final entity in cacheDir.list()) {
      if (entity is! io.File) continue;

      final relativePath = path.relative(entity.path, from: _cacheDir!);
      if (liveRelativePaths.contains(relativePath)) continue;
      final releasePathDeletion = _cleanup.beginPathDeletion(relativePath);
      if (releasePathDeletion == null) continue;

      try {
        final stat = await entity.stat();
        if (now.difference(stat.modified) < _kOrphanFileGracePeriod) continue;
        if (livePathsRevision != _metadataPathRevision) {
          liveRelativePaths = _currentTrackedPaths();
          livePathsRevision = _metadataPathRevision;
        }
        if (liveRelativePaths.contains(relativePath)) continue;
        await entity.delete();
      } on Object catch (e) {
        cacheLogger.log(
          'CacheManager: Error checking/deleting orphaned file '
          '${entity.path}: $e',
          CacheManagerLogLevel.warning,
        );
      } finally {
        releasePathDeletion();
      }
    }
  }

  Set<String> _currentTrackedPaths() {
    final box = _cacheBox;
    if (box == null || !box.isOpen) return const {};
    final relativePaths = <String>{};
    for (final raw in box.values) {
      relativePaths.add(CacheEntryMetadata.fromMap(raw).relativePath);
    }
    return relativePaths;
  }

  // ---- ImageCacheManager mixin implementation ----

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

    var runningResize = _runningResizes[resizedKey];
    if (runningResize == null) {
      runningResize = _fetchedResizedFile(
        url,
        key,
        resizedKey,
        headers,
        withProgress,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ).asBroadcastStream();
      _runningResizes[resizedKey] = runningResize;
    }
    try {
      yield* runningResize;
    } finally {
      // A consumer can abandon this stream early (for example the image
      // loader refetching after a cached file was evicted mid-read). Without
      // this, the entry would outlive its now-completed broadcast stream and
      // every later call for the same key would attach to it and never emit.
      if (_runningResizes[resizedKey] == runningResize) {
        _runningResizes.remove(resizedKey);
      }
    }
  }

  Stream<FileResponse> _fetchedResizedFile(
    String url,
    String originalKey,
    String resizedKey,
    Map<String, String>? headers,
    bool withProgress, {
    int? maxWidth,
    int? maxHeight,
  }) async* {
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
        yield await _resizeImageFile(
          response,
          resizedKey,
          maxWidth,
          maxHeight,
        );
      }
    }
  }

  Future<FileInfo> _resizeImageFile(
    FileInfo originalFile,
    String key,
    int? maxWidth,
    int? maxHeight,
  ) async {
    final originalFileName = originalFile.file.path;
    final fileExtension = originalFileName.split('.').last;
    if (!_supportedFileNames.contains(fileExtension)) {
      return originalFile;
    }

    // Resizing keeps only the first frame, so leave animated images as-is.
    // Must run before _decodeImage, which never completes for animated
    // images until a frame is pumped.
    final ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(
        await originalFile.file.readAsBytes(),
      );
    } on Object catch (_) {
      // Not decodable here (e.g. SVG served at a .png URL); keep the original.
      return originalFile;
    }
    final isAnimated = codec.frameCount > 1;
    codec.dispose();
    if (isAnimated) return originalFile;

    final image = await _decodeImage(originalFile.file);

    final shouldResize = (maxWidth != null && image.width > maxWidth) ||
        (maxHeight != null && image.height > maxHeight);
    if (!shouldResize) return originalFile;

    if (maxWidth != null && maxHeight != null) {
      final resizeFactorWidth = image.width / maxWidth;
      final resizeFactorHeight = image.height / maxHeight;
      final resizeFactor = max(resizeFactorHeight, resizeFactorWidth);
      maxWidth = (image.width / resizeFactor).round();
      maxHeight = (image.height / resizeFactor).round();
    }

    final resized = await _decodeImage(
      originalFile.file,
      width: maxWidth,
      height: maxHeight,
    );
    final resizedBytes =
        (await resized.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
    final maxAge = originalFile.validTill.difference(clock.now());

    final file = await putFile(
      originalFile.originalUrl,
      resizedBytes,
      key: key,
      maxAge: maxAge,
      fileExtension: fileExtension,
    );

    return FileInfo(
      file,
      originalFile.source,
      originalFile.validTill,
      originalFile.originalUrl,
    );
  }
}

Future<ui.Image> _decodeImage(
  File file, {
  int? width,
  int? height,
  bool allowUpscaling = false,
}) {
  final shouldResize = width != null || height != null;
  final fileImage = FileImage(file as io.File);
  final image = shouldResize
      ? ResizeImage(
          fileImage,
          width: width,
          height: height,
          allowUpscaling: allowUpscaling,
        )
      : fileImage as ImageProvider;
  final completer = Completer<ui.Image>();
  image.resolve(ImageConfiguration.empty).addListener(
    ImageStreamListener((info, _) {
      completer.complete(info.image);
      image.evict();
    }),
  );
  return completer.future;
}
