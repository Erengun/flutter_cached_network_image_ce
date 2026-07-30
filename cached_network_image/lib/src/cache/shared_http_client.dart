import 'dart:async';

import 'package:http/http.dart' as http;

/// Owns a lazily created HTTP client and request-local abort lifecycles.
///
/// Before [dispose], downloads reuse the current client. After [dispose], the
/// manager may still be used, so a new client is created on demand and closed
/// as soon as its last active response is released.
///
/// Completing the abort trigger is sufficient to release an unread response
/// in `BrowserClient`. `IOClient` additionally requires the caller to listen to
/// and cancel an unread response stream after headers have arrived.
final class SharedHttpClient {
  SharedHttpClient(this._clientFactory);

  final http.Client Function() _clientFactory;

  _ClientEntry? _currentEntry;
  bool _closeWhenIdle = false;

  Future<SharedHttpClientResponse> send({
    required Uri uri,
    Map<String, String>? headers,
    Duration? connectionTimeout,
  }) async {
    final entry = _acquire();
    final abortCompleter = Completer<void>();
    try {
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abortCompleter.future,
      );
      if (headers != null && headers.isNotEmpty) {
        request.headers.addAll(headers);
      }

      final sendFuture = entry.client.send(request);
      final response = connectionTimeout == null
          ? await sendFuture
          : await sendFuture.timeout(
              connectionTimeout,
              onTimeout: () {
                abortCompleter.complete();
                throw TimeoutException(
                  'Connection timed out after $connectionTimeout',
                  connectionTimeout,
                );
              },
            );

      return SharedHttpClientResponse._(
        response,
        abortCompleter,
        () => _release(entry),
      );
    } on Object catch (_) {
      if (!abortCompleter.isCompleted) {
        abortCompleter.complete();
      }
      _release(entry);
      rethrow;
    }
  }

  /// Closes the current client and makes future clients close when idle.
  ///
  /// Cache managers in this package support operations after disposal. Keeping
  /// this mode enabled ensures those later operations cannot leave a new
  /// long-lived client behind.
  void dispose() {
    _closeWhenIdle = true;
    final entry = _currentEntry;
    _currentEntry = null;
    entry?.close();
  }

  _ClientEntry _acquire() {
    final entry = _currentEntry ??= _ClientEntry(_clientFactory());
    entry.activeResponses++;
    return entry;
  }

  void _release(_ClientEntry entry) {
    entry.activeResponses--;
    if (_closeWhenIdle &&
        entry.activeResponses == 0 &&
        identical(_currentEntry, entry)) {
      _currentEntry = null;
      entry.close();
    }
  }
}

final class SharedHttpClientResponse {
  SharedHttpClientResponse._(
    this.response,
    this._abortCompleter,
    this._releaseClient,
  );

  final http.StreamedResponse response;
  final Completer<void> _abortCompleter;
  final void Function() _releaseClient;

  bool _released = false;

  /// Ends this response's abort lifecycle and releases its client lease.
  void release() {
    if (_released) return;
    _released = true;
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
    }
    _releaseClient();
  }
}

final class _ClientEntry {
  _ClientEntry(this.client);

  final http.Client client;
  int activeResponses = 0;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    client.close();
  }
}
