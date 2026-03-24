import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
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

export 'cache_entry_metadata.dart';

const _kBoxName = 'cached_network_image_cache';
const _kDefaultMaxAge = Duration(days: 30);
const _kDefaultMaxCacheObjects = 200;
const _kDefaultStalePeriod = Duration(days: 7);

const _supportedFileNames = ['jpg', 'jpeg', 'png', 'tga', 'cur', 'ico'];

/// Sanitizes a key so it doesn't exceed Hive's 255-character limit for string keys.
String _sanitizeBoxKey(String key) {
  if (key.length <= 255) return key;
  final hash = sha256.convert(utf8.encode(key)).toString();
  // 255 max limit. 255 - 64 (sha256 hex length) - 1 (underscore) = 190
  return '${key.substring(0, 190)}_$hash';
}

/// Signature for a function that returns the cache base directory.
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
  /// [httpClientFactory] allows injecting a custom HTTP client (useful for testing).
  /// [cacheDirectoryProvider] allows overriding where cache files are stored.
  ///   Defaults to [getTemporaryDirectory]. Pass [getApplicationSupportDirectory]
  ///   if you need a more persistent location (but note that files may be
  ///   backed up on iOS/Android).
  DefaultCacheManager({
    this.stalePeriod = _kDefaultStalePeriod,
    this.maxNrOfCacheObjects = _kDefaultMaxCacheObjects,
    this.connectionParameters,
    http.Client Function()? httpClientFactory,
    CacheDirectoryProvider? cacheDirectoryProvider,
  })  : _httpClientFactory = httpClientFactory ?? http.Client.new,
        _cacheDirectoryProvider =
            cacheDirectoryProvider ?? getTemporaryDirectory;

  /// Duration before cached files are considered stale.
  final Duration stalePeriod;

  /// Maximum number of objects in the cache before cleanup.
  final int maxNrOfCacheObjects;

  /// Optional connection parameters for HTTP timeouts.
  ///
  /// When `null` (the default), no timeouts are applied and downloads may
  /// wait indefinitely — preserving the existing behaviour.
  final ConnectionParameters? connectionParameters;

  /// Factory for creating HTTP clients (injectable for testing).
  final http.Client Function() _httpClientFactory;

  /// Provider for the base cache directory.
  final CacheDirectoryProvider _cacheDirectoryProvider;

  /// Private Hive instance to avoid conflicts with the host app's global
  /// [Hive] singleton. Each [DefaultCacheManager] gets its own isolated
  /// Hive registry.
  final HiveInterface _hive = HiveImpl();

  Box<Map>? _cacheBox;
  String? _cacheDir;

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
    _cacheDir = path.join(dir.path, 'cached_network_image_ce');
    await io.Directory(_cacheDir!).create(recursive: true);

    final hivePath = path.join(_cacheDir!, 'hive');
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
    }

    // Run cleanup in background
    unawaited(_cleanupOldFiles());
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

    final request = http.Request('GET', Uri.parse(url));
    if (headers != null) {
      request.headers.addAll(headers);
    }

    final client = _httpClientFactory();
    try {
      final connectionTimeout = connectionParameters?.connectionTimeout;
      final response = connectionTimeout != null
          ? await client.send(request).timeout(connectionTimeout)
          : await client.send(request);

      if (response.statusCode != 200 && response.statusCode != 202) {
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

      await _ensureCacheDirectoryExists();

      final tempFilePath =
          '$filePath.${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tempFile = io.File(tempFilePath);
      final sink = tempFile.openWrite();

      final requestTimeout = connectionParameters?.requestTimeout;
      final stream = requestTimeout != null
          ? response.stream.timeout(requestTimeout)
          : response.stream;

      var receivedBytes = 0;
      var movedToFinalPath = false;
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

        final finalFile = io.File(filePath);
        try {
          await tempFile.rename(filePath);
          movedToFinalPath = true;
        } on Object catch (_) {
          io.File? backupFile;
          try {
            if (await finalFile.exists()) {
              final backupPath =
                  '$filePath.${DateTime.now().microsecondsSinceEpoch}.bak';
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
          }

          if (backupFile != null && await backupFile.exists()) {
            try {
              await backupFile.delete();
            } on Object catch (e) {
              cacheLogger.log(
                'CacheManager: Failed to delete backup file for $filePath with error:\n$e',
                CacheManagerLogLevel.warning,
              );
            }
          }
        }
      } on Object catch (_) {
        await sink.close();
        rethrow;
      } finally {
        if (!movedToFinalPath && await tempFile.exists()) {
          await tempFile.delete();
        }
      }

      // Store metadata in Hive
      final validTill = DateTime.now().add(stalePeriod);
      final cacheHeaders = response.headers;
      final eTag = cacheHeaders['etag'];

      await _cacheBox!.put(
          _sanitizeBoxKey(key),
          CacheEntryMetadata(
            url: url,
            relativePath: relativePath,
            validTill: validTill,
            eTag: eTag,
            length: receivedBytes,
          ).toMap());

      final localFile = const LocalFileSystem().file(filePath);
      yield FileInfo(localFile, FileSource.Online, validTill, url);
    } finally {
      client.close();
    }
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    await _ensureInitialized();

    final raw = _cacheBox!.get(_sanitizeBoxKey(key));
    if (raw == null) return null;

    final metadata = CacheEntryMetadata.fromMap(raw);

    final filePath = _cacheFilePath(metadata.relativePath);
    final file = io.File(filePath);
    if (!file.existsSync()) {
      // Metadata exists but file is missing, clean up
      await _cacheBox!.delete(_sanitizeBoxKey(key));
      return null;
    }

    final localFile = const LocalFileSystem().file(filePath);
    return FileInfo(
        localFile, FileSource.Cache, metadata.validTill, metadata.url);
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
    final relativePath = _generateRelativePath(key, fileExtension);
    final filePath = _cacheFilePath(relativePath);

    await _ensureCacheDirectoryExists();

    final file = io.File(filePath);
    await file.writeAsBytes(fileBytes);

    final validTill = DateTime.now().add(maxAge);
    _cacheBox!.put(
        _sanitizeBoxKey(key),
        CacheEntryMetadata(
          url: url,
          relativePath: relativePath,
          validTill: validTill,
          eTag: eTag,
          length: fileBytes.length,
        ).toMap());

    return const LocalFileSystem().file(filePath);
  }

  @override
  Future<void> removeFile(String key) async {
    await _ensureInitialized();

    final raw = _cacheBox!.get(_sanitizeBoxKey(key));
    if (raw != null) {
      final metadata = CacheEntryMetadata.fromMap(raw);
      final file = io.File(_cacheFilePath(metadata.relativePath));
      if (await file.exists()) {
        await file.delete();
      }
      await _cacheBox!.delete(_sanitizeBoxKey(key));
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
  }

  /// Clean up files that haven't been used in a while.
  Future<void> _cleanupOldFiles() async {
    try {
      final now = DateTime.now();
      final entries = <MapEntry<dynamic, CacheEntryMetadata>>[];

      for (final key in _cacheBox!.keys.toList()) {
        final raw = _cacheBox!.get(key);
        if (raw != null) {
          entries.add(MapEntry(key, CacheEntryMetadata.fromMap(raw)));
        }
      }

      // Remove expired entries
      for (final entry in entries) {
        if (entry.value.validTill.isBefore(now)) {
          final file = io.File(_cacheFilePath(entry.value.relativePath));
          if (await file.exists()) {
            await file.delete();
          }
          await _cacheBox!.delete(entry.key);
        }
      }

      // If cache is still too large, remove oldest entries
      if (_cacheBox!.length > maxNrOfCacheObjects) {
        final sortedEntries = entries
            .where((e) => _cacheBox!.containsKey(e.key))
            .toList()
          ..sort((a, b) => a.value.validTill.compareTo(b.value.validTill));

        final toRemove = sortedEntries.length - maxNrOfCacheObjects;
        for (var i = 0; i < toRemove; i++) {
          final entry = sortedEntries[i];
          final file = io.File(_cacheFilePath(entry.value.relativePath));
          if (await file.exists()) {
            await file.delete();
          }
          await _cacheBox!.delete(entry.key);
        }
      }
    } on Object catch (e) {
      cacheLogger.log(
        'CacheManager: Error during cleanup: $e',
        CacheManagerLogLevel.warning,
      );
    }
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
      if (fromCache.validTill.isAfter(DateTime.now())) {
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
    yield* runningResize;
    _runningResizes.remove(resizedKey);
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
    final maxAge = originalFile.validTill.difference(DateTime.now());

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
