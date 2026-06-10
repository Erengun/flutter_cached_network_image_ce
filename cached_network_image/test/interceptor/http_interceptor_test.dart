import 'dart:async';
import 'dart:io' as io;

import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:cached_network_image_ce/src/cache/interceptors/http_interceptor.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

// Minimal PNG bytes (1x1 transparent pixel)
final _pngBytes = Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x62,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

// Each test uses a unique URL to avoid cross-test cache hits.
const _url1 = 'https://example.com/test1.png';
const _url2 = 'https://example.com/test2.png';
const _url3 = 'https://example.com/test3.png';
const _url4 = 'https://example.com/test4.png';
const _url5 = 'https://example.com/test5.png';
const _url6 = 'https://example.com/test6.png';
const _url7 = 'https://example.com/test7.png';
const _url8 = 'https://example.com/404.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory testTempDir;

  setUpAll(() {
    testTempDir =
        io.Directory.systemTemp.createTempSync('http_interceptor_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getTemporaryDirectory') {
          return testTempDir.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    try {
      testTempDir.deleteSync(recursive: true);
    } on Object catch (_) {}
  });

  // Helper: drain a FileResponse stream and return the first FileInfo.
  Future<FileInfo> firstFileInfo(Stream<FileResponse> stream) async {
    await for (final response in stream) {
      if (response is FileInfo) return response;
    }
    throw StateError('No FileInfo in stream');
  }

  group('onRequest interceptor', () {
    test('mutates headers — headers appear in actual HTTP request', () async {
      http.BaseRequest? capturedRequest;
      final mockClient = http_testing.MockClient((request) async {
        capturedRequest = request;
        return http.Response.bytes(_pngBytes, 200);
      });

      const interceptor = _HeaderMutatingInterceptor('X-Custom', 'hello');
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        httpInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      await firstFileInfo(manager.getFileStream(_url1));

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.headers['x-custom'], 'hello');
    });

    test('mutates url — different url is fetched', () async {
      const redirectedUrl = 'https://cdn.example.com/image.png';
      String? fetchedUrl;
      final mockClient = http_testing.MockClient((request) async {
        fetchedUrl = request.url.toString();
        return http.Response.bytes(_pngBytes, 200);
      });

      const interceptor = _UrlMutatingInterceptor(redirectedUrl);
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        httpInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      await firstFileInfo(manager.getFileStream(_url2));

      expect(fetchedUrl, redirectedUrl);
    });

    test('resolve() — client.send() is never called', () async {
      var sendCalled = false;
      final mockClient = http_testing.MockClient((request) async {
        sendCalled = true;
        return http.Response.bytes(_pngBytes, 200);
      });

      final interceptor = _ResolvingRequestInterceptor(_pngBytes);
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        httpInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      final info = await firstFileInfo(manager.getFileStream(_url3));

      expect(sendCalled, isFalse);
      expect(info, isA<FileInfo>());
    });
  });

  group('onResponse interceptor', () {
    test('replaces response body — downstream gets replaced bytes', () async {
      final original = Uint8List.fromList([0, 1, 2, 3]);
      final replacement = _pngBytes;

      final mockClient = http_testing.MockClient((request) async {
        return http.Response.bytes(original, 200);
      });

      final interceptor = _ResponseReplacingInterceptor(replacement);
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        httpInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      final info = await firstFileInfo(manager.getFileStream(_url4));

      final writtenBytes = await info.file.readAsBytes();
      expect(writtenBytes, replacement);
    });

    test('next() passes through — original response is used', () async {
      final mockClient = http_testing.MockClient((request) async {
        return http.Response.bytes(_pngBytes, 200);
      });

      final interceptor = _PassthroughResponseInterceptor();
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        httpInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      final info = await firstFileInfo(manager.getFileStream(_url5));

      final writtenBytes = await info.file.readAsBytes();
      expect(writtenBytes, _pngBytes);
    });
  });

  group('onError interceptor', () {
    test('resolve() on network error — FileInfo returned, no exception',
        () async {
      final mockClient = http_testing.MockClient((request) async {
        throw const io.SocketException('Network unreachable');
      });

      final interceptor = _ErrorResolvingInterceptor(_pngBytes);
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        httpInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      // Should not throw
      final info = await firstFileInfo(manager.getFileStream(_url6));

      expect(info, isA<FileInfo>());
    });

    test('next() on network error — exception propagates to caller', () async {
      final mockClient = http_testing.MockClient((request) async {
        throw const io.SocketException('Network unreachable');
      });

      final interceptor = _PassthroughErrorInterceptor();
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        httpInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      await expectLater(
        firstFileInfo(manager.getFileStream(_url7)),
        throwsA(isA<io.SocketException>()),
      );
    });

    test('onError next() preserves HttpExceptionWithStatus identity for 404',
        () async {
      final interceptor = _PassthroughErrorInterceptor();
      final mockClient =
          http_testing.MockClient((_) async => http.Response('Not Found', 404));

      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheDirectoryProvider: () async => testTempDir,
        httpInterceptors: [interceptor],
      );

      await expectLater(
        manager.getFileStream(_url8).toList(),
        throwsA(
          isA<HttpExceptionWithStatus>()
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
      await manager.dispose();
    });
  });
}

