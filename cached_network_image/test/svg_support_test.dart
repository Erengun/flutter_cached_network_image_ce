import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_cache_manager.dart';
import 'image_data.dart';

/// Minimal SVG content for testing.
final List<int> kSvgImage = utf8.encode(
  '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">'
  '<rect width="1" height="1" fill="red"/>'
  '</svg>',
);

/// SVG with XML declaration header.
final List<int> kSvgWithXmlDeclaration = utf8.encode(
  '<?xml version="1.0" encoding="UTF-8"?>\n'
  '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">'
  '<rect width="1" height="1" fill="blue"/>'
  '</svg>',
);

void main() {
  late FakeCacheManager cacheManager;

  setUp(() {
    cacheManager = FakeCacheManager();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('CachedNetworkImage SVG support', () {
    testWidgets('unsupportedImageBuilder is called with SVG bytes',
        (tester) async {
      const imageUrl = 'svg-test';
      cacheManager.returns(imageUrl, kSvgImage);
      Uint8List? receivedBytes;
      String? receivedUrl;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              unsupportedImageBuilder: (context, url, bytes) {
                receivedBytes = bytes;
                receivedUrl = url;
                return const Text('SVG rendered');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(receivedUrl, imageUrl);
      expect(receivedBytes, isNotNull);
      // Verify the bytes contain SVG content.
      final content = utf8.decode(receivedBytes!);
      expect(content, contains('<svg'));
      expect(find.text('SVG rendered'), findsOneWidget);
    });

    testWidgets(
        'unsupportedImageBuilder is called for SVG with XML declaration',
        (tester) async {
      const imageUrl = 'svg-xml-decl-test';
      cacheManager.returns(imageUrl, kSvgWithXmlDeclaration);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              unsupportedImageBuilder: (context, url, bytes) {
                return const Text('XML SVG rendered');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('XML SVG rendered'), findsOneWidget);
    });

    testWidgets(
        'errorWidget receives UnsupportedImageFormatException when '
        'unsupportedImageBuilder is null', (tester) async {
      const imageUrl = 'svg-error-fallback-test';
      cacheManager.returns(imageUrl, kSvgImage);
      Object? receivedError;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              errorWidget: (context, url, error) {
                receivedError = error;
                return const Text('Error fallback');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(receivedError, isA<UnsupportedImageFormatException>());
      expect(find.text('Error fallback'), findsOneWidget);
    });

    testWidgets('regular raster image does not trigger unsupportedImageBuilder',
        (tester) async {
      const imageUrl = 'raster-image-test';
      cacheManager.returns(imageUrl, kTransparentImage);
      var unsupportedCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              unsupportedImageBuilder: (context, url, bytes) {
                unsupportedCalled = true;
                return const Text('Should not appear');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(unsupportedCalled, isFalse);
      expect(find.text('Should not appear'), findsNothing);
    });

    testWidgets(
        'unsupportedImageBuilder takes precedence over errorWidget for SVGs',
        (tester) async {
      const imageUrl = 'svg-precedence-test';
      cacheManager.returns(imageUrl, kSvgImage);
      var errorCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              unsupportedImageBuilder: (context, url, bytes) {
                return const Text('SVG handler');
              },
              errorWidget: (context, url, error) {
                errorCalled = true;
                return const Text('Error handler');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(errorCalled, isFalse);
      expect(find.text('SVG handler'), findsOneWidget);
      expect(find.text('Error handler'), findsNothing);
    });

    testWidgets(
        'errorWidget still works for non-SVG errors when unsupportedImageBuilder is set',
        (tester) async {
      const imageUrl = 'non-svg-error-test';
      cacheManager.throwsNotFound(imageUrl);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CachedNetworkImage(
              imageUrl: imageUrl,
              cacheManager: cacheManager,
              unsupportedImageBuilder: (context, url, bytes) {
                return const Text('Should not appear');
              },
              errorWidget: (context, url, error) {
                return const Text('404 error');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('404 error'), findsOneWidget);
      expect(find.text('Should not appear'), findsNothing);
    });
  });
}
