import 'dart:typed_data';

/// Exception thrown when the image bytes cannot be decoded by Flutter's
/// standard image codec (e.g. SVG images).
///
/// When caught, the [bytes] field contains the raw cached file bytes so that
/// a custom renderer (such as `flutter_svg`) can display the image.
class UnsupportedImageFormatException implements Exception {
  /// Creates an [UnsupportedImageFormatException].
  const UnsupportedImageFormatException({
    required this.bytes,
    required this.url,
    this.detectedFormat,
  });

  /// The raw bytes of the cached file.
  final Uint8List bytes;

  /// The original URL of the image.
  final String url;

  /// The detected image format, e.g. `"svg"`, if known.
  final String? detectedFormat;

  @override
  String toString() {
    final format =
        detectedFormat != null ? ' (detected format: $detectedFormat)' : '';
    return 'UnsupportedImageFormatException: '
        'Image at "$url" could not be decoded by the standard codec$format. '
        'Use unsupportedImageBuilder to supply a custom renderer.';
  }
}
