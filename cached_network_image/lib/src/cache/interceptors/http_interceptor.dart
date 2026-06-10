import 'package:http/http.dart' as http;

/// Mutable request data passed through the HTTP interceptor chain.
///
/// Interceptors may mutate [url] and [headers] in-place, or replace them
/// entirely before calling [HttpRequestHandler.next]. Once [next] is called,
/// further mutations to this object have no effect on subsequent interceptors —
/// the chain runner passes the value at the time [next] was called.
class HttpRequestData {
  HttpRequestData({required this.url, required this.headers});

  String url;
  Map<String, String> headers;
}

/// Immutable response data passed through the HTTP interceptor chain.
class HttpResponseData {
  const HttpResponseData({required this.response, required this.originalUrl});

  final http.StreamedResponse response;
  final String originalUrl;
}

/// Handler for [HttpInterceptor.onRequest].
///
/// Call exactly one of [next], [resolve], or [reject].
///
/// `.create()` is for internal use by the package only.
class HttpRequestHandler {
  HttpRequestHandler.create(this._onNext, this._onResolve, this._onReject);

  final void Function(HttpRequestData) _onNext;
  final void Function(HttpResponseData) _onResolve;
  final void Function(Object, StackTrace?) _onReject;

  void next(HttpRequestData request) => _onNext(request);
  void resolve(HttpResponseData response) => _onResolve(response);
  void reject(Object error, [StackTrace? stackTrace]) =>
      _onReject(error, stackTrace);
}

/// Handler for [HttpInterceptor.onResponse].
///
/// Call [next] to pass the response (possibly replaced) to the next interceptor,
/// [resolve] to short-circuit with a specific response, or [reject] to turn
/// the response into an error.
///
/// `.create()` is for internal use by the package only.
class HttpResponseHandler {
  HttpResponseHandler.create(this._onNext, this._onResolve, this._onReject);

  final void Function(HttpResponseData) _onNext;
  final void Function(HttpResponseData) _onResolve;
  final void Function(Object, StackTrace?) _onReject;

  void next(HttpResponseData response) => _onNext(response);
  void resolve(HttpResponseData response) => _onResolve(response);
  void reject(Object error, [StackTrace? stackTrace]) =>
      _onReject(error, stackTrace);
}

/// Handler for [HttpInterceptor.onError].
///
/// `.create()` is for internal use by the package only.
class HttpErrorHandler {
  HttpErrorHandler.create(this._onNext, this._onResolve, this._onReject);

  final void Function(Object, StackTrace) _onNext;
  final void Function(HttpResponseData) _onResolve;
  final void Function(Object, StackTrace?) _onReject;

  void next(Object error, StackTrace stackTrace) => _onNext(error, stackTrace);
  void resolve(HttpResponseData response) => _onResolve(response);
  void reject(Object error, [StackTrace? stackTrace]) =>
      _onReject(error, stackTrace);
}

/// Abstract interceptor for HTTP requests and responses.
///
/// Override any hook you need; all default to passing through unchanged.
///
/// Each hook receives a typed data object and a handler. You MUST call
/// exactly one of [handler.next], [handler.resolve], or [handler.reject]:
/// - [next]: pass (possibly mutated) data to the next interceptor
/// - [resolve]: short-circuit the chain with a synthetic response
/// - [reject]: short-circuit the chain with an error
abstract class HttpInterceptor {
  const HttpInterceptor();

  void onRequest(HttpRequestData request, HttpRequestHandler handler) =>
      handler.next(request);

  void onResponse(HttpResponseData response, HttpResponseHandler handler) =>
      handler.next(response);

  void onError(
    Object error,
    StackTrace stackTrace,
    HttpErrorHandler handler,
  ) =>
      handler.next(error, stackTrace);
}
