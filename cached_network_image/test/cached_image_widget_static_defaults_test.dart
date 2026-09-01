import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_cache_manager.dart';
import 'image_data.dart';

void main() {
  late FakeCacheManager cacheManager;

  setUp(() {
    cacheManager = FakeCacheManager();
  });

  tearDown(() {
    CachedNetworkImage.defaultImageBuilder = null;
    CachedNetworkImage.defaultPlaceholder = null;
    CachedNetworkImage.defaultProgressIndicatorBuilder = null;
    CachedNetworkImage.defaultErrorBuilder = null;
    CachedNetworkImage.defaultUnsupportedImageBuilder = null;
    CachedNetworkImage.defaultPlaceholderFadeInDuration = null;
    CachedNetworkImage.defaultErrorListener = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('CachedNetworkImage static defaults', () {
    testWidgets('defaultErrorBuilder is used when errorBuilder is not given',
        (tester) async {
      var imageUrl = 'static-error-builder-test';
      cacheManager.throwsNotFound(imageUrl);
      var called = false;
      CachedNetworkImage.defaultErrorBuilder = (context, error, stackTrace) {
        called = true;
        return const Icon(Icons.error);
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              disablePlaceholderOnCacheHit: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(called, isTrue);
    });

    testWidgets('errorBuilder of the widget wins over defaultErrorBuilder',
        (tester) async {
      var imageUrl = 'static-error-builder-override-test';
      cacheManager.throwsNotFound(imageUrl);
      var staticCalled = false;
      var localCalled = false;
      CachedNetworkImage.defaultErrorBuilder = (context, error, stackTrace) {
        staticCalled = true;
        return const Icon(Icons.error);
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              disablePlaceholderOnCacheHit: false,
              errorBuilder: (context, error, stackTrace) {
                localCalled = true;
                return const Icon(Icons.broken_image);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(localCalled, isTrue);
      expect(staticCalled, isFalse);
    });

    testWidgets('defaultPlaceholder is used when placeholder is not given',
        (tester) async {
      var imageUrl = 'static-placeholder-test';
      cacheManager.returns(imageUrl, kTransparentImage);
      var called = false;
      CachedNetworkImage.defaultPlaceholder = (context, url) {
        called = true;
        return const CircularProgressIndicator();
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              disablePlaceholderOnCacheHit: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(called, isTrue);
    });

    testWidgets(
        'defaultProgressIndicatorBuilder is used when builder is not given',
        (tester) async {
      var imageUrl = 'static-progress-test';
      cacheManager.returns(imageUrl, kTransparentImage);
      DownloadProgress? lastProgress;
      CachedNetworkImage.defaultProgressIndicatorBuilder =
          (context, url, progress) {
        lastProgress = progress;
        return const CircularProgressIndicator();
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              disablePlaceholderOnCacheHit: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(lastProgress, isNotNull);
      expect(lastProgress!.originalUrl, imageUrl);
    });

    test('effective getters fall back to the static defaults', () {
      const widget = CachedNetworkImage(imageUrl: 'effective-getters-test');
      expect(widget.effectiveImageBuilder, isNull);
      expect(widget.effectiveUnsupportedImageBuilder, isNull);
      expect(widget.effectiveErrorListener, isNull);
      expect(widget.effectivePlaceholderFadeInDuration, isNull);

      Widget imageBuilder(BuildContext context, ImageProvider provider) =>
          const SizedBox.shrink();
      Widget unsupportedImageBuilder(
        BuildContext context,
        String url,
        Uint8List bytes,
      ) =>
          const SizedBox.shrink();
      void errorListener(Object error) {}

      CachedNetworkImage.defaultImageBuilder = imageBuilder;
      CachedNetworkImage.defaultUnsupportedImageBuilder =
          unsupportedImageBuilder;
      CachedNetworkImage.defaultErrorListener = errorListener;
      expect(widget.effectiveImageBuilder, imageBuilder);
      expect(widget.effectiveUnsupportedImageBuilder, unsupportedImageBuilder);
      expect(widget.effectiveErrorListener, errorListener);

      CachedNetworkImage.defaultPlaceholderFadeInDuration =
          const Duration(milliseconds: 300);
      expect(
        widget.effectivePlaceholderFadeInDuration,
        const Duration(milliseconds: 300),
      );

      const widgetWithOwnValue = CachedNetworkImage(
        imageUrl: 'effective-getters-test',
        placeholderFadeInDuration: Duration(milliseconds: 50),
      );
      expect(
        widgetWithOwnValue.effectivePlaceholderFadeInDuration,
        const Duration(milliseconds: 50),
      );
    });
  });
}
