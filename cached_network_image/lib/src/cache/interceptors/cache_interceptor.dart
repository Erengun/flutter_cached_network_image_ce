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
class CacheHitHandler {
  CacheHitHandler._(this._onNext, this._onResolve, this._onReject);

  final void Function(CacheHitData) _onNext;
  final void Function(FileInfo) _onResolve;
  final void Function() _onReject;

  void next(CacheHitData data) => _onNext(data);
  void resolve(FileInfo fileInfo) => _onResolve(fileInfo);

  /// Force a re-download by treating this hit as a miss.
  void reject() => _onReject();
}

/// Handler for [CacheInterceptor.onMiss].
class CacheMissHandler {
  CacheMissHandler._(this._onNext, this._onResolve);

  final void Function(CacheMissData) _onNext;
  final void Function(FileInfo) _onResolve;

  void next(CacheMissData data) => _onNext(data);

  /// Provide a synthetic [FileInfo] to bypass the download.
  void resolve(FileInfo fileInfo) => _onResolve(fileInfo);
}

/// Handler for [CacheInterceptor.onStore].
class CacheStoreHandler {
  CacheStoreHandler._(this._onNext, this._onReject);

  final void Function(CacheStoreData) _onNext;
  final void Function() _onReject;

  void next(CacheStoreData data) => _onNext(data);

  /// Skip writing this entry to the cache index.
  void reject() => _onReject();
}

/// Abstract interceptor for cache lookup and storage events.
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
