import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:file/file.dart';

export 'cache_entry_metadata.dart';

/// Stub [DefaultCacheManager] for unsupported platforms.
///
/// This is used as the fallback in the conditional import and should
/// never actually be instantiated at runtime.
class DefaultCacheManager extends CacheManager with ImageCacheManager {
  DefaultCacheManager({
    Duration stalePeriod = const Duration(days: 7),
    int maxNrOfCacheObjects = 200,
  }) {
    throw UnsupportedError(
      'DefaultCacheManager is not supported on this platform.',
    );
  }

  @override
  Future<void> dispose() => throw UnsupportedError('Unsupported platform');

  @override
  Future<void> emptyCache() => throw UnsupportedError('Unsupported platform');

  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) =>
      throw UnsupportedError('Unsupported platform');

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) =>
      throw UnsupportedError('Unsupported platform');

  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) =>
      throw UnsupportedError('Unsupported platform');

  @override
  Future<File> putFile(
    String url,
    List<int> fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) =>
      throw UnsupportedError('Unsupported platform');

  @override
  Future<void> removeFile(String key) =>
      throw UnsupportedError('Unsupported platform');
}
