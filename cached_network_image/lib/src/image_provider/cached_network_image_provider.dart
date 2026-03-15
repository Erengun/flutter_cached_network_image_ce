import 'dart:async' show Future, StreamController;
import 'dart:ui' as ui show Codec;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart'
    if (dart.library.io) '_image_loader.dart'
    if (dart.library.js_interop) 'package:cached_network_image_web_ce/cached_network_image_web_ce.dart'
    show ImageLoader;
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart'
    show ErrorListener, ImageRenderMethodForWeb;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// IO implementation of the CachedNetworkImageProvider; the ImageProvider to
/// load network images using a cache.
@immutable
class CachedNetworkImageProvider
    extends ImageProvider<CachedNetworkImageProvider> {
  /// Creates an ImageProvider which loads an image from the [url], using the [scale].
  /// When the image fails to load [errorListener] is called.
  const CachedNetworkImageProvider(
    this.url, {
    this.maxHeight,
    this.maxWidth,
    this.scale = 1.0,
    this.errorListener,
    this.headers,
    this.cacheManager,
    this.cacheKey,
    this.imageRenderMethodForWeb = ImageRenderMethodForWeb.HtmlImage,
  });

  /// CacheManager from which the image files are loaded.
  final BaseCacheManager? cacheManager;

  /// The default cache manager used for image caching.
  static BaseCacheManager defaultCacheManager = DefaultCacheManager();

  /// Web url of the image to load
  final String url;

  /// Cache key of the image to cache
  final String? cacheKey;

  /// Scale of the image
  final double scale;

  /// Listener to be called when images fails to load.
  ///
  /// Note: Using this listener with Flutter versions older than 3.16 may
  /// cause a memory leak if the image fails to load. Please upgrade Flutter
  /// to avoid this issue.
  final ErrorListener? errorListener;

  /// Set headers for the image provider, for example for authentication.
  ///
  /// **Note on Flutter Web:** Headers are only supported when using
  /// [ImageRenderMethodForWeb.HttpGet] render method. The default
  /// [ImageRenderMethodForWeb.HtmlImage] does not support custom headers.
  /// If you provide headers on Web, you must also set
  /// `imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet`.
  final Map<String, String>? headers;

  /// Maximum height of the loaded image. If not null and using an
  /// [ImageCacheManager] the image is resized on disk to fit the height.
  final int? maxHeight;

  /// Maximum width of the loaded image. If not null and using an
  /// [ImageCacheManager] the image is resized on disk to fit the width.
  final int? maxWidth;

  /// Render option for images on the web platform.
  final ImageRenderMethodForWeb imageRenderMethodForWeb;

  @override
  Future<CachedNetworkImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) {
    return SynchronousFuture<CachedNetworkImageProvider>(this);
  }

  @Deprecated('loadBuffer is deprecated, use loadImage instead')
  @override
  ImageStreamCompleter loadBuffer(
    CachedNetworkImageProvider key,
    DecoderBufferCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    final imageStreamCompleter = MultiImageStreamCompleter(
      codec: _loadBufferAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedNetworkImageProvider>('Image key', key),
      ],
    );

    if (errorListener != null) {
      // In Flutter >= 3.16, we use addEphemeralErrorListener to avoid memory leaks.
      // addListener keeps the ImageStreamCompleter alive, which prevents disposal
      // when there are no other active listeners.
      try {
        (imageStreamCompleter as dynamic).addEphemeralErrorListener(
          (Object error, StackTrace? trace) {
            errorListener?.call(error);
          },
        );
      } on NoSuchMethodError {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception:
                'Warning: Using errorListener with Flutter < 3.16 causes memory leaks. '
                'Please upgrade Flutter or avoid using errorListener.',
            library: 'cached_network_image',
            context: ErrorDescription(
              'CachedNetworkImageProvider.loadBuffer fallback to addListener',
            ),
          ),
        );
        imageStreamCompleter.addListener(
          ImageStreamListener(
            (image, synchronousCall) {},
            onError: (Object error, StackTrace? trace) {
              errorListener?.call(error);
            },
          ),
        );
      }
    }

    return imageStreamCompleter;
  }

  @Deprecated('_loadBufferAsync is deprecated, use _loadImageAsync instead')
  Stream<ui.Codec> _loadBufferAsync(
    CachedNetworkImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    DecoderBufferCallback decode,
  ) {
    assert(key == this);
    return ImageLoader().loadBufferAsync(
      url,
      cacheKey,
      chunkEvents,
      decode,
      cacheManager ?? defaultCacheManager,
      maxHeight,
      maxWidth,
      headers,
      imageRenderMethodForWeb,
      () => PaintingBinding.instance.imageCache.evict(key),
    );
  }

  @override
  ImageStreamCompleter loadImage(
    CachedNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    final imageStreamCompleter = MultiImageStreamCompleter(
      codec: _loadImageAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: key.scale,
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<CachedNetworkImageProvider>('Image key', key),
      ],
    );

    if (errorListener != null) {
      // In Flutter >= 3.16, we use addEphemeralErrorListener to avoid memory leaks.
      // addListener keeps the ImageStreamCompleter alive, which prevents disposal
      // when there are no other active listeners.
      try {
        (imageStreamCompleter as dynamic).addEphemeralErrorListener(
          (Object error, StackTrace? trace) {
            errorListener?.call(error);
          },
        );
      } on NoSuchMethodError {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception:
                'Warning: Using errorListener with Flutter < 3.16 causes memory leaks. '
                'Please upgrade Flutter or avoid using errorListener.',
            library: 'cached_network_image',
            context: ErrorDescription(
              'CachedNetworkImageProvider.loadImage fallback to addListener',
            ),
          ),
        );
        imageStreamCompleter.addListener(
          ImageStreamListener(
            (image, synchronousCall) {},
            onError: (Object error, StackTrace? trace) {
              errorListener?.call(error);
            },
          ),
        );
      }
    }

    return imageStreamCompleter;
  }

  Stream<ui.Codec> _loadImageAsync(
    CachedNetworkImageProvider key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) {
    assert(key == this);
    return ImageLoader().loadImageAsync(
      url,
      cacheKey,
      chunkEvents,
      decode,
      cacheManager ?? defaultCacheManager,
      maxHeight,
      maxWidth,
      headers,
      imageRenderMethodForWeb,
      () => PaintingBinding.instance.imageCache.evict(key),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is CachedNetworkImageProvider) {
      return ((cacheKey ?? url) == (other.cacheKey ?? other.url)) &&
          scale == other.scale &&
          maxHeight == other.maxHeight &&
          maxWidth == other.maxWidth;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(cacheKey ?? url, scale, maxHeight, maxWidth);

  @override
  String toString() => 'CachedNetworkImageProvider("$url", scale: $scale)';
}
