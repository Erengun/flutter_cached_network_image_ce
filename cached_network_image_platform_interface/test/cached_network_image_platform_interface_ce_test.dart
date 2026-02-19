// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:file/file.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageLoader', () {
    test('Default loadImageAsync throws UnimplementedError', () {
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
          null,
          ImageRenderMethodForWeb.HttpGet,
          () => {},
        ),
        throwsA(const TypeMatcher<UnimplementedError>()),
      );
    });
  });
}

Future<ui.Codec> decoder(
  ui.ImmutableBuffer buffer, {
  ui.TargetImageSizeCallback? getTargetSize,
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
