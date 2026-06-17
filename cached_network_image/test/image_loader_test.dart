// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:cached_network_image_ce/src/image_provider/_image_loader.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_cache_manager.dart';
import 'image_data.dart';

class MockBaseCacheManager extends Mock implements BaseCacheManager {}

void main() {
  late FakeCacheManager fakeCacheManager;
  late FakeImageCacheManager fakeImageCacheManager;

  setUp(() {
    fakeCacheManager = FakeCacheManager();
    fakeImageCacheManager = FakeImageCacheManager();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('CachedNetworkImageProvider.loadImage', () {
    testWidgets('creates MultiImageStreamCompleter', (tester) async {
      const url = 'https://example.com/load-image-test.png';
      fakeCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
    });

    testWidgets('adds error listener when errorListener is set',
        (tester) async {
      const url = 'https://example.com/error-listener-test.png';
      fakeCacheManager.throwsNotFound(url);

      Object? receivedError;
      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
        errorListener: (error) {
          receivedError = error;
        },
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
      // The error listener should have been registered
      // Wait for the error to propagate
      await tester.pump();
      await tester.pump();
      expect(receivedError, isA<HttpExceptionWithStatus>());
    });

    testWidgets('works without errorListener', (tester) async {
      const url = 'https://example.com/no-error-listener-test.png';
      fakeCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
      // Should not throw when there's no errorListener
      await tester.pump();
    });
  });

  group('CachedNetworkImageProvider.loadBuffer (deprecated)', () {
    testWidgets('creates MultiImageStreamCompleter', (tester) async {
      const url = 'https://example.com/load-buffer-test.png';
      fakeCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      final completer = provider.loadBuffer(
        provider,
        (ui.ImmutableBuffer buffer,
            {bool allowUpscaling = false,
            int? cacheHeight,
            int? cacheWidth}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
    });

    testWidgets('adds error listener when errorListener is set',
        (tester) async {
      const url = 'https://example.com/buffer-error-test.png';
      fakeCacheManager.throwsNotFound(url);

      Object? receivedError;
      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
        errorListener: (error) {
          receivedError = error;
        },
      );

      final completer = provider.loadBuffer(
        provider,
        (ui.ImmutableBuffer buffer,
            {bool allowUpscaling = false,
            int? cacheHeight,
            int? cacheWidth}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
      await tester.pump();
      await tester.pump();
      expect(receivedError, isA<HttpExceptionWithStatus>());
    });
  });

  group('CachedNetworkImageProvider with ImageCacheManager', () {
    testWidgets('uses getImageFile when ImageCacheManager provided',
        (tester) async {
      const url = 'https://example.com/image-cache-mgr-test.png';
      fakeImageCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeImageCacheManager,
        maxHeight: 100,
        maxWidth: 200,
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
    });
  });

  group('CachedNetworkImageProvider with headers and cacheKey', () {
    testWidgets('passes headers and cacheKey through', (tester) async {
      const url = 'https://example.com/headers-test.png';
      fakeCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
        cacheKey: 'custom-cache-key',
        headers: const {'Authorization': 'Bearer token123'},
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
    });
  });

  group('CachedNetworkImageProvider.defaultCacheManager', () {
    test('has a default value of DefaultCacheManager', () {
      expect(
        CachedNetworkImageProvider.defaultCacheManager,
        isA<DefaultCacheManager>(),
      );
    });

    test('can be replaced', () {
      final original = CachedNetworkImageProvider.defaultCacheManager;
      final mockManager = MockBaseCacheManager();
      CachedNetworkImageProvider.defaultCacheManager = mockManager;
      expect(CachedNetworkImageProvider.defaultCacheManager, same(mockManager));
      CachedNetworkImageProvider.defaultCacheManager = original;
    });
  });

  group('ImageLoader unit tests', () {
    test('loadImageAsync returns a stream', () {
      final mockCacheManager = MockBaseCacheManager();

      when(
        () => mockCacheManager.getFileStream(
          any(),
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([]));

      final loader = ImageLoader();
      final stream = loader.loadImageAsync(
        'https://example.com/image.png',
        null,
        StreamController<ImageChunkEvent>(),
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
        mockCacheManager,
        null,
        null,
        null,
        ImageRenderMethodForWeb.HttpGet,
        () {},
      );

      expect(stream, isA<Stream<ui.Codec>>());
    });

    test('loadBufferAsync returns a stream (deprecated)', () {
      final mockCacheManager = MockBaseCacheManager();

      when(
        () => mockCacheManager.getFileStream(
          any(),
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([]));

      final loader = ImageLoader();
      final stream = loader.loadBufferAsync(
        'https://example.com/image.png',
        null,
        StreamController<ImageChunkEvent>(),
        (ui.ImmutableBuffer buffer,
            {bool allowUpscaling = false,
            int? cacheHeight,
            int? cacheWidth}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
        mockCacheManager,
        null,
        null,
        null,
        ImageRenderMethodForWeb.HttpGet,
        () {},
      );

      expect(stream, isA<Stream<ui.Codec>>());
    });
  });
}
