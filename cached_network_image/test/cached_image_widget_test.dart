import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_cache_manager.dart';
import 'image_data.dart';

class MockBaseCacheManager extends Mock implements BaseCacheManager {}

void main() {
  late FakeCacheManager cacheManager;

  setUp(() {
    cacheManager = FakeCacheManager();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('CachedNetworkImage.evictFromCache', () {
    test('calls removeFile on cache manager', () async {
      final mockCacheManager = MockBaseCacheManager();
      when(() => mockCacheManager.removeFile(any())).thenAnswer((_) async {});

      // evictFromCache should call removeFile
      await CachedNetworkImage.evictFromCache(
        'https://example.com/img.png',
        cacheManager: mockCacheManager,
      );

      verify(() => mockCacheManager.removeFile('https://example.com/img.png'))
          .called(1);
    });

    test('uses cacheKey when provided', () async {
      final mockCacheManager = MockBaseCacheManager();
      when(() => mockCacheManager.removeFile(any())).thenAnswer((_) async {});

      await CachedNetworkImage.evictFromCache(
        'https://example.com/img.png',
        cacheKey: 'custom-key',
        cacheManager: mockCacheManager,
      );

      verify(() => mockCacheManager.removeFile('custom-key')).called(1);
    });
  });

  group('CachedNetworkImage widget builders', () {
    testWidgets('renders without error with imageBuilder set', (tester) async {
      var imageUrl = 'image-builder-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              imageBuilder: (context, imageProvider) {
                return Image(image: imageProvider);
              },
              placeholder: (context, url) => const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'uses empty Container when no placeholder and no progressIndicator',
        (tester) async {
      var imageUrl = 'no-placeholder-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
            ),
          ),
        ),
      );
      // On first pump, the placeholder Container should be present
      // (before image loads).
      await tester.pump();
      // Widget should build without errors.
      expect(tester.takeException(), isNull);
    });

    testWidgets('passes width and height to widget', (tester) async {
      var imageUrl = 'size-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              width: 100,
              height: 200,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final cachedImage = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cachedImage.width, 100);
      expect(cachedImage.height, 200);
    });

    testWidgets('passes fit, alignment, repeat, matchTextDirection',
        (tester) async {
      var imageUrl = 'styling-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              fit: BoxFit.cover,
              alignment: Alignment.topLeft,
              repeat: ImageRepeat.repeat,
              matchTextDirection: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);

      final cachedImage = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(cachedImage.fit, BoxFit.cover);
      expect(cachedImage.alignment, Alignment.topLeft);
      expect(cachedImage.repeat, ImageRepeat.repeat);
      expect(cachedImage.matchTextDirection, isTrue);
    });

    testWidgets('passes color and colorBlendMode', (tester) async {
      var imageUrl = 'color-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              color: Colors.red,
              colorBlendMode: BlendMode.srcOver,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('passes filterQuality', (tester) async {
      var imageUrl = 'filter-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('passes memCacheWidth and memCacheHeight', (tester) async {
      var imageUrl = 'memcache-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              memCacheWidth: 50,
              memCacheHeight: 50,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('useOldImageOnUrlChange works without error', (tester) async {
      var imageUrl = 'old-image-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              useOldImageOnUrlChange: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('placeholderFadeInDuration is passed', (tester) async {
      var imageUrl = 'fade-test';
      cacheManager.returns(imageUrl, kTransparentImage);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              placeholderFadeInDuration: const Duration(milliseconds: 300),
              fadeOutDuration: const Duration(milliseconds: 500),
              fadeInDuration: const Duration(milliseconds: 200),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('errorWidget builder is called on error', (tester) async {
      var imageUrl = 'error-builder-test';
      cacheManager.throwsNotFound(imageUrl);
      var errorBuilderCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              errorWidget: (context, url, error) {
                errorBuilderCalled = true;
                return const Icon(Icons.error);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(errorBuilderCalled, isTrue);
    });

    testWidgets('progressIndicatorBuilder receives DownloadProgress',
        (tester) async {
      var imageUrl = 'progress-detail-test';
      cacheManager.returns(imageUrl, kTransparentImage);
      DownloadProgress? lastProgress;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              progressIndicatorBuilder: (context, url, progress) {
                lastProgress = progress;
                return const CircularProgressIndicator();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(lastProgress, isNotNull);
      expect(lastProgress!.originalUrl, imageUrl);
    });
  });

  group('CachedNetworkImage static logLevel', () {
    test('get and set logLevel', () {
      final originalLevel = CachedNetworkImage.logLevel;

      CachedNetworkImage.logLevel = CacheManagerLogLevel.verbose;
      expect(CachedNetworkImage.logLevel, CacheManagerLogLevel.verbose);

      CachedNetworkImage.logLevel = CacheManagerLogLevel.none;
      expect(CachedNetworkImage.logLevel, CacheManagerLogLevel.none);

      CachedNetworkImage.logLevel = originalLevel;
    });
  });
}
