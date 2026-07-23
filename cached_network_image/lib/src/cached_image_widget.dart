import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:octo_image/octo_image.dart';

/// Builder function to create an image widget. The function is called after
/// the ImageProvider completes the image loading.
typedef ImageWidgetBuilder = Widget Function(
  BuildContext context,
  ImageProvider imageProvider,
);

/// Builder function to create a placeholder widget. The function is called
/// once while the ImageProvider is loading the image.
typedef PlaceholderWidgetBuilder = Widget Function(
  BuildContext context,
  String url,
);

/// Builder function to create a progress indicator widget. The function is
/// called every time a chuck of the image is downloaded from the web, but at
/// least once during image loading.
typedef ProgressIndicatorBuilder = Widget Function(
  BuildContext context,
  String url,
  DownloadProgress progress,
);

/// Builder function to create an error widget. This builder is called when
/// the image failed loading, for example due to a 404 NotFound exception.
typedef LoadingErrorWidgetBuilder = Widget Function(
  BuildContext context,
  String url,
  Object error,
);

/// Builder function to create a widget for images whose format is not
/// supported by Flutter's standard image codec (e.g. SVG).
///
/// The [bytes] parameter contains the raw cached file bytes. Use a package
/// like `flutter_svg` to render them:
///
/// ```dart
/// CachedNetworkImage(
///   imageUrl: 'https://example.com/image.svg',
///   unsupportedImageBuilder: (context, url, bytes) {
///     return SvgPicture.memory(bytes);
///   },
/// )
/// ```
typedef UnsupportedImageWidgetBuilder = Widget Function(
  BuildContext context,
  String url,
  Uint8List bytes,
);

/// Image widget to show NetworkImage with caching functionality.
class CachedNetworkImage extends StatefulWidget {
  /// Get the current log level of the cache manager.
  static CacheManagerLogLevel get logLevel => CacheManager.logLevel;

  /// Set the log level of the cache manager to a [CacheManagerLogLevel].
  static set logLevel(CacheManagerLogLevel level) =>
      CacheManager.logLevel = level;

  /// Evict an image from both the disk file based caching system of the
  /// [BaseCacheManager] as the in memory [ImageCache] of the [ImageProvider].
  /// [url] is used by both the disk and memory cache. The scale is only used
  /// to clear the image from the [ImageCache].
  static Future<bool> evictFromCache(
    String url, {
    String? cacheKey,
    BaseCacheManager? cacheManager,
    double scale = 1,
    Duration minimumGifFrameDuration = const Duration(milliseconds: 100),
  }) async {
    final effectiveCacheManager =
        cacheManager ?? CachedNetworkImageProvider.defaultCacheManager;
    await effectiveCacheManager.removeFile(cacheKey ?? url);
    return CachedNetworkImageProvider(
      url,
      scale: scale,
      minimumGifFrameDuration: minimumGifFrameDuration,
    ).evict();
  }

  /// Option to use cacheManager with other settings
  final BaseCacheManager? cacheManager;

  /// The target image that is displayed.
  final String imageUrl;

  /// The target image's cache key.
  final String? cacheKey;

  /// Optional builder to further customize the display of the image.
  final ImageWidgetBuilder? imageBuilder;

  /// Widget displayed while the target [imageUrl] is loading.
  final PlaceholderWidgetBuilder? placeholder;

  /// Widget displayed while the target [imageUrl] is loading.
  final ProgressIndicatorBuilder? progressIndicatorBuilder;

  /// Widget displayed while the target [imageUrl] failed loading.
  @Deprecated('Use errorBuilder instead.')
  final LoadingErrorWidgetBuilder? errorWidget;

  /// Builder displayed while the target [imageUrl] failed loading.
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Builder for images whose format is not supported by Flutter's standard
  /// image codec (e.g. SVG, or any other format the codec fails to decode,
  /// such as JXL, AVIF, or HEIC on platforms without native support).
  ///
  /// When set, the image is still downloaded and cached normally. If the
  /// cached bytes cannot be decoded as a raster image, this builder is called
  /// with the raw bytes so you can render them with a custom package such as
  /// `flutter_svg`.
  ///
  /// If this is `null` and the image format is unsupported, the
  /// [errorWidget] builder is called instead (with an
  /// [UnsupportedImageFormatException]).
  final UnsupportedImageWidgetBuilder? unsupportedImageBuilder;

  /// The duration of the fade-in animation for the [placeholder].
  final Duration? placeholderFadeInDuration;

  /// The duration of the fade-out animation for the [placeholder].
  final Duration? fadeOutDuration;

