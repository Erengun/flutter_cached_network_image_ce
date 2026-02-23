import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image_platform_interface_ce/src/image_format_detector.dart';
import 'package:cached_network_image_platform_interface_ce/src/unsupported_image_format_exception.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageFormatDetector.isSvg', () {
    test('detects simple <svg opening tag', () {
      final bytes =
          utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>');
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isTrue);
    });

    test('detects <svg with leading whitespace', () {
      final bytes = utf8.encode('   \n  <svg></svg>');
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isTrue);
    });

    test('detects <svg case-insensitively', () {
      final bytes =
          utf8.encode('<SVG xmlns="http://www.w3.org/2000/svg"></SVG>');
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isTrue);
    });

    test('detects XML declaration followed by <svg', () {
      final bytes = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg"></svg>',
      );
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isTrue);
    });

    test('detects <!DOCTYPE svg', () {
      final bytes = utf8.encode(
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" '
        '"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n'
        '<svg></svg>',
      );
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isTrue);
    });

    test('detects SVG with UTF-8 BOM', () {
      final svgBytes = utf8.encode('<svg></svg>');
      final withBom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...svgBytes]);
      expect(ImageFormatDetector.isSvg(withBom), isTrue);
    });

    test('detects XML with BOM followed by <svg', () {
      final svgBytes = utf8.encode(
        '<?xml version="1.0"?><svg></svg>',
      );
      final withBom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...svgBytes]);
      expect(ImageFormatDetector.isSvg(withBom), isTrue);
    });

    test('returns false for empty bytes', () {
      expect(ImageFormatDetector.isSvg(Uint8List(0)), isFalse);
    });

    test('returns false for PNG bytes', () {
      final pngHeader = Uint8List.fromList(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      );
      expect(ImageFormatDetector.isSvg(pngHeader), isFalse);
    });

    test('returns false for JPEG bytes', () {
      final jpegHeader = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      expect(ImageFormatDetector.isSvg(jpegHeader), isFalse);
    });

    test('returns false for HTML content', () {
      final bytes = utf8.encode(
        '<!DOCTYPE html><html><body>not an svg</body></html>',
      );
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isFalse);
    });

    test('returns false for XML without SVG', () {
      final bytes = utf8.encode(
        '<?xml version="1.0"?><root><child/></root>',
      );
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isFalse);
    });

    test('returns false for just whitespace', () {
      final bytes = utf8.encode('   \n\t  ');
      expect(ImageFormatDetector.isSvg(Uint8List.fromList(bytes)), isFalse);
    });
  });

  group('ImageFormatDetector.detectUnsupportedFormat', () {
    test('returns "svg" for SVG bytes', () {
      final bytes = utf8.encode('<svg></svg>');
      expect(
        ImageFormatDetector.detectUnsupportedFormat(Uint8List.fromList(bytes)),
        equals('svg'),
      );
    });

    test('returns null for PNG bytes', () {
      final pngHeader = Uint8List.fromList(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      );
      expect(
        ImageFormatDetector.detectUnsupportedFormat(pngHeader),
        isNull,
      );
    });
  });

  group('UnsupportedImageFormatException', () {
    test('toString includes URL and format', () {
      final exception = UnsupportedImageFormatException(
        bytes: Uint8List(0),
        url: 'https://example.com/image.svg',
        detectedFormat: 'svg',
      );
      final str = exception.toString();
      expect(str, contains('https://example.com/image.svg'));
      expect(str, contains('svg'));
      expect(str, contains('unsupportedImageBuilder'));
    });

    test('toString works without detected format', () {
      final exception = UnsupportedImageFormatException(
        bytes: Uint8List(0),
        url: 'https://example.com/image',
      );
      final str = exception.toString();
      expect(str, contains('https://example.com/image'));
      expect(str, isNot(contains('detected format')));
    });

    test('holds bytes and url correctly', () {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final exception = UnsupportedImageFormatException(
        bytes: bytes,
        url: 'https://example.com/test.svg',
        detectedFormat: 'svg',
      );
      expect(exception.bytes, same(bytes));
      expect(exception.url, 'https://example.com/test.svg');
      expect(exception.detectedFormat, 'svg');
    });
  });
}
