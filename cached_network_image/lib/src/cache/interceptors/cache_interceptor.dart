import 'dart:io' as io;

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';

import '../cache_entry_metadata.dart';

/// Data passed to [CacheInterceptor.onHit].
class CacheHitData {
  const CacheHitData({
    required this.fileInfo,
    required this.key,
    required this.isExpired,
  });

  final FileInfo fileInfo;
  final String key;

  /// True if [fileInfo.validTill] is in the past.
  final bool isExpired;
}

/// Data passed to [CacheInterceptor.onMiss].
class CacheMissData {
  const CacheMissData({required this.key, required this.url});

  final String key;
  final String url;
}

/// Data passed to [CacheInterceptor.onStore].
///
/// Note: [file] is a `dart:io` [File]. This class is only available on
/// native IO platforms (Android, iOS, macOS, Linux, Windows). It is not
/// available on web.
class CacheStoreData {
  const CacheStoreData({
    required this.url,
    required this.key,
    required this.metadata,
    required this.file,
  });

  final String url;
  final String key;
  final CacheEntryMetadata metadata;
  final io.File file;
}

/// Handler for [CacheInterceptor.onHit].
///
/// `.create()` is for internal use by the package only.
class CacheHitHandler {
  CacheHitHandler.create(this._onNext, this._onResolve, this._onReject);

  final void Function(CacheHitData) _onNext;
  final void Function(FileInfo) _onResolve;
  final void Function() _onReject;

  void next(CacheHitData data) => _onNext(data);
  void resolve(FileInfo fileInfo) => _onResolve(fileInfo);

  /// Force a re-download by treating this hit as a miss.
  ///
  /// After rejection, the cache miss path runs (including [CacheInterceptor.onMiss]),
  /// and a fresh download is initiated.
  void reject() => _onReject();
}

/// Handler for [CacheInterceptor.onMiss].
///
/// `.create()` is for internal use by the package only.
class CacheMissHandler {
  CacheMissHandler.create(this._onNext, this._onResolve);

  final void Function(CacheMissData) _onNext;
  final void Function(FileInfo) _onResolve;

  void next(CacheMissData data) => _onNext(data);

  /// Provide a synthetic [FileInfo] to bypass the download.
  void resolve(FileInfo fileInfo) => _onResolve(fileInfo);
}

/// Handler for [CacheInterceptor.onStore].
///
/// `.create()` is for internal use by the package only.
class CacheStoreHandler {
  CacheStoreHandler.create(this._onNext, this._onReject);

  final void Function(CacheStoreData) _onNext;
  final void Function() _onReject;

  void next(CacheStoreData data) => _onNext(data);

  /// Skip writing this entry to the cache index.
  void reject() => _onReject();
}

/// Abstract interceptor for cache lookup and storage events.
///
/// This interceptor is specific to the IO [DefaultCacheManager] and is
/// not available on web targets.
///
/// Override any hook you need; all default to passing through unchanged.
abstract class CacheInterceptor {
  const CacheInterceptor();

  void onHit(CacheHitData data, CacheHitHandler handler) =>
      handler.next(data);

  void onMiss(CacheMissData data, CacheMissHandler handler) =>
      handler.next(data);

  void onStore(CacheStoreData data, CacheStoreHandler handler) =>
      handler.next(data);
}
