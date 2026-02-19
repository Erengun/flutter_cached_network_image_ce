/// An HTTP exception that includes the HTTP status code.
///
/// This replaces `flutter_cache_manager`'s `HttpExceptionWithStatus` and
/// avoids depending on `dart:io`'s `HttpException` which is not available
/// on web.
class HttpExceptionWithStatus implements Exception {
  const HttpExceptionWithStatus(this.statusCode, this.message, {this.uri});

  /// The HTTP status code.
  final int statusCode;

  /// Error message describing the exception.
  final String message;

  /// The URI that caused the exception, if available.
  final Uri? uri;

  @override
  String toString() {
    final buffer = StringBuffer('HttpExceptionWithStatus: $message');
    if (uri != null) {
      buffer.write(', uri = $uri');
    }
    buffer.write(' (status: $statusCode)');
    return buffer.toString();
  }
}
