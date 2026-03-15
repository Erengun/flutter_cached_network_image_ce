// ignore_for_file: deprecated_member_use_from_same_package
@TestOn('browser')
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image_platform_interface_ce'
    '/cached_network_image_platform_interface_ce.dart' hide ImageLoader;
import 'package:cached_network_image_web_ce/cached_network_image_web_ce.dart';
import 'package:file/file.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loadImageAsync returns a stream', () {
    final imageLoader = ImageLoader();
    final stream = imageLoader.loadImageAsync(
      'test.com/image',
      null,
      StreamController<ImageChunkEvent>(),
      decoder,
      MockCacheManager(),
      null,
      null,
      null,
      ImageRenderMethodForWeb.HttpGet,
      () => {},
    );
    expect(stream, isNotNull);
  });

  test('loadBufferAsync returns a stream', () {
    final imageLoader = ImageLoader();
    final stream = imageLoader.loadBufferAsync(
      'test.com/image',
      null,
      StreamController<ImageChunkEvent>(),
      bufferDecoder,
      MockCacheManager(),
      null,
      null,
      null,
      ImageRenderMethodForWeb.HttpGet,
      () => {},
    );
    expect(stream, isNotNull);
  });

  test(
    'loadImageAsync with HtmlImage and headers throws ArgumentError',
    () {
      final imageLoader = ImageLoader();
      expect(
        () => imageLoader.loadImageAsync(
          'test.com/image',
          null,
          StreamController<ImageChunkEvent>(),
          decoder,
          MockCacheManager(),
          null,
          null,
          {'Authorization': 'Bearer token'},
          ImageRenderMethodForWeb.HtmlImage,
          () => {},
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'loadBufferAsync with HtmlImage and headers throws ArgumentError',
    () {
      final imageLoader = ImageLoader();
      expect(
        () => imageLoader.loadBufferAsync(
          'test.com/image',
          null,
          StreamController<ImageChunkEvent>(),
          bufferDecoder,
          MockCacheManager(),
          null,
          null,
          {'Authorization': 'Bearer token'},
          ImageRenderMethodForWeb.HtmlImage,
          () => {},
        ),
        throwsArgumentError,
      );
    },
  );

  test('loadImageAsync with HttpGet and headers works', () {
    final imageLoader = ImageLoader();
    final stream = imageLoader.loadImageAsync(
      'test.com/image',
      null,
      StreamController<ImageChunkEvent>(),
      decoder,
      MockCacheManager(),
      null,
      null,
      {'Authorization': 'Bearer token'},
      ImageRenderMethodForWeb.HttpGet,
      () => {},
    );
    expect(stream, isNotNull);
  });

  test('loadImageAsync with HtmlImage and no headers works', () {
    final imageLoader = ImageLoader();
    // This test would need actual image data to complete the stream,
    // so we just verify that the stream is created without assertion error
    final stream = imageLoader.loadImageAsync(
      'test.com/image',
      null,
      StreamController<ImageChunkEvent>(),
      decoder,
      MockCacheManager(),
      null,
      null,
      null,
      ImageRenderMethodForWeb.HtmlImage,
      () => {},
    );
    expect(stream, isNotNull);
  });
}

Future<ui.Codec> decoder(
  ui.ImmutableBuffer buffer, {
  ui.TargetImageSizeCallback? getTargetSize,
}) {
  throw UnimplementedError();
}

Future<ui.Codec> bufferDecoder(
  ui.ImmutableBuffer buffer, {
  bool allowUpscaling = false,
  int? cacheHeight,
  int? cacheWidth,
}) {
  throw UnimplementedError();
}

class MockCacheManager implements BaseCacheManager {
  @override
  Future<void> dispose() {
    throw UnimplementedError();
  }

  @override
  Future<void> emptyCache() {
    throw UnimplementedError();
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File> putFile(
    String url,
    List<int> fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeFile(String key) {
    throw UnimplementedError();
  }
}
