import 'dart:io' as io;

import 'package:cached_network_image_ce/src/cache/cache_entry_metadata.dart';
import 'package:cached_network_image_ce/src/cache/interceptors/cache_interceptor.dart';
import 'package:cached_network_image_ce/src/cache/interceptors/http_interceptor.dart';
import 'package:cached_network_image_ce/src/cache/interceptors/interceptor_runner.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

// ── Helpers ──────────────────────────────────────────────────────────────────

HttpRequestData _request({
  String url = 'https://example.com/image.jpg',
  Map<String, String>? headers,
}) =>
    HttpRequestData(url: url, headers: headers ?? {});

HttpResponseData _response({int status = 200, String url = 'https://example.com/image.jpg'}) =>
    HttpResponseData(
      response: http.StreamedResponse(const Stream<List<int>>.empty(), status),
      originalUrl: url,
    );

FileInfo _fileInfo({String url = 'https://example.com/image.jpg'}) {
  final fs = MemoryFileSystem();
  final fakeFile = fs.file('/fake.jpg')..createSync();
  return FileInfo(
    fakeFile,
    FileSource.Cache,
    DateTime.now().add(const Duration(days: 1)),
    url,
  );
}

CacheHitData _hitData({String url = 'https://example.com/image.jpg'}) =>
    CacheHitData(
      fileInfo: _fileInfo(url: url),
      key: url,
      isExpired: false,
    );

CacheMissData _missData({String url = 'https://example.com/image.jpg'}) =>
    CacheMissData(key: url, url: url);

CacheStoreData _storeData({String url = 'https://example.com/image.jpg'}) =>
    CacheStoreData(
      url: url,
      key: url,
      metadata: CacheEntryMetadata(
        validTill: DateTime.now().add(const Duration(days: 1)),
        eTag: null,
        length: 100,
        relativePath: 'fake.jpg',
        url: url,
      ),
      file: io.File('/fake.jpg'),
    );

// ── Inline interceptor stubs ─────────────────────────────────────────────────

class _MutateUrlInterceptor extends HttpInterceptor {
  @override
  void onRequest(HttpRequestData req, HttpRequestHandler handler) {
    req.url = 'https://mutated.example.com/image.jpg';
    handler.next(req);
  }
}

class _MutateHeadersInterceptor extends HttpInterceptor {
  @override
  void onRequest(HttpRequestData req, HttpRequestHandler handler) {
    req.headers['x-custom'] = 'injected';
    handler.next(req);
  }
}

class _ResolveRequestInterceptor extends HttpInterceptor {
  final HttpResponseData resolveWith;
  _ResolveRequestInterceptor(this.resolveWith);

  @override
  void onRequest(HttpRequestData req, HttpRequestHandler handler) =>
      handler.resolve(resolveWith);
}

class _RejectRequestInterceptor extends HttpInterceptor {
  final Object error;
  _RejectRequestInterceptor(this.error);

  @override
  void onRequest(HttpRequestData req, HttpRequestHandler handler) =>
      handler.reject(error);
}

class _MutateResponseInterceptor extends HttpInterceptor {
  final HttpResponseData replacement;
  _MutateResponseInterceptor(this.replacement);

  @override
  void onResponse(HttpResponseData resp, HttpResponseHandler handler) =>
      handler.next(replacement);
}

class _ResolveResponseInterceptor extends HttpInterceptor {
  final HttpResponseData resolveWith;
  _ResolveResponseInterceptor(this.resolveWith);

  @override
  void onResponse(HttpResponseData resp, HttpResponseHandler handler) =>
      handler.resolve(resolveWith);
}

class _RejectResponseInterceptor extends HttpInterceptor {
  final Object error;
  _RejectResponseInterceptor(this.error);

  @override
  void onResponse(HttpResponseData resp, HttpResponseHandler handler) =>
      handler.reject(error);
}

class _NextErrorInterceptor extends HttpInterceptor {
  @override
  void onError(Object error, StackTrace stackTrace, HttpErrorHandler handler) =>
      handler.next(error, stackTrace);
}

class _ResolveErrorInterceptor extends HttpInterceptor {
  final HttpResponseData resolveWith;
  _ResolveErrorInterceptor(this.resolveWith);

  @override
  void onError(Object error, StackTrace stackTrace, HttpErrorHandler handler) =>
      handler.resolve(resolveWith);
}

class _RejectErrorInterceptor extends HttpInterceptor {
  final Object newError;
  _RejectErrorInterceptor(this.newError);

  @override
  void onError(Object error, StackTrace stackTrace, HttpErrorHandler handler) =>
      handler.reject(newError);
}

class _RejectHitInterceptor extends CacheInterceptor {
  @override
  void onHit(CacheHitData data, CacheHitHandler handler) => handler.reject();
}

class _ResolveHitInterceptor extends CacheInterceptor {
  final FileInfo resolveWith;
  _ResolveHitInterceptor(this.resolveWith);

