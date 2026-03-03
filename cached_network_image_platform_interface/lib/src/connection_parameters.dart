import 'package:flutter/foundation.dart' show immutable;

/// Configuration for HTTP connection and request timeouts used by
/// [DefaultCacheManager] when downloading files.
///
/// Both timeouts are optional. When the entire [ConnectionParameters] object
/// is `null` (the default), the cache manager preserves its current behaviour
/// of waiting indefinitely.
///
/// Example:
/// ```dart
/// DefaultCacheManager(
///   connectionParameters: ConnectionParameters(
///     connectionTimeout: Duration(seconds: 10),
///     requestTimeout: Duration(seconds: 30),
///   ),
/// )
/// ```
@immutable
class ConnectionParameters {
  /// Creates connection parameters for the cache manager.
  ///
  /// [connectionTimeout] limits how long to wait for the server to respond
  /// with headers (i.e. the TCP connection + TLS handshake + first response).
  /// A [TimeoutException] is thrown if the server does not respond in time.
  ///
  /// [requestTimeout] limits how long to wait between consecutive data chunks
  /// while streaming the response body. This is an *inactivity* timeout — it
  /// does **not** cap the total download duration. A slow-but-progressing
  /// download will never be interrupted. A [TimeoutException] is thrown if no
  /// data arrives within the specified duration.
  ConnectionParameters({
    this.connectionTimeout,
    this.requestTimeout,
  }) {
    if (connectionTimeout != null && connectionTimeout!.isNegative) {
      throw ArgumentError.value(
        connectionTimeout,
        'connectionTimeout',
        'Must be greater than or equal to zero.',
      );
    }
    if (requestTimeout != null && requestTimeout!.isNegative) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be greater than or equal to zero.',
      );
    }
  }

  /// Maximum duration to wait for the server to respond with headers.
  ///
  /// When `null`, no connection timeout is applied.
  final Duration? connectionTimeout;

  /// Maximum duration to wait between consecutive data chunks during
  /// the response stream.
  ///
  /// This is an *inactivity* (idle) timeout, not a total download timeout.
  /// When `null`, no request timeout is applied.
  final Duration? requestTimeout;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionParameters &&
          runtimeType == other.runtimeType &&
          connectionTimeout == other.connectionTimeout &&
          requestTimeout == other.requestTimeout;

  @override
  int get hashCode => Object.hash(connectionTimeout, requestTimeout);

  @override
  String toString() => 'ConnectionParameters('
      'connectionTimeout: $connectionTimeout, '
      'requestTimeout: $requestTimeout)';
}
