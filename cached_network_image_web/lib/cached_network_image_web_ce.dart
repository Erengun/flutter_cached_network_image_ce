/// Web implementation of CachedNetworkImage
library cached_network_image_web_ce;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui_web';

import 'package:cached_network_image_platform_interface_ce'
        '/cached_network_image_platform_interface_ce.dart' as platform
    show ImageLoader, ImageRenderMethodForWeb;
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:flutter/material.dart';

enum _State { open, waitingForData, closing }

/// ImageLoader class to load images on the web platform.
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
    platform.ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) {
    return _load(
      url,
      cacheKey,
      chunkEvents,
      (bytes) async {
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
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
    platform.ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) {
    return _load(
      url,
      cacheKey,
      chunkEvents,
      (bytes) async {
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
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
    _FileDecoderCallback decode,
    BaseCacheManager cacheManager,
    int? maxHeight,
    int? maxWidth,
    Map<String, String>? headers,
    platform.ImageRenderMethodForWeb imageRenderMethodForWeb,
    VoidCallback evictImage,
  ) {
    switch (imageRenderMethodForWeb) {
      case platform.ImageRenderMethodForWeb.HttpGet:
        return _loadAsyncHttpGet(
          url,
          cacheKey,
          chunkEvents,
          decode,
          cacheManager,
          maxHeight,
          maxWidth,
          headers,
          evictImage,
        );
      case platform.ImageRenderMethodForWeb.HtmlImage:
        return _loadAsyncHtmlImage(url, chunkEvents).asStream();
    }
  }

  Stream<ui.Codec> _loadAsyncHttpGet(
    String url,
    String? cacheKey,
    StreamController<ImageChunkEvent> chunkEvents,
    _FileDecoderCallback decode,
    BaseCacheManager cacheManager,
    int? maxHeight,
    int? maxWidth,
    Map<String, String>? headers,
    VoidCallback evictImage,
  ) {
    var streamController = StreamController<ui.Codec>();

    try {
      final stream = cacheManager.getFileStream(
        url,
        withProgress: true,
        headers: headers,
        key: cacheKey,
      );

      var state = _State.open;

      stream.listen(
        (event) {
          if (event is DownloadProgress) {
            chunkEvents.add(
              ImageChunkEvent(
                cumulativeBytesLoaded: event.downloaded,
                expectedTotalBytes: event.totalSize,
              ),
            );
          }
          if (event is FileInfo) {
            if (state == _State.open) {
              state = _State.waitingForData;
            }

            event.file
                .readAsBytes()
                .then((value) {
              final unsupportedFormat =
                  ImageFormatDetector.detectUnsupportedFormat(value);
              if (unsupportedFormat != null) {
                throw UnsupportedImageFormatException(
                  bytes: value,
                  url: url,
                  detectedFormat: unsupportedFormat,
                );
              }
              return decode(value);
            }).then((data) {
              streamController.add(data);
              if (state == _State.closing) {
                streamController.close();
                chunkEvents.close();
              }
            });
          }
        },
        onError: (e, st) {
          scheduleMicrotask(() {
            evictImage();
          });
          streamController.addError(e, st);
        },
        onDone: () async {
          if (state == _State.open) {
            streamController.close();
            chunkEvents.close();
          } else if (state == _State.waitingForData) {
            state = _State.closing;
          }
        },
        cancelOnError: true,
      );
    } on Object catch (e, st) {
      scheduleMicrotask(() {
        evictImage();
      });
      streamController.addError(e, st);
    }

    return streamController.stream;
  }

  Future<ui.Codec> _loadAsyncHtmlImage(
    String url,
    StreamController<ImageChunkEvent> chunkEvents,
  ) {
    final resolved = Uri.base.resolve(url);
    // ignore: undefined_function
    return createImageCodecFromUrl(
      resolved,
      chunkCallback: (int bytes, int total) {
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: bytes,
            expectedTotalBytes: total,
          ),
        );
      },
    );
  }
}

typedef _FileDecoderCallback = Future<ui.Codec> Function(Uint8List);