  @override
  void onHit(CacheHitData data, CacheHitHandler handler) =>
      handler.resolve(resolveWith);
}

class _ResolveMissInterceptor extends CacheInterceptor {
  final FileInfo resolveWith;
  _ResolveMissInterceptor(this.resolveWith);

  @override
  void onMiss(CacheMissData data, CacheMissHandler handler) =>
      handler.resolve(resolveWith);
}

class _RejectStoreInterceptor extends CacheInterceptor {
  @override
  void onStore(CacheStoreData data, CacheStoreHandler handler) =>
      handler.reject();
}

/// A no-op cache interceptor that passes everything through unchanged.
class _PassThroughCacheInterceptor extends CacheInterceptor {
  const _PassThroughCacheInterceptor();
}

// ── Minimal tracking interceptors ─────────────────────────────────────────────

class _CallTrackingInterceptor extends HttpInterceptor {
  final void Function() onCalled;
  _CallTrackingInterceptor(this.onCalled);

  @override
  void onRequest(HttpRequestData req, HttpRequestHandler handler) {
    onCalled();
    handler.next(req);
  }
}

class _CallTrackingResponseInterceptor extends HttpInterceptor {
  final void Function() onCalled;
  _CallTrackingResponseInterceptor(this.onCalled);

  @override
  void onResponse(HttpResponseData resp, HttpResponseHandler handler) {
    onCalled();
    handler.next(resp);
  }
}

class _ThrowingRequestInterceptor extends HttpInterceptor {
  final Object error;
  _ThrowingRequestInterceptor(this.error);

  @override
  void onRequest(HttpRequestData req, HttpRequestHandler handler) =>
      throw error;
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── runOnRequestChain ──────────────────────────────────────────────────────

  group('runOnRequestChain', () {
    test('empty list returns initial data unchanged', () async {
      final req = _request(url: 'https://original.com/img.jpg');
      final result = await runOnRequestChain([], req);
      expect(result, isA<HttpRequestProceed>());
      expect((result as HttpRequestProceed).data.url, 'https://original.com/img.jpg');
    });

    test('single interceptor calling next() passes data through', () async {
      final result = await runOnRequestChain([_MutateUrlInterceptor()], _request());
      expect(result, isA<HttpRequestProceed>());
      expect(
        (result as HttpRequestProceed).data.url,
        'https://mutated.example.com/image.jpg',
      );
    });

    test('two interceptors: first mutates url, second mutates headers', () async {
      final result = await runOnRequestChain(
        [_MutateUrlInterceptor(), _MutateHeadersInterceptor()],
        _request(),
      );
      expect(result, isA<HttpRequestProceed>());
      final proceed = result as HttpRequestProceed;
      expect(proceed.data.url, 'https://mutated.example.com/image.jpg');
      expect(proceed.data.headers['x-custom'], 'injected');
    });

    test('resolve() short-circuits: second interceptor not called, result is HttpRequestResolved',
        () async {
      var secondCalled = false;
      final second = _CallTrackingInterceptor(() => secondCalled = true);
      final resolveResp = _response();

      final result = await runOnRequestChain(
        [_ResolveRequestInterceptor(resolveResp), second],
        _request(),
      );

      expect(result, isA<HttpRequestResolved>());
      expect(secondCalled, isFalse);
    });

    test('reject() throws the provided error', () async {
      final error = Exception('request rejected');
      await expectLater(
        runOnRequestChain([_RejectRequestInterceptor(error)], _request()),
        throwsA(same(error)),
      );
    });

    test('synchronous throw in interceptor propagates as future error', () async {
      final error = Exception('sync throw');
      await expectLater(
        runOnRequestChain([_ThrowingRequestInterceptor(error)], _request()),
        throwsA(same(error)),
      );
    });

    test('first calls next() with modified data then second calls resolve()', () async {
      final resolveResp = _response(status: 201);
      final result = await runOnRequestChain(
        [_MutateUrlInterceptor(), _ResolveRequestInterceptor(resolveResp)],
        _request(),
      );
      expect(result, isA<HttpRequestResolved>());
      expect(
        (result as HttpRequestResolved).response.response.statusCode,
        201,
      );
    });
  });

  // ── runOnResponseChain ─────────────────────────────────────────────────────

  group('runOnResponseChain', () {
    test('empty list returns initial response unchanged', () async {
      final resp = _response(status: 200);
      final result = await runOnResponseChain([], resp);
      expect(result.response.statusCode, 200);
    });

    test('next() passes through all interceptors', () async {
      final replacement = _response(status: 204);
      final result = await runOnResponseChain(
        [_MutateResponseInterceptor(replacement)],
        _response(status: 200),
      );
      expect(result.response.statusCode, 204);
    });

    test('resolve() short-circuits with the new response', () async {
      final resolveResp = _response(status: 201);
      var secondCalled = false;
      final second = _CallTrackingResponseInterceptor(() => secondCalled = true);

      final result = await runOnResponseChain(
        [_ResolveResponseInterceptor(resolveResp), second],
        _response(),
      );
      expect(result.response.statusCode, 201);
      expect(secondCalled, isFalse);
    });

    test('reject() throws', () async {
      final error = Exception('response rejected');
      await expectLater(
        runOnResponseChain([_RejectResponseInterceptor(error)], _response()),
        throwsA(same(error)),
      );
    });
  });

