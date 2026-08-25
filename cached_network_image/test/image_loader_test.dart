// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:cached_network_image_ce/src/image_provider/_image_loader.dart';
import 'package:file/local.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_cache_manager.dart';
import 'image_data.dart';

class MockBaseCacheManager extends Mock implements BaseCacheManager {}

class MockImageCacheManager extends Mock implements ImageCacheManager {}

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

  group('cache file evicted between yield and read', () {
    late io.Directory tempDir;

    setUp(() {
      tempDir = io.Directory.systemTemp.createTempSync('image_loader_race_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } on Object catch (_) {
        // Ignore
      }
    });

    /// Writes [bytes] to a real file under [tempDir] and returns a cache-sourced
    /// [FileInfo] pointing at it.
    FileInfo cacheHit(String url, String name, List<int> bytes) {
      final path = '${tempDir.path}/$name';
      io.File(path).writeAsBytesSync(bytes);
      return FileInfo(
        const LocalFileSystem().file(path),
        FileSource.Cache,
        DateTime.now().add(const Duration(days: 1)),
        url,
      );
    }

    /// A [FileInfo] whose backing file has already been deleted, simulating an
    /// eviction sweep that removed the file after the cache manager yielded it.
    FileInfo evictedCacheHit(String url, String name) {
      final info = cacheHit(url, name, kTransparentImage);
      io.File(info.file.path).deleteSync();
      return info;
    }

    Stream<ui.Codec> load(ImageCacheManager manager, String url) {
      // Drain the chunk events: closing an unlistened StreamController never
      // completes, which would hang _load's finally block.
      final chunkEvents = StreamController<ImageChunkEvent>()
        ..stream.listen((_) {});
      return ImageLoader().loadImageAsync(
        url,
        null,
        chunkEvents,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return ui.instantiateImageCodecFromBuffer(buffer);
        },
        manager,
        null,
        null,
        null,
        ImageRenderMethodForWeb.HttpGet,
        () {},
      );
    }

    test('recovers by refetching when the cached file has been deleted',
        () async {
      const url = 'https://example.com/evicted.png';
      final manager = MockImageCacheManager();

      var call = 0;
      when(
        () => manager.getImageFile(
          url,
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
          maxHeight: any(named: 'maxHeight'),
          maxWidth: any(named: 'maxWidth'),
        ),
      ).thenAnswer((_) {
        call++;
        return Stream<FileResponse>.value(
          call == 1
              ? evictedCacheHit(url, 'gone.png')
              : cacheHit(url, 'fresh.png', kTransparentImage),
        );
      });

      final codecs = await load(manager, url).toList();

      expect(codecs, hasLength(1));
      expect(call, 2, reason: 'should have refetched exactly once');
    });

    test('surfaces the error when the refetch is also missing', () async {
      const url = 'https://example.com/always-evicted.png';
      final manager = MockImageCacheManager();

      var call = 0;
      when(
        () => manager.getImageFile(
          url,
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
          maxHeight: any(named: 'maxHeight'),
          maxWidth: any(named: 'maxWidth'),
        ),
      ).thenAnswer((_) {
        call++;
        return Stream<FileResponse>.value(
          evictedCacheHit(url, 'gone$call.png'),
        );
      });

      await expectLater(
        load(manager, url),
        emitsError(isA<io.PathNotFoundException>()),
      );
      expect(call, 2, reason: 'retry must be capped at one');
    });

    test('does not retry a freshly downloaded file that is missing', () async {
      const url = 'https://example.com/online-missing.png';
      final manager = MockImageCacheManager();

      var call = 0;
      when(
        () => manager.getImageFile(
          url,
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
          maxHeight: any(named: 'maxHeight'),
          maxWidth: any(named: 'maxWidth'),
        ),
      ).thenAnswer((_) {
        call++;
        final gone = evictedCacheHit(url, 'online$call.png');
        return Stream<FileResponse>.value(
          FileInfo(gone.file, FileSource.Online, gone.validTill, url),
        );
      });

      await expectLater(
        load(manager, url),
        emitsError(isA<io.PathNotFoundException>()),
      );
      expect(call, 1, reason: 'an Online result is a different bug; no retry');
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