  /// The curve of the fade-out animation for the [placeholder].
  final Curve fadeOutCurve;

  /// The duration of the fade-in animation for the [imageUrl].
  final Duration fadeInDuration;

  /// The curve of the fade-in animation for the [imageUrl].
  final Curve fadeInCurve;

  /// If non-null, require the image to have this width.
  ///
  /// If null, the image will pick a size that best preserves its intrinsic
  /// aspect ratio. This may result in a sudden change if the size of the
  /// placeholder widget does not match that of the target image. The size is
  /// also affected by the scale factor.
  final double? width;

  /// If non-null, require the image to have this height.
  ///
  /// If null, the image will pick a size that best preserves its intrinsic
  /// aspect ratio. This may result in a sudden change if the size of the
  /// placeholder widget does not match that of the target image. The size is
  /// also affected by the scale factor.
  final double? height;

  /// How to inscribe the image into the space allocated during layout.
  ///
  /// The default varies based on the other fields. See the discussion at
  /// [paintImage].
  final BoxFit? fit;

  /// How to align the image within its bounds.
  ///
  /// The alignment aligns the given position in the image to the given position
  /// in the layout bounds. For example, a [Alignment] alignment of (-1.0,
  /// -1.0) aligns the image to the top-left corner of its layout bounds, while a
  /// [Alignment] alignment of (1.0, 1.0) aligns the bottom right of the
  /// image with the bottom right corner of its layout bounds. Similarly, an
  /// alignment of (0.0, 1.0) aligns the bottom middle of the image with the
  /// middle of the bottom edge of its layout bounds.
  ///
  /// If the [alignment] is [TextDirection]-dependent (i.e. if it is a
  /// [AlignmentDirectional]), then an ambient [Directionality] widget
  /// must be in scope.
  ///
  /// Defaults to [Alignment.center].
  ///
  /// See also:
  ///
  ///  * [Alignment], a class with convenient constants typically used to
  ///    specify an [AlignmentGeometry].
  ///  * [AlignmentDirectional], like [Alignment] for specifying alignments
  ///    relative to text direction.
  final Alignment alignment;

  /// How to paint any portions of the layout bounds not covered by the image.
  final ImageRepeat repeat;

  /// Whether to paint the image in the direction of the [TextDirection].
  ///
  /// If this is true, then in [TextDirection.ltr] contexts, the image will be
  /// drawn with its origin in the top left (the "normal" painting direction for
  /// children); and in [TextDirection.rtl] contexts, the image will be drawn with
  /// a scaling factor of -1 in the horizontal direction so that the origin is
  /// in the top right.
  ///
  /// This is occasionally used with children in right-to-left environments, for
  /// children that were designed for left-to-right locales. Be careful, when
  /// using this, to not flip children with integral shadows, text, or other
  /// effects that will look incorrect when flipped.
  ///
  /// If this is true, there must be an ambient [Directionality] widget in
  /// scope.
  final bool matchTextDirection;

  /// Optional headers for the http request of the image url.
  ///
  /// **Note on Flutter Web:** Headers are only supported when using
  /// [ImageRenderMethodForWeb.HttpGet] render method. The default
  /// [ImageRenderMethodForWeb.HtmlImage] does not support custom headers.
  /// If you provide headers on Web, you must also set
  /// `imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet`.
  final Map<String, String>? httpHeaders;

  /// When set to true it will animate from the old image to the new image
  /// if the url changes.
  final bool useOldImageOnUrlChange;

  /// If non-null, this color is blended with each image pixel using [colorBlendMode].
  final Color? color;

  /// Used to combine [color] with this image.
  ///
  /// The default is [BlendMode.srcIn]. In terms of the blend mode, [color] is
  /// the source and this image is the destination.
  ///
  /// See also:
  ///
  ///  * [BlendMode], which includes an illustration of the effect of each blend mode.
  final BlendMode? colorBlendMode;

  /// Target the interpolation quality for image scaling.
  ///
  /// If not given a value, defaults to FilterQuality.low.
  final FilterQuality filterQuality;

  /// Will resize the image in memory to have a certain width using [ResizeImage]
  final int? memCacheWidth;

  /// Will resize the image in memory to have a certain height using [ResizeImage]
  final int? memCacheHeight;

  /// Will resize the image and store the resized image in the disk cache.
  final int? maxWidthDiskCache;

  /// Will resize the image and store the resized image in the disk cache.
  final int? maxHeightDiskCache;

  /// Listener to be called when images fails to load.
  final ValueChanged<Object>? errorListener;

  /// Render option for images on the web platform.
  final ImageRenderMethodForWeb imageRenderMethodForWeb;

