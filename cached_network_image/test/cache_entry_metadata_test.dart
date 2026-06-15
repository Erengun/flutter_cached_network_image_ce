import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CacheEntryMetadata touchedAt', () {
    test('toMap includes touchedAt when set', () {
      final validTill = DateTime(2025, 6, 15);
      final touchedAt = DateTime(2025, 6, 10, 12, 0, 0);
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/image.png',
        relativePath: 'abc.png',
        validTill: validTill,
        touchedAt: touchedAt,
      );

      final map = metadata.toMap();
      expect(map.containsKey('touchedAt'), isTrue);
      expect(map['touchedAt'], touchedAt.millisecondsSinceEpoch);
    });

    test('toMap omits touchedAt key when null', () {
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/image.png',
        relativePath: 'abc.png',
        validTill: DateTime(2025, 6, 15),
      );

      final map = metadata.toMap();
      expect(map.containsKey('touchedAt'), isFalse);
    });

    test('toMap/fromMap roundtrip preserves touchedAt', () {
      final validTill = DateTime(2025, 6, 15);
      final touchedAt = DateTime(2025, 6, 10, 8, 30, 0);
      final original = CacheEntryMetadata(
        url: 'https://example.com/roundtrip.png',
        relativePath: 'rt.png',
        validTill: validTill,
        touchedAt: touchedAt,
      );

      final reconstructed = CacheEntryMetadata.fromMap(original.toMap());

      expect(
        reconstructed.touchedAt!.millisecondsSinceEpoch,
        touchedAt.millisecondsSinceEpoch,
      );
    });

    test('fromMap returns null touchedAt for legacy data without touchedAt key',
        () {
      final map = {
        'url': 'https://example.com/legacy.png',
        'relativePath': 'legacy.png',
        'validTill': DateTime(2025, 6, 15).millisecondsSinceEpoch,
        'eTag': null,
        'length': 0,
        // no 'touchedAt' key — legacy entry
      };

      final metadata = CacheEntryMetadata.fromMap(map);
      expect(metadata.touchedAt, isNull);
    });

    test('effectiveTouchedAt returns touchedAt when set', () {
      final validTill = DateTime(2025, 6, 15);
      final touchedAt = DateTime(2025, 6, 10);
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/image.png',
        relativePath: 'abc.png',
        validTill: validTill,
        touchedAt: touchedAt,
      );

      expect(metadata.effectiveTouchedAt, touchedAt);
    });

    test('effectiveTouchedAt falls back to validTill when touchedAt is null',
        () {
      final validTill = DateTime(2025, 6, 15);
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/image.png',
        relativePath: 'abc.png',
        validTill: validTill,
      );

      expect(metadata.effectiveTouchedAt, validTill);
    });
  });

  group('CacheEntryMetadata', () {
    test('constructor sets all fields', () {
      final validTill = DateTime(2025, 1, 1);
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/image.png',
        relativePath: 'abc123.png',
        validTill: validTill,
        eTag: '"etag-value"',
        length: 1024,
      );

      expect(metadata.url, 'https://example.com/image.png');
      expect(metadata.relativePath, 'abc123.png');
      expect(metadata.validTill, validTill);
      expect(metadata.eTag, '"etag-value"');
      expect(metadata.length, 1024);
    });

    test('constructor defaults length to 0', () {
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/image.png',
        relativePath: 'abc123.png',
        validTill: DateTime(2025, 1, 1),
      );

      expect(metadata.length, 0);
      expect(metadata.eTag, isNull);
    });

    test('fromMap constructs correctly with all fields', () {
      final map = {
        'url': 'https://example.com/image.png',
        'relativePath': 'abc123.png',
        'validTill': DateTime(2025, 6, 15).millisecondsSinceEpoch,
        'eTag': '"some-etag"',
        'length': 2048,
      };

      final metadata = CacheEntryMetadata.fromMap(map);

      expect(metadata.url, 'https://example.com/image.png');
      expect(metadata.relativePath, 'abc123.png');
      expect(
        metadata.validTill,
        DateTime.fromMillisecondsSinceEpoch(
          DateTime(2025, 6, 15).millisecondsSinceEpoch,
        ),
      );
      expect(metadata.eTag, '"some-etag"');
      expect(metadata.length, 2048);
    });

    test('fromMap defaults length to 0 when missing', () {
      final map = {
        'url': 'https://example.com/image.png',
        'relativePath': 'abc123.png',
        'validTill': DateTime(2025, 1, 1).millisecondsSinceEpoch,
        'eTag': null,
      };

      final metadata = CacheEntryMetadata.fromMap(map);

      expect(metadata.length, 0);
      expect(metadata.eTag, isNull);
    });

    test('toMap serializes correctly', () {
      final validTill = DateTime(2025, 3, 20);
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/test.jpg',
        relativePath: 'def456.jpg',
        validTill: validTill,
        eTag: '"my-etag"',
        length: 512,
      );

      final map = metadata.toMap();

      expect(map['url'], 'https://example.com/test.jpg');
      expect(map['relativePath'], 'def456.jpg');
      expect(map['validTill'], validTill.millisecondsSinceEpoch);
      expect(map['eTag'], '"my-etag"');
      expect(map['length'], 512);
    });

    test('toMap → fromMap roundtrip preserves data', () {
      final original = CacheEntryMetadata(
        url: 'https://example.com/roundtrip.png',
        relativePath: 'roundtrip123.png',
        validTill: DateTime(2025, 12, 31, 23, 59, 59),
        eTag: '"roundtrip-etag"',
        length: 4096,
      );

      final reconstructed = CacheEntryMetadata.fromMap(original.toMap());

      expect(reconstructed.url, original.url);
      expect(reconstructed.relativePath, original.relativePath);
      expect(
        reconstructed.validTill.millisecondsSinceEpoch,
        original.validTill.millisecondsSinceEpoch,
      );
      expect(reconstructed.eTag, original.eTag);
      expect(reconstructed.length, original.length);
    });

    test('toMap with null eTag', () {
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/no-etag.png',
        relativePath: 'noetag.png',
        validTill: DateTime(2025, 1, 1),
      );

      final map = metadata.toMap();
      expect(map['eTag'], isNull);
    });
  });
}
