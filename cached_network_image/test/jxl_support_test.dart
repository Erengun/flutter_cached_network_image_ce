import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_cache_manager.dart';

/// Bytes that are neither a valid raster image nor SVG text, so the codec is
/// guaranteed to fail to decode them. Deliberately not real JXL bytes: a real
/// JXL sample could actually decode on some host codecs, which would make the
/// test pass for the wrong reason.
final Uint8List kUndecodableBytes = Uint8List.fromList(
  [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07],
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

  group('CachedNetworkImage codec decode failure (e.g. JXL)', () {
    testWidgets(
        'unsupportedImageBuilder is called when the codec fails to decode '
        'bytes', (tester) async {
      const imageUrl = 'undecodable-test';
      cacheManager.returns(imageUrl, kUndecodableBytes);
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
                return const Text('Unsupported rendered');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(receivedUrl, imageUrl);
      expect(receivedBytes, kUndecodableBytes);
      expect(find.text('Unsupported rendered'), findsOneWidget);
    });

    testWidgets(
        'errorWidget receives UnsupportedImageFormatException with null '
        'detectedFormat for a generic decode failure', (tester) async {
      const imageUrl = 'undecodable-error-fallback-test';
      cacheManager.returns(imageUrl, kUndecodableBytes);
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
      expect(
        (receivedError as UnsupportedImageFormatException).detectedFormat,
        isNull,
      );
      expect(find.text('Error fallback'), findsOneWidget);
    });
  });
}