  /// Scale of the image.
  final double scale;

  /// The minimum frame duration applied to GIF images when decoded frame
  /// durations are extremely short.
  final Duration minimumGifFrameDuration;

  /// When true (the default), the placeholder and fade-in/out animations are
  /// skipped when the image is already available in the disk cache. This
  /// prevents an unnecessary visual flicker for images that load almost
  /// instantly from cache.
  ///
  /// Set to `false` to always show the placeholder and fade animations,
  /// regardless of cache status.
  final bool disablePlaceholderOnCacheHit;

  /// CachedNetworkImage shows a network image using a caching mechanism. It also
  /// provides support for a placeholder, showing an error and fading into the
  /// loaded image. Next to that it supports most features of a default Image
  /// widget.
  const CachedNetworkImage({
    super.key,
    required this.imageUrl,
    this.httpHeaders,
    this.imageBuilder,
    this.placeholder,
    this.progressIndicatorBuilder,
    @Deprecated('Use errorBuilder instead.') this.errorWidget,
    this.errorBuilder,
    this.unsupportedImageBuilder,
    this.fadeOutDuration = const Duration(milliseconds: 1000),
    this.fadeOutCurve = Curves.easeOut,
    this.fadeInDuration = const Duration(milliseconds: 500),
    this.fadeInCurve = Curves.easeIn,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.matchTextDirection = false,
    this.cacheManager,
    this.useOldImageOnUrlChange = false,
    this.color,
    this.filterQuality = FilterQuality.low,
    this.colorBlendMode,
    this.placeholderFadeInDuration,
    this.memCacheWidth,
    this.memCacheHeight,
    this.cacheKey,
    this.maxWidthDiskCache,
    this.maxHeightDiskCache,
    this.errorListener,
    this.imageRenderMethodForWeb = ImageRenderMethodForWeb.HtmlImage,
    this.scale = 1.0,
    this.minimumGifFrameDuration = const Duration(milliseconds: 100),
    this.disablePlaceholderOnCacheHit = true,
  });

  @override
  State<CachedNetworkImage> createState() => _CachedNetworkImageState();
}

class _CachedNetworkImageState extends State<CachedNetworkImage> {
  late CachedNetworkImageProvider _image;

  /// Whether the placeholder should be suppressed because the image is
  /// available in the disk cache (and will load almost instantly).
  ///
  /// Starts as `true` (optimistic) when [disablePlaceholderOnCacheHit] is
  /// enabled. If the async cache check reveals the image is NOT cached, this
  /// flips to `false` and the placeholder appears via [setState].
  bool _skipPlaceholder = false;

  /// Incremented each time [_preCheckCache] is called so that stale async
  /// completions (from a previous URL or config) are discarded.
  int _preCheckGeneration = 0;

  @override
  void initState() {
    super.initState();
    _createImageProvider();
    if (widget.disablePlaceholderOnCacheHit) {
      _skipPlaceholder = true;
      _preCheckCache();
    }
  }

  @override
  void didUpdateWidget(CachedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final imageConfigChanged = oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.cacheKey != widget.cacheKey ||
        oldWidget.cacheManager != widget.cacheManager ||
        oldWidget.httpHeaders != widget.httpHeaders ||
        oldWidget.maxWidthDiskCache != widget.maxWidthDiskCache ||
        oldWidget.maxHeightDiskCache != widget.maxHeightDiskCache ||
        oldWidget.imageRenderMethodForWeb != widget.imageRenderMethodForWeb ||
        oldWidget.scale != widget.scale ||
        oldWidget.minimumGifFrameDuration != widget.minimumGifFrameDuration ||
        oldWidget.errorListener != widget.errorListener;

    if (imageConfigChanged) {
      _createImageProvider();
    }

    if (imageConfigChanged ||
        oldWidget.disablePlaceholderOnCacheHit !=
            widget.disablePlaceholderOnCacheHit) {
      if (widget.disablePlaceholderOnCacheHit) {
        _skipPlaceholder = true;
        _preCheckCache();
      } else {
        _skipPlaceholder = false;
      }
    }
  }

  void _createImageProvider() {
    _image = CachedNetworkImageProvider(
      widget.imageUrl,
      headers: widget.httpHeaders,
      cacheManager: widget.cacheManager,
      cacheKey: widget.cacheKey,
      imageRenderMethodForWeb: widget.imageRenderMethodForWeb,
      maxWidth: widget.maxWidthDiskCache,
      maxHeight: widget.maxHeightDiskCache,
      errorListener: widget.errorListener,
      scale: widget.scale,
      minimumGifFrameDuration: widget.minimumGifFrameDuration,
    );
  }

