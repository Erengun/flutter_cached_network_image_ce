import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CachedNetworkImageProvider', () {
    group('equality', () {
      test('same url and scale are equal', () {
        const a = CachedNetworkImageProvider('https://example.com/img.png');
        const b = CachedNetworkImageProvider('https://example.com/img.png');
        expect(a, equals(b));
      });

      test('different url are not equal', () {
        const a = CachedNetworkImageProvider('https://example.com/a.png');
        const b = CachedNetworkImageProvider('https://example.com/b.png');
        expect(a, isNot(equals(b)));
      });

      test('same cacheKey are equal regardless of url', () {
        const a = CachedNetworkImageProvider(
          'https://example.com/a.png',
          cacheKey: 'shared-key',
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/b.png',
          cacheKey: 'shared-key',
        );
        expect(a, equals(b));
      });

      test('different cacheKey are not equal', () {
        const a = CachedNetworkImageProvider(
          'https://example.com/img.png',
          cacheKey: 'key-1',
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/img.png',
          cacheKey: 'key-2',
        );
        expect(a, isNot(equals(b)));
      });

      test('different scale are not equal', () {
        const a = CachedNetworkImageProvider(
          'https://example.com/img.png',
          scale: 1.0,
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/img.png',
          scale: 2.0,
        );
        expect(a, isNot(equals(b)));
      });

      test(
          'providers with different minimumGifFrameDuration values are not equal',
          () {
        const a = CachedNetworkImageProvider(
          'https://example.com/img.png',
          minimumGifFrameDuration: Duration(milliseconds: 100),
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/img.png',
          minimumGifFrameDuration: Duration(milliseconds: 200),
        );

        expect(a, isNot(equals(b)));
      });

      test('different maxHeight are not equal', () {
        const a = CachedNetworkImageProvider(
          'https://example.com/img.png',
          maxHeight: 100,
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/img.png',
          maxHeight: 200,
        );
        expect(a, isNot(equals(b)));
      });

      test('different maxWidth are not equal', () {
        const a = CachedNetworkImageProvider(
          'https://example.com/img.png',
          maxWidth: 100,
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/img.png',
          maxWidth: 200,
        );
        expect(a, isNot(equals(b)));
      });

      test('not equal to non-CachedNetworkImageProvider', () {
        const a = CachedNetworkImageProvider('https://example.com/img.png');
        expect(a == Object(), isFalse);
      });
    });

    group('hashCode', () {
      test('equal objects produce same hashCode', () {
        const a = CachedNetworkImageProvider(
          'https://example.com/img.png',
          scale: 2.0,
          maxHeight: 100,
          maxWidth: 200,
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/img.png',
          scale: 2.0,
          minimumGifFrameDuration: Duration(milliseconds: 100),
          maxHeight: 100,
          maxWidth: 200,
        );
        expect(a.hashCode, equals(b.hashCode));
      });

      test('hashCode uses cacheKey when present', () {
        const a = CachedNetworkImageProvider(
          'https://example.com/a.png',
          cacheKey: 'shared-key',
        );
        const b = CachedNetworkImageProvider(
          'https://example.com/b.png',
          cacheKey: 'shared-key',
        );
        expect(a.hashCode, equals(b.hashCode));
      });
    });

    group('toString', () {
      test('contains url and scale', () {
        const provider = CachedNetworkImageProvider(
          'https://example.com/img.png',
          scale: 2.0,
          minimumGifFrameDuration: Duration(milliseconds: 150),
        );
        final result = provider.toString();
        expect(result, contains('https://example.com/img.png'));
        expect(result, contains('2.0'));
        expect(result, contains('0:00:00.150000'));
      });
    });

    group('obtainKey', () {
      test('returns SynchronousFuture with same instance', () async {
        const provider = CachedNetworkImageProvider(
          'https://example.com/img.png',
        );
        final future = provider.obtainKey(ImageConfiguration.empty);
        expect(future, isA<SynchronousFuture<CachedNetworkImageProvider>>());
        final key = await future;
        expect(key, same(provider));
      });
    });
  });
}
