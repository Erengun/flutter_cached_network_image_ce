import 'dart:typed_data';

/// Utility to detect image formats that are not supported by Flutter's
/// standard image codec (e.g. SVG).
class ImageFormatDetector {
  ImageFormatDetector._();

  /// Returns `true` if [bytes] appear to be an SVG image.
  ///
  /// Checks the first bytes of the content (up to 1024 bytes) for SVG
  /// signatures: `<svg`, `<?xml`, or `<!DOCTYPE svg`.
  /// Also handles a leading UTF-8 BOM (`0xEF 0xBB 0xBF`).
  static bool isSvg(Uint8List bytes) {
    if (bytes.isEmpty) return false;

    var start = 0;

    // Strip UTF-8 BOM if present.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }

    // Only inspect the first ~1024 bytes for performance.
    final end = bytes.length < 1024 ? bytes.length : 1024;
    final header = String.fromCharCodes(bytes, start, end).trimLeft();
    final lower = header.toLowerCase();

    if (lower.startsWith('<svg')) return true;
    if (lower.startsWith('<?xml')) {
      // XML declaration — check if the body contains <svg within the header.
      return lower.contains('<svg');
    }
    if (lower.startsWith('<!doctype svg')) return true;

    return false;
  }

  /// Returns the detected format name for [bytes], or `null` if the format
  /// is supported by Flutter's standard codec.
  ///
  /// Currently only detects SVG. Can be extended for other unsupported
  /// formats in the future.
  static String? detectUnsupportedFormat(Uint8List bytes) {
    if (isSvg(bytes)) return 'svg';
    return null;
  }
}