  Future<void> _preCheckCache() async {
    final generation = ++_preCheckGeneration;
    final cm =
        widget.cacheManager ?? CachedNetworkImageProvider.defaultCacheManager;
    try {
      final cached =
          await cm.getFileFromCache(widget.cacheKey ?? widget.imageUrl);
      if (generation != _preCheckGeneration) return;
      if (mounted && cached == null) {
        setState(() => _skipPlaceholder = false);
      }
    } on Object catch (_) {
      if (generation != _preCheckGeneration) return;
      // If the cache check fails, fall back to showing the placeholder.
      if (mounted) {
        setState(() => _skipPlaceholder = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasCustomBuilder = widget.imageBuilder != null ||
        widget.placeholder != null ||
        widget.progressIndicatorBuilder != null ||
        widget.errorWidget != null ||
        widget.errorBuilder != null ||
        widget.unsupportedImageBuilder != null;

    OctoPlaceholderBuilder? octoPlaceholderBuilder;
    OctoProgressIndicatorBuilder? octoProgressIndicatorBuilder;
    Duration? effectiveFadeOutDuration = widget.fadeOutDuration;
    Duration effectiveFadeInDuration = widget.fadeInDuration;
    Duration? effectivePlaceholderFadeInDuration =
        widget.placeholderFadeInDuration;

    if (_skipPlaceholder) {
      // Image is in disk cache — skip placeholder and fade animations
      // so the image appears instantly.
      octoPlaceholderBuilder = null;
      octoProgressIndicatorBuilder = null;
      effectiveFadeOutDuration = Duration.zero;
      effectiveFadeInDuration = Duration.zero;
      effectivePlaceholderFadeInDuration = Duration.zero;
    } else {
      octoPlaceholderBuilder =
          widget.placeholder != null ? _octoPlaceholderBuilder : null;
      octoProgressIndicatorBuilder = widget.progressIndicatorBuilder != null
          ? _octoProgressIndicatorBuilder
          : null;

      /// If there is no placeholder OctoImage does not fade, so always set an
      /// (empty) placeholder as this always used to be the behaviour of
      /// CachedNetworkImage.
      if (octoPlaceholderBuilder == null &&
          octoProgressIndicatorBuilder == null) {
        octoPlaceholderBuilder = (context) => Container();
      }
    }

    return OctoImage(
      image: _image,
      imageBuilder: widget.imageBuilder != null ? _octoImageBuilder : null,
      placeholderBuilder: octoPlaceholderBuilder,
      progressIndicatorBuilder: octoProgressIndicatorBuilder,
      errorBuilder: hasCustomBuilder ? _octoErrorBuilder : null,
      fadeOutDuration: effectiveFadeOutDuration,
      fadeOutCurve: widget.fadeOutCurve,
      fadeInDuration: effectiveFadeInDuration,
      fadeInCurve: widget.fadeInCurve,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      repeat: widget.repeat,
      matchTextDirection: widget.matchTextDirection,
      color: widget.color,
      filterQuality: widget.filterQuality,
      colorBlendMode: widget.colorBlendMode,
      placeholderFadeInDuration: effectivePlaceholderFadeInDuration,
      gaplessPlayback: widget.useOldImageOnUrlChange,
      memCacheWidth: widget.memCacheWidth,
      memCacheHeight: widget.memCacheHeight,
    );
  }

  Widget _octoImageBuilder(BuildContext context, Widget child) {
    return widget.imageBuilder!(context, _image);
  }

  Widget _octoPlaceholderBuilder(BuildContext context) {
    return widget.placeholder!(context, widget.imageUrl);
  }

  Widget _octoProgressIndicatorBuilder(
    BuildContext context,
    ImageChunkEvent? progress,
  ) {
    int? totalSize;
    var downloaded = 0;
    if (progress != null) {
      totalSize = progress.expectedTotalBytes;
      downloaded = progress.cumulativeBytesLoaded;
    }
    return widget.progressIndicatorBuilder!(
      context,
      widget.imageUrl,
      DownloadProgress(widget.imageUrl, totalSize, downloaded),
    );
  }

  Widget _octoErrorBuilder(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    if (error is UnsupportedImageFormatException &&
        widget.unsupportedImageBuilder != null) {
      return widget.unsupportedImageBuilder!(
          context, widget.imageUrl, error.bytes);
    }
    if (widget.errorBuilder != null) {
      return widget.errorBuilder!(context, error, stackTrace);
    }
    if (widget.errorWidget != null) {
      return widget.errorWidget!(context, widget.imageUrl, error);
    }
    return const SizedBox.shrink();
  }
}
