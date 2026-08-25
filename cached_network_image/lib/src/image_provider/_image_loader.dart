import 'dart:async';
import 'dart:io' show PathNotFoundException;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:cached_network_image_platform_interface_ce'
        '/cached_network_image_platform_interface_ce.dart' as platform
    show ImageLoader;
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:flutter/material.dart';

/// ImageLoader class to load images on IO platforms.
class ImageLoader implements platform.ImageLoader {
  @Deprecated('Use loadImageAsync instead')
  @override
  Stream<ui.Codec> loadBufferAsync(
    String url,
    String? cacheKey,
    StreamController<ImageChunkEvent> chunkEvents,
    DecoderBufferCallback decode,
    BaseCacheManager cacheManager,
    int? maxHeight,
    int? maxWidth,
    Map<String, String>? headers,
    ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) {
    return _load(
      url,
      cacheKey,
      chunkEvents,
      (bytes) async {
        final buffer = await ImmutableBuffer.fromUint8List(bytes);
        return decode(buffer);
      },
      cacheManager,
      maxHeight,
      maxWidth,
      headers,
      imageRenderMethodForWeb,
      evictImage,
    );
  }

  @override
  Stream<ui.Codec> loadImageAsync(
    String url,
    String? cacheKey,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
    BaseCacheManager cacheManager,
    int? maxHeight,
    int? maxWidth,
    Map<String, String>? headers,
    ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) {
    return _load(
      url,
      cacheKey,
      chunkEvents,
      (bytes) async {
        final buffer = await ImmutableBuffer.fromUint8List(bytes);
        return decode(buffer);
      },
      cacheManager,
      maxHeight,
      maxWidth,
      headers,
      imageRenderMethodForWeb,
      evictImage,
    );
  }

  Stream<ui.Codec> _load(
    String url,
    String? cacheKey,
    StreamController<ImageChunkEvent> chunkEvents,
    Future<ui.Codec> Function(Uint8List) decode,
    BaseCacheManager cacheManager,
    int? maxHeight,
    int? maxWidth,
    Map<String, String>? headers,
    ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) async* {
    try {
      assert(
          cacheManager is ImageCacheManager ||
              (maxWidth == null && maxHeight == null),
          'To resize the image with a CacheManager the '
          'CacheManager needs to be an ImageCacheManager. maxWidth and '
          'maxHeight will be ignored when a normal CacheManager is used.');

      // A cache manager can delete a cached file during its own eviction
      // sweep after it has already handed out the FileInfo pointing at it,
      // which leaves the read below throwing PathNotFoundException for a file
      // the cache reported as valid. Fetching again turns that into an
      // ordinary cache miss and a fresh download. One extra attempt only, so
      // a genuinely unreadable cache directory cannot spin.
      var mayRefetch = true;
      var refetch = true;

      while (refetch) {
        refetch = false;

        final stream = cacheManager is ImageCacheManager
            ? cacheManager.getImageFile(
                url,
                maxHeight: maxHeight,
                maxWidth: maxWidth,
                withProgress: true,
                headers: headers,
                key: cacheKey,
              )
            : cacheManager.getFileStream(
                url,
                withProgress: true,
                headers: headers,
                key: cacheKey,
              );

        // Set when the read below already ruled a refetch out, so the handler
        // around the loop does not second-guess that as the error unwinds.
        var refetchDeclined = false;
        try {
          await for (final result in stream) {
            if (result is DownloadProgress) {
              chunkEvents.add(
                ImageChunkEvent(
                  cumulativeBytesLoaded: result.downloaded,
                  expectedTotalBytes: result.totalSize,
                ),
              );
            }
            if (result is FileInfo) {
              final file = result.file;
              Uint8List? bytes;
              try {
                bytes = await file.readAsBytes();
              } on PathNotFoundException {
                // Only a cached file can be evicted out from under us. A
                // missing file on a just-downloaded result is a different
                // defect and must stay visible.
                if (!mayRefetch || result.source != FileSource.Cache) {
                  refetchDeclined = true;
                  rethrow;
                }
                refetch = true;
              }
              if (bytes == null) break;
              final unsupportedFormat =
                  ImageFormatDetector.detectUnsupportedFormat(bytes);
              if (unsupportedFormat != null) {
                throw UnsupportedImageFormatException(
                  bytes: bytes,
                  url: url,
                  detectedFormat: unsupportedFormat,
                );
              }
              final ui.Codec decoded;
              try {
                decoded = await decode(bytes);
              } catch (_) {
                throw UnsupportedImageFormatException(bytes: bytes, url: url);
              }
              yield decoded;
            }
          }
        } on PathNotFoundException {
          // The same race, reached while the cache manager itself read a
          // cached file: resizing reads the original entry, which is
          // separately evictable.
          if (!mayRefetch || refetchDeclined) rethrow;
          refetch = true;
        }

        if (refetch) mayRefetch = false;
      }
    } on Object catch (error, stackTrace) {
      // Depending on where the exception was thrown, the image cache may not
      // have had a chance to track the key in the cache at all.
      // Schedule a microtask to give the cache a chance to add the key.
      scheduleMicrotask(() {
        evictImage();
      });
      yield* Stream.error(error, stackTrace);
    } finally {
      await chunkEvents.close();
    }
  }
}