// ── Test interceptor implementations ────────────────────────────────────────

class _HeaderMutatingInterceptor extends HttpInterceptor {
  const _HeaderMutatingInterceptor(this.headerName, this.headerValue);

  final String headerName;
  final String headerValue;

  @override
  void onRequest(HttpRequestData request, HttpRequestHandler handler) {
    request.headers[headerName] = headerValue;
    handler.next(request);
  }
}

class _UrlMutatingInterceptor extends HttpInterceptor {
  const _UrlMutatingInterceptor(this.newUrl);

  final String newUrl;

  @override
  void onRequest(HttpRequestData request, HttpRequestHandler handler) {
    handler.next(HttpRequestData(url: newUrl, headers: request.headers));
  }
}

class _ResolvingRequestInterceptor extends HttpInterceptor {
  const _ResolvingRequestInterceptor(this.bytes);

  final Uint8List bytes;

  @override
  void onRequest(HttpRequestData request, HttpRequestHandler handler) {
    handler.resolve(
      HttpResponseData(
        response: http.StreamedResponse(
          Stream.value(bytes),
          200,
          headers: {},
        ),
        originalUrl: request.url,
      ),
    );
  }
}

class _ResponseReplacingInterceptor extends HttpInterceptor {
  const _ResponseReplacingInterceptor(this.replacementBytes);

  final Uint8List replacementBytes;

  @override
  void onResponse(HttpResponseData response, HttpResponseHandler handler) {
    handler.next(
      HttpResponseData(
        response: http.StreamedResponse(
          Stream.value(replacementBytes),
          200,
          headers: {},
        ),
        originalUrl: response.originalUrl,
      ),
    );
  }
}

class _PassthroughResponseInterceptor extends HttpInterceptor {
  @override
  void onResponse(HttpResponseData response, HttpResponseHandler handler) {
    handler.next(response);
  }
}

class _ErrorResolvingInterceptor extends HttpInterceptor {
  const _ErrorResolvingInterceptor(this.bytes);

  final Uint8List bytes;

  @override
  void onError(Object error, StackTrace stackTrace, HttpErrorHandler handler) {
    handler.resolve(
      HttpResponseData(
        response: http.StreamedResponse(
          Stream.value(bytes),
          200,
          headers: {},
        ),
        originalUrl: 'https://example.com/image.png',
      ),
    );
  }
}

class _PassthroughErrorInterceptor extends HttpInterceptor {
  @override
  void onError(Object error, StackTrace stackTrace, HttpErrorHandler handler) {
    handler.next(error, stackTrace);
  }
}
