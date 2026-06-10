// IMPORTANT: Each runner requires every interceptor to call exactly one handler
// method (next, resolve, or reject). Failing to call any method will cause the
// returned Future to never complete, hanging all downstream callers.
// This is a programming error in the interceptor implementation.

import 'dart:async';

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';

import 'cache_interceptor.dart';
import 'http_interceptor.dart';

// ── HTTP request chain ───────────────────────────────────────────────────────

sealed class HttpRequestOutcome {}

final class HttpRequestProceed extends HttpRequestOutcome {
  HttpRequestProceed(this.data);
  final HttpRequestData data;
}

final class HttpRequestResolved extends HttpRequestOutcome {
  HttpRequestResolved(this.response);
  final HttpResponseData response;
}

// ── HTTP error chain ─────────────────────────────────────────────────────────

sealed class HttpErrorOutcome {}

final class HttpErrorRethrow extends HttpErrorOutcome {
  HttpErrorRethrow(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

final class HttpErrorResolved extends HttpErrorOutcome {
  HttpErrorResolved(this.response);
  final HttpResponseData response;
}

// ── Cache hit chain ──────────────────────────────────────────────────────────

sealed class CacheHitOutcome {}

final class CacheHitReturn extends CacheHitOutcome {
  CacheHitReturn(this.fileInfo);
  final FileInfo fileInfo;
}

final class CacheHitRejected extends CacheHitOutcome {}

// ── Runner functions ─────────────────────────────────────────────────────────

Future<HttpRequestOutcome> runOnRequestChain(
  List<HttpInterceptor> interceptors,
  HttpRequestData initial,
) async {
  if (interceptors.isEmpty) return HttpRequestProceed(initial);

  final completer = Completer<HttpRequestOutcome>();

  void run(int index, HttpRequestData data) {
    if (completer.isCompleted) return;
    if (index >= interceptors.length) {
      completer.complete(HttpRequestProceed(data));
      return;
    }
    final handler = HttpRequestHandler.create(
      (next) => run(index + 1, next),
      (response) => completer.complete(HttpRequestResolved(response)),
      (err, st) => completer.completeError(err, st ?? StackTrace.current),
    );
    try {
      interceptors[index].onRequest(data, handler);
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }
  }

  run(0, initial);
  return completer.future;
}

Future<HttpResponseData> runOnResponseChain(
  List<HttpInterceptor> interceptors,
  HttpResponseData initial,
) async {
  if (interceptors.isEmpty) return initial;

  final completer = Completer<HttpResponseData>();

  void run(int index, HttpResponseData data) {
    if (completer.isCompleted) return;
    if (index >= interceptors.length) {
      completer.complete(data);
      return;
    }
    final handler = HttpResponseHandler.create(
      (next) => run(index + 1, next),
      (response) => completer.complete(response),
      (err, st) => completer.completeError(err, st ?? StackTrace.current),
    );
    try {
      interceptors[index].onResponse(data, handler);
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }
  }

  run(0, initial);
  return completer.future;
}

Future<HttpErrorOutcome> runOnErrorChain(
  List<HttpInterceptor> interceptors,
  Object error,
  StackTrace stackTrace,
) async {
  if (interceptors.isEmpty) return HttpErrorRethrow(error, stackTrace);

  final completer = Completer<HttpErrorOutcome>();

  void run(int index, Object err, StackTrace st) {
    if (completer.isCompleted) return;
    if (index >= interceptors.length) {
      completer.complete(HttpErrorRethrow(err, st));
      return;
    }
    final handler = HttpErrorHandler.create(
      (nextErr, nextSt) => run(index + 1, nextErr, nextSt),
      (response) => completer.complete(HttpErrorResolved(response)),
      (newErr, newSt) =>
          completer.complete(HttpErrorRethrow(newErr, newSt ?? StackTrace.current)),
    );
    try {
      interceptors[index].onError(err, st, handler);
    } catch (e, s) {
      if (!completer.isCompleted) completer.completeError(e, s);
    }
  }

  run(0, error, stackTrace);
  return completer.future;
}

Future<CacheHitOutcome> runOnHitChain(
  List<CacheInterceptor> interceptors,
  CacheHitData initial,
) async {
  if (interceptors.isEmpty) return CacheHitReturn(initial.fileInfo);

  final completer = Completer<CacheHitOutcome>();

  void run(int index, CacheHitData data) {
    if (completer.isCompleted) return;
    if (index >= interceptors.length) {
      completer.complete(CacheHitReturn(data.fileInfo));
      return;
    }
    final handler = CacheHitHandler.create(
      (next) => run(index + 1, next),
      (fileInfo) => completer.complete(CacheHitReturn(fileInfo)),
      () => completer.complete(CacheHitRejected()),
    );
    try {
      interceptors[index].onHit(data, handler);
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }
  }

  run(0, initial);
  return completer.future;
}

Future<FileInfo?> runOnMissChain(
  List<CacheInterceptor> interceptors,
  CacheMissData initial,
) async {
  if (interceptors.isEmpty) return null;

  final completer = Completer<FileInfo?>();

  void run(int index, CacheMissData data) {
    if (completer.isCompleted) return;
    if (index >= interceptors.length) {
      completer.complete(null);
      return;
    }
    final handler = CacheMissHandler.create(
      (next) => run(index + 1, next),
      (fileInfo) => completer.complete(fileInfo),
    );
    try {
      interceptors[index].onMiss(data, handler);
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }
  }

  run(0, initial);
  return completer.future;
}

Future<bool> runOnStoreChain(
  List<CacheInterceptor> interceptors,
  CacheStoreData initial,
) async {
  if (interceptors.isEmpty) return true;

  final completer = Completer<bool>();

  void run(int index, CacheStoreData data) {
    if (completer.isCompleted) return;
    if (index >= interceptors.length) {
      completer.complete(true);
      return;
    }
    final handler = CacheStoreHandler.create(
      (next) => run(index + 1, next),
      () => completer.complete(false),
    );
    try {
      interceptors[index].onStore(data, handler);
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }
  }

  run(0, initial);
  return completer.future;
}