  // ── runOnErrorChain ────────────────────────────────────────────────────────

  group('runOnErrorChain', () {
    final originalError = Exception('original error');
    final originalSt = StackTrace.current;

    test('empty list returns HttpErrorRethrow with original error', () async {
      final result = await runOnErrorChain([], originalError, originalSt);
      expect(result, isA<HttpErrorRethrow>());
      expect((result as HttpErrorRethrow).error, same(originalError));
    });

    test('next() propagates to HttpErrorRethrow', () async {
      final result = await runOnErrorChain(
        [_NextErrorInterceptor()],
        originalError,
        originalSt,
      );
      expect(result, isA<HttpErrorRethrow>());
      expect((result as HttpErrorRethrow).error, same(originalError));
    });

    test('resolve() returns HttpErrorResolved with the provided response', () async {
      final resolveResp = _response(status: 200);
      final result = await runOnErrorChain(
        [_ResolveErrorInterceptor(resolveResp)],
        originalError,
        originalSt,
      );
      expect(result, isA<HttpErrorResolved>());
      expect((result as HttpErrorResolved).response.response.statusCode, 200);
    });

    test('reject() with a new error returns HttpErrorRethrow with the new error', () async {
      final newError = Exception('new error');
      final result = await runOnErrorChain(
        [_RejectErrorInterceptor(newError)],
        originalError,
        originalSt,
      );
      expect(result, isA<HttpErrorRethrow>());
      expect((result as HttpErrorRethrow).error, same(newError));
    });
  });

  // ── runOnHitChain ──────────────────────────────────────────────────────────

  group('runOnHitChain', () {
    test('empty list returns CacheHitReturn with original FileInfo', () async {
      final hit = _hitData();
      final result = await runOnHitChain([], hit);
      expect(result, isA<CacheHitReturn>());
      expect((result as CacheHitReturn).fileInfo, same(hit.fileInfo));
    });

    test('next() passes through, returns CacheHitReturn', () async {
      final hit = _hitData();
      final result = await runOnHitChain([const _PassThroughCacheInterceptor()], hit);
      expect(result, isA<CacheHitReturn>());
    });

    test('resolve() returns CacheHitReturn with the modified FileInfo', () async {
      final customFileInfo = _fileInfo(url: 'https://modified.com/image.jpg');
      final result = await runOnHitChain(
        [_ResolveHitInterceptor(customFileInfo)],
        _hitData(),
      );
      expect(result, isA<CacheHitReturn>());
      expect((result as CacheHitReturn).fileInfo, same(customFileInfo));
    });

    test('reject() returns CacheHitRejected', () async {
      final result = await runOnHitChain([_RejectHitInterceptor()], _hitData());
      expect(result, isA<CacheHitRejected>());
    });

    test('two interceptors: first passes through, second rejects → returns CacheHitRejected',
        () async {
      final result = await runOnHitChain(
        [const _PassThroughCacheInterceptor(), _RejectHitInterceptor()],
        _hitData(),
      );
      expect(result, isA<CacheHitRejected>());
    });
  });

  // ── runOnMissChain ─────────────────────────────────────────────────────────

  group('runOnMissChain', () {
    test('empty list returns null (proceed to download)', () async {
      final result = await runOnMissChain([], _missData());
      expect(result, isNull);
    });

    test('next() returns null', () async {
      final result = await runOnMissChain([const _PassThroughCacheInterceptor()], _missData());
      expect(result, isNull);
    });

    test('resolve() returns the provided FileInfo', () async {
      final syntheticFileInfo = _fileInfo(url: 'https://synthetic.com/image.jpg');
      final result = await runOnMissChain(
        [_ResolveMissInterceptor(syntheticFileInfo)],
        _missData(),
      );
      expect(result, same(syntheticFileInfo));
    });
  });

  // ── runOnStoreChain ────────────────────────────────────────────────────────

  group('runOnStoreChain', () {
    test('empty list returns true', () async {
      final result = await runOnStoreChain([], _storeData());
      expect(result, isTrue);
    });

    test('next() returns true', () async {
      final result = await runOnStoreChain([const _PassThroughCacheInterceptor()], _storeData());
      expect(result, isTrue);
    });

    test('reject() returns false', () async {
      final result = await runOnStoreChain([_RejectStoreInterceptor()], _storeData());
      expect(result, isFalse);
    });

    test('two interceptors: first passes through, second rejects → returns false', () async {
      final result = await runOnStoreChain(
        [const _PassThroughCacheInterceptor(), _RejectStoreInterceptor()],
        _storeData(),
      );
      expect(result, isFalse);
    });
  });
}
