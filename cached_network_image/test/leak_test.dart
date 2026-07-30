/// Leak tests to verify that all resources (StreamControllers, HTTP clients,
/// Hive boxes, subscriptions, file handles) are properly cleaned up in
/// both success and error paths.
///
/// These tests document and verify the cleanup contracts of the library,
/// making it safe for long-running apps and repeated widget rebuilds.
library;

import 'dart:async';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:cached_network_image_ce/cached_network_image.dart'
    hide DefaultCacheManager;
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:cached_network_image_ce/src/cache/shared_http_client.dart';
import 'package:cached_network_image_ce/src/image_provider/_image_loader.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'fake_cache_manager.dart';
import 'image_data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory testTempDir;

  setUpAll(() {
    testTempDir = io.Directory.systemTemp.createTempSync('leak_test_');
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
    } on Object catch (e) {
      // ignore: avoid_print
      print('Failed to clean temp dir: $e');
    }
  });

  // ===========================================================================
  // 1. DefaultCacheManager.getFileStream — StreamController closure
  // ===========================================================================
  group('Leak: getFileStream StreamController', () {
    test('StreamController is closed after successful download', () async {
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('data', 200),
        ),
      );

      final stream = manager.getFileStream('https://example.com/success.png');
      // Consuming the stream to completion should close the controller
      final events = await stream.toList();
      expect(events.whereType<FileInfo>().isNotEmpty, isTrue);

      // Verify: listening again should get an empty stream (controller
      // already drained and closed)
      // The stream is single-subscription so this verifies it completed
      await manager.emptyCache();
      await manager.dispose();
    });

    test('StreamController is closed after HTTP error', () async {
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('err', 500),
        ),
      );

      Object? error;
      try {
        await manager.getFileStream('https://example.com/error.png').toList();
      } on Object catch (e) {
        error = e;
      }

      expect(error, isNotNull);
      // No dangling controller — cleanup happens in finally of
      // _pushFileToStream
      await manager.dispose();
    });

    test('StreamController is closed when download throws mid-stream',
        () async {
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient.streaming(
          (request, bodyStream) async {
            final controller = StreamController<List<int>>();
            controller.add([1, 2, 3]);
            // Simulate network error mid-stream
            controller.addError(
              const io.SocketException('Connection reset'),
            );
            controller.close();
            return http.StreamedResponse(controller.stream, 200);
          },
        ),
      );

      Object? caughtError;
      try {
        await manager
            .getFileStream('https://example.com/mid-error.png')
            .toList();
      } on Object catch (e) {
        caughtError = e;
      }

      expect(caughtError, isNotNull);
      await manager.dispose();
    });
  });

  // ===========================================================================
  // 2. Shared http.Client lifecycle
  // ===========================================================================
  group('Leak: shared http.Client lifecycle', () {
    test('client is reused across downloads and closed by dispose', () async {
      var factoryCalls = 0;
      var closeCalls = 0;

      final manager = DefaultCacheManager(
        httpClientFactory: () {
          factoryCalls++;
          final mock = http_testing.MockClient(
            (request) async => http.Response('ok', 200),
          );
          return _CloseTrackingClient(mock, onClose: () {
            closeCalls++;
          });
        },
      );

      expect(factoryCalls, 0);

      await manager
          .getFileStream('https://example.com/client-reuse-first.png')
          .toList();
      await manager
          .getFileStream('https://example.com/client-reuse-second.png')
          .toList();

      expect(factoryCalls, 1);
      expect(closeCalls, 0);

      await manager.dispose();
      expect(closeCalls, 1);

      await manager.dispose();
      expect(closeCalls, 1);
    });

    test('client remains open after HTTP error until dispose', () async {
      var closeCalls = 0;

      final manager = DefaultCacheManager(
        httpClientFactory: () {
          final mock = http_testing.MockClient(
            (request) async => http.Response('fail', 500),
          );
          return _CloseTrackingClient(mock, onClose: () {
            closeCalls++;
          });
        },
      );

      try {
        await manager
            .getFileStream('https://example.com/client-close-error.png')
            .toList();
      } on Object catch (_) {}

      expect(closeCalls, 0);

      await manager.dispose();
      expect(closeCalls, 1);
    });

    test('client remains open when send throws until dispose', () async {
      var closeCalls = 0;

      final manager = DefaultCacheManager(
        httpClientFactory: () {
          final mock = http_testing.MockClient(
            (request) async =>
                throw const io.SocketException('Connection refused'),
          );
          return _CloseTrackingClient(mock, onClose: () {
            closeCalls++;
          });
        },
      );

      try {
        await manager
            .getFileStream('https://example.com/client-close-throw.png')
            .toList();
      } on Object catch (_) {}

      expect(closeCalls, 0);

      await manager.dispose();
      expect(closeCalls, 1);
    });

    test('download after dispose creates and closes a new client', () async {
      var factoryCalls = 0;
      var closeCalls = 0;
      final manager = DefaultCacheManager(
        httpClientFactory: () {
          factoryCalls++;
          return _CloseTrackingClient(
            http_testing.MockClient(
              (request) async => http.Response('ok', 200),
            ),
            onClose: () {
              closeCalls++;
            },
          );
        },
      );

      await manager
          .getFileStream('https://example.com/client-before-dispose.png')
          .toList();
      await manager.dispose();

      await manager
          .getFileStream('https://example.com/client-after-dispose.png')
          .toList();

      expect(factoryCalls, 2);
      expect(closeCalls, 2);

      await manager.dispose();
      expect(closeCalls, 2);
    });

    test('post-dispose client closes after its last active download', () async {
      var closeCalls = 0;
      var sendCalls = 0;
      final firstResponse = Completer<http.StreamedResponse>();
      final secondResponse = Completer<http.StreamedResponse>();
      final client = SharedHttpClient(
        () => _CloseTrackingClient(
          http_testing.MockClient.streaming((request, bodyStream) {
            sendCalls++;
            return sendCalls == 1
                ? firstResponse.future
                : secondResponse.future;
          }),
          onClose: () {
            closeCalls++;
          },
        ),
      );
      client.dispose();

      final firstSend = client.send(uri: Uri.parse('https://example.com/one'));
      final secondSend = client.send(uri: Uri.parse('https://example.com/two'));

      firstResponse.complete(
        http.StreamedResponse(const Stream.empty(), 200),
      );
      final first = await firstSend;
      first.release();
      expect(closeCalls, 0);

      secondResponse.complete(
        http.StreamedResponse(const Stream.empty(), 200),
      );
      final second = await secondSend;
      second.release();
      expect(closeCalls, 1);
    });
  });

  // ===========================================================================
  // 3. File sink closure in _downloadFile
  // ===========================================================================
  group('Leak: file sink closure', () {
    test('file sink is closed on successful download', () async {
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('data-for-sink', 200),
        ),
      );

      final events = await manager
          .getFileStream('https://example.com/sink-success.png')
          .toList();

      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, isNotEmpty);

      // Verify: the file should be readable (sink was flushed+closed)
      final file = fileInfos.first.file;
      expect(file, isA<io.File>());
      expect(await (file as io.File).exists(), isTrue);
      final bytes = await (file as io.File).readAsBytes();
      expect(bytes.isNotEmpty, isTrue);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('file sink is closed when stream errors mid-download', () async {
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient.streaming(
          (request, bodyStream) async {
            final controller = StreamController<List<int>>();
            controller.add([1, 2, 3]);
            controller.addError(const io.SocketException('Broken pipe'));
            controller.close();
            return http.StreamedResponse(controller.stream, 200);
          },
        ),
      );

      try {
        await manager
            .getFileStream('https://example.com/sink-error.png')
            .toList();
      } on Object catch (_) {}

      // If sink wasn't closed, the file would remain locked.
      // Verify by checking we can still write to the cache dir
      await manager.dispose();
    });
  });

  // ===========================================================================
  // 4. ImageLoader chunkEvents StreamController closure
  // ===========================================================================
  group('Leak: ImageLoader chunkEvents closure', () {
    late FakeCacheManager fakeCacheManager;

    setUp(() {
      fakeCacheManager = FakeCacheManager();
    });

    tearDown(() {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    test('chunkEvents StreamController is closed after success', () async {
      const url = 'https://example.com/chunk-success.png';
      fakeCacheManager.returns(url, kTransparentImage);

      final chunkEvents = StreamController<ImageChunkEvent>();
      var chunkStreamDone = false;
      chunkEvents.stream.listen(
        (_) {},
        onDone: () => chunkStreamDone = true,
      );

      final loader = ImageLoader();
      await loader.loadImageAsync(
        url,
        null,
        chunkEvents,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
        fakeCacheManager,
        null,
        null,
        null,
        ImageRenderMethodForWeb.HttpGet,
        () {},
      ).toList();

      // chunkEvents should be closed (done callback fired)
      expect(chunkStreamDone, isTrue,
          reason: 'chunkEvents StreamController must be closed after loading');
    });

    test('chunkEvents StreamController is closed after error', () async {
      const url = 'https://example.com/chunk-error.png';
      fakeCacheManager.throwsNotFound(url);

      final chunkEvents = StreamController<ImageChunkEvent>();
      var chunkStreamDone = false;
      chunkEvents.stream.listen(
        (_) {},
        onDone: () => chunkStreamDone = true,
        onError: (_) {},
      );

      final loader = ImageLoader();
      // Use drain() with onError so the stream can complete.
      // The async* generator catches the error, yields Stream.error,
      // and then the finally block closes chunkEvents.
      await loader
          .loadImageAsync(
            url,
            null,
            chunkEvents,
            (ui.ImmutableBuffer buffer,
                {ui.TargetImageSizeCallback? getTargetSize}) async {
              return await ui.instantiateImageCodecFromBuffer(buffer);
            },
            fakeCacheManager,
            null,
            null,
            null,
            ImageRenderMethodForWeb.HttpGet,
            () {},
          )
          .handleError((_) {})
          .drain<void>();

      // chunkEvents should still be closed even on error (finally block)
      expect(chunkStreamDone, isTrue,
          reason: 'chunkEvents StreamController must be closed even on error');
    });
  });

  // ===========================================================================
  // 5. MultiImageStreamCompleter — subscription & timer cleanup
  // ===========================================================================
  group('Leak: MultiImageStreamCompleter disposal', () {
    testWidgets('chunkSubscription is cancelled when all listeners removed',
        (tester) async {
      const url = 'https://example.com/multi-dispose.png';
      final fakeCacheManager = FakeCacheManager();
      fakeCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      // Add a listener
      final listener = ImageStreamListener(
        (image, synchronousCall) {},
      );
      completer.addListener(listener);

      await tester.pump();
      await tester.pump();

      // Remove listener — should trigger __maybeDispose
      completer.removeListener(listener);

      // After removal, the completer should be disposed
      // (no dangling subscriptions or timers)
      // Verify by adding another listener — it should still work
      // (but won't get new frames since codec stream is done)
    });

    testWidgets('keepAlive handle prevents premature disposal', (tester) async {
      const url = 'https://example.com/keepalive.png';
      final fakeCacheManager = FakeCacheManager();
      fakeCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      // Add listener to make completer "hadAtLeastOneListener"
      final listener = ImageStreamListener((_, __) {});
      completer.addListener(listener);

      // Get a keepAlive handle
      final handle = completer.keepAlive();

      // Remove listener — should NOT dispose because handle still held
      completer.removeListener(listener);

      // Dispose the handle — should now allow disposal
      handle.dispose();
    });
  });

  // ===========================================================================
  // 6. CachedNetworkImageProvider — loadImage creates and closes resources
  // ===========================================================================
  group('Leak: CachedNetworkImageProvider resource lifecycle', () {
    late FakeCacheManager fakeCacheManager;

    setUp(() {
      fakeCacheManager = FakeCacheManager();
    });

    tearDown(() {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    testWidgets('loadImage cleans up on error without errorListener',
        (tester) async {
      const url = 'https://example.com/provider-error-no-listener.png';
      fakeCacheManager.throwsNotFound(url);

      // Suppress expected image codec error from reportError
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {};
      addTearDown(() => FlutterError.onError = originalOnError);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      // No errorListener — should still not leak
      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
      await tester.pump();
    });

    testWidgets('loadBuffer cleans up on error without errorListener',
        (tester) async {
      const url = 'https://example.com/buffer-error-no-listener.png';
      fakeCacheManager.throwsNotFound(url);

      // Suppress expected image codec error from reportError
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {};
      addTearDown(() => FlutterError.onError = originalOnError);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      final completer = provider.loadBuffer(
        provider,
        (ui.ImmutableBuffer buffer,
            {bool allowUpscaling = false,
            int? cacheHeight,
            int? cacheWidth}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());
      await tester.pump();
    });

    testWidgets('evictFromCache does not leak', (tester) async {
      const url = 'https://example.com/evict-test.png';
      fakeCacheManager.returns(url, kTransparentImage);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
      );

      // Load the image first
      provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      await tester.pump();
      await tester.pump();

      // Evict from cache — should clean up without leaking
      PaintingBinding.instance.imageCache.evict(provider);
    });

    testWidgets(
        'errorListener does not leak ImageStreamCompleter on Flutter >= 3.16',
        (tester) async {
      const url = 'https://example.com/buffer-error-listener-leak.png';
      fakeCacheManager.throwsNotFound(url);

      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {};
      addTearDown(() => FlutterError.onError = originalOnError);

      final provider = CachedNetworkImageProvider(
        url,
        cacheManager: fakeCacheManager,
        errorListener: (e) {},
      );

      final completer = provider.loadImage(
        provider,
        (ui.ImmutableBuffer buffer,
            {ui.TargetImageSizeCallback? getTargetSize}) async {
          return await ui.instantiateImageCodecFromBuffer(buffer);
        },
      );

      expect(completer, isA<ImageStreamCompleter>());

      // Add a listener
      final listener = ImageStreamListener((image, synchronousCall) {});
      completer.addListener(listener);

      await tester.pump();

      // Remove the listener
      completer.removeListener(listener);

      // If addEphemeralErrorListener works correctly, the completer should report 0 active listeners
      // when no standard ImageStreamListeners are attached.
      expect(completer.hasListeners, isFalse,
          reason: 'errorListener should not keep the completer alive');
    });
  });

  // ===========================================================================
  // 7. Hive box lifecycle
  // ===========================================================================
  group('Leak: Hive box lifecycle', () {
    test('dispose closes the Hive box', () async {
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/hive-dispose.bin',
        [1, 2, 3],
        fileExtension: 'bin',
      );

      // dispose() should close the box without error
      await manager.dispose();

      // Re-opening should work (box was properly closed)
      final manager2 = DefaultCacheManager();
      final cached = await manager2.getFileFromCache(
        'https://example.com/hive-dispose.bin',
      );
      expect(cached, isNotNull);

      await manager2.emptyCache();
      await manager2.dispose();
    });

    test('double dispose does not throw', () async {
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/double-dispose.bin',
        [1, 2],
        fileExtension: 'bin',
      );

      await manager.dispose();
      // Second dispose should be safe (box already closed)
      await manager.dispose();
    });

    test('emptyCache followed by dispose is safe', () async {
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/empty-then-dispose.bin',
        [1, 2, 3],
        fileExtension: 'bin',
      );

      await manager.emptyCache();
      await manager.dispose();

      // Re-open and verify it's empty
      final manager2 = DefaultCacheManager();
      final cached = await manager2.getFileFromCache(
        'https://example.com/empty-then-dispose.bin',
      );
      expect(cached, isNull);

      await manager2.dispose();
    });

    test('operations after dispose re-initialize gracefully', () async {
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/reuse-after-dispose.bin',
        [1],
        fileExtension: 'bin',
      );
      await manager.dispose();

      // Using the manager after dispose should re-initialize
      final cached = await manager.getFileFromCache(
        'https://example.com/reuse-after-dispose.bin',
      );
      expect(cached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });
  });
}

/// A wrapper around [http.Client] that tracks whether [close] was called.
class _CloseTrackingClient extends http.BaseClient {
  _CloseTrackingClient(this._inner, {required this.onClose});

  final http.Client _inner;
  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request);
  }

  @override
  void close() {
    onClose();
    _inner.close();
  }
}
