import 'package:file/file.dart';

import 'file_response.dart';

/// Log levels of the cache manager. Debug shows failed downloads and verbose
/// also shows successful downloads and cache retrievals.
enum CacheManagerLogLevel {
  none,
  warning,
  debug,
  verbose,
}

/// Logger used by the cache manager to log useful information.
class CacheLogger {
  /// Log a message at a certain log level.
  void log(String message, CacheManagerLogLevel level) {
    if (CacheManager.logLevel.index >= level.index) {
      // ignore: avoid_print
      print(message);
    }
  }
}

/// Global logger instance for the cache manager.
CacheLogger cacheLogger = CacheLogger();

/// Abstract interface for cache managers.
///
/// Provides the minimum API surface needed for caching network files.
/// Implementations should handle downloading, storing, and retrieving
/// cached files.
abstract class BaseCacheManager {
  /// Get the file from the cache and/or online, depending on availability
  /// and age.
  ///
  /// Downloaded from [url], [headers] can be used for example for
  /// authentication. The files are returned as a stream. First the cached
  /// file if available, when the cached file is too old the newly downloaded
  /// file is returned afterwards.
  ///
  /// The [FileResponse] is either a [FileInfo] object for fully downloaded
  /// files or a [DownloadProgress] object for when a file is being downloaded.
  /// The [DownloadProgress] objects are only dispatched when [withProgress] is
  /// set on true and the file is not available in the cache.
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress,
  });

  /// Remove a file from the cache.
  Future<void> removeFile(String key);

  /// Remove all files from the cache.
  Future<void> emptyCache();

  /// Close the cache database.
  Future<void> dispose();

  /// Get the file from the cache.
  Future<FileInfo?> getFileFromCache(String key, {bool ignoreMemCache = false});

  /// Put a file in the cache.
  Future<File> putFile(
    String url,
    List<int> fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  });
}

/// Concrete base implementation of [BaseCacheManager].
///
/// Holds a static [logLevel] that controls logging verbosity across all
/// cache manager instances.
abstract class CacheManager implements BaseCacheManager {
  /// The global log level for all cache manager instances.
  static CacheManagerLogLevel logLevel = CacheManagerLogLevel.none;
}

/// Extended cache manager with image-specific methods.
///
/// Implementations of this mixin provide [getImageFile] which supports
/// fetching and optionally resizing images before caching.
mixin ImageCacheManager on BaseCacheManager {
  /// Returns a resized image file to fit within [maxHeight] and [maxWidth].
  ///
  /// It tries to keep the aspect ratio. It stores the resized image by adding
  /// the size to the key or url. When the resized file is not found in the
  /// cache the original is fetched from the cache or online and stored in
  /// the cache. Then it is resized and returned to the caller.
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  });
}
