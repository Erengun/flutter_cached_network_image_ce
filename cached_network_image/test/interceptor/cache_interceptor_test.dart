import 'dart:async';
import 'dart:io' as io;

import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:cached_network_image_ce/src/cache/interceptors/cache_interceptor.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:file/local.dart';
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
const _hitUrl1 = 'https://example.com/cache_hit_1.png';
const _hitUrl2 = 'https://example.com/cache_hit_2.png';
const _hitRejectMissUrl = 'https://example.com/cache_hit_reject_miss.png';
const _missUrl1 = 'https://example.com/cache_miss_1.png';
const _storeUrl1 = 'https://example.com/cache_store_1.png';
const _storeUrl2 = 'https://example.com/cache_store_2.png';
const _storeUrl3 = 'https://example.com/cache_store_3.png';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory testTempDir;

  setUpAll(() {
    testTempDir =
        io.Directory.systemTemp.createTempSync('cache_interceptor_test_');
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

  group('onHit interceptor', () {
    test('resolve() with modified FileInfo — modified FileInfo returned',
        () async {
      final mockClient = http_testing.MockClient((request) async {
        return http.Response.bytes(_pngBytes, 200);
      });

      final modifiedFile =
          const LocalFileSystem().file('/synthetic/modified.png');
      final modifiedValidTill = DateTime.now().add(const Duration(days: 999));
      final modifiedFileInfo = FileInfo(
        modifiedFile,
        FileSource.Cache,
        modifiedValidTill,
        _hitUrl1,
      );

      final interceptor = _ResolvingHitInterceptor(modifiedFileInfo);
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      // First fetch: cache miss — onHit not called, file is downloaded and stored.
      await firstFileInfo(manager.getFileStream(_hitUrl1));

      // Second fetch: cache hit — onHit fires and resolves with modified FileInfo.
      final result = await firstFileInfo(manager.getFileStream(_hitUrl1));

      expect(result.validTill, modifiedValidTill);
      expect(result.originalUrl, _hitUrl1);
    });

    test('reject() — re-download is triggered (HTTP called twice)', () async {
      var callCount = 0;
      final mockClient = http_testing.MockClient((request) async {
        callCount++;
        return http.Response.bytes(_pngBytes, 200);
      });

      final interceptor = _RejectingHitInterceptor();
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      // First fetch: miss → download (callCount = 1).
      await firstFileInfo(manager.getFileStream(_hitUrl2));
      expect(callCount, 1);

      // Second fetch: hit → interceptor rejects → treated as miss → re-download.
      await firstFileInfo(manager.getFileStream(_hitUrl2));
      expect(callCount, 2);
    });
  });

  group('onMiss interceptor', () {
    test('resolve() with synthetic FileInfo — no HTTP call made', () async {
      var callCount = 0;
      final mockClient = http_testing.MockClient((request) async {
        callCount++;
        return http.Response.bytes(_pngBytes, 200);
      });

      // Create a real file so callers don't blow up if they read it.
      final syntheticFilePath = '${testTempDir.path}/synthetic_miss_file.png';
      await io.File(syntheticFilePath).writeAsBytes(_pngBytes);
      final syntheticFile = const LocalFileSystem().file(syntheticFilePath);
      final syntheticValidTill = DateTime.now().add(const Duration(days: 1));
      final syntheticFileInfo = FileInfo(
        syntheticFile,
        FileSource.Cache,
        syntheticValidTill,
        _missUrl1,
      );

      final interceptor = _ResolvingMissInterceptor(syntheticFileInfo);
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      final result = await firstFileInfo(manager.getFileStream(_missUrl1));

      expect(callCount, 0);
      expect(result.validTill, syntheticValidTill);
      expect(result.originalUrl, _missUrl1);
    });
  });

  group('onStore interceptor', () {
    test('reject() — Hive metadata not written, subsequent lookup is a miss',
        () async {
      var callCount = 0;
      final mockClient = http_testing.MockClient((request) async {
        callCount++;
        return http.Response.bytes(_pngBytes, 200);
      });

      final interceptor = _RejectingStoreInterceptor();
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      // First fetch: downloaded successfully, but metadata not written to Hive.
      await firstFileInfo(manager.getFileStream(_storeUrl1));
      expect(callCount, 1);

      // Second fetch: getFileFromCache returns null (no metadata) → miss → re-download.
      await firstFileInfo(manager.getFileStream(_storeUrl1));
      expect(callCount, 2);
    });

    test(
        'next() (default) — metadata is written, second fetch is a hit (1 HTTP call)',
        () async {
      var callCount = 0;
      final mockClient = http_testing.MockClient((request) async {
        callCount++;
        return http.Response.bytes(_pngBytes, 200);
      });

      // No cache interceptors — default onStore behaviour allows storage.
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
      );
      addTearDown(manager.dispose);

      await firstFileInfo(manager.getFileStream(_storeUrl2));
      expect(callCount, 1);

      // Second fetch hits the cache — no additional HTTP call.
      await firstFileInfo(manager.getFileStream(_storeUrl2));
      expect(callCount, 1);
    });

    test('reject() removes disk file — no orphaned image file on disk',
        () async {
      final mockClient = http_testing.MockClient((request) async {
        return http.Response.bytes(_pngBytes, 200);
      });

      final interceptor = _RejectingStoreInterceptor();
      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheDirectoryProvider: () async => testTempDir,
        cacheInterceptors: [interceptor],
      );
      addTearDown(manager.dispose);

      await firstFileInfo(manager.getFileStream(_storeUrl3));

      // Derive the expected file path using the same formula as DefaultCacheManager.
      final keyHash = _storeUrl3.hashCode.toUnsigned(32).toRadixString(16);
      final expectedFile = io.File(
        '${testTempDir.path}/cached_network_image_ce/$keyHash.png',
      );
      expect(await expectedFile.exists(), isFalse,
          reason: 'onStore reject() must delete the written file');
    });
  });

  group('onHit reject + onMiss resolve interaction', () {
    test(
        'onHit reject() triggers onMiss chain — miss interceptor wins over re-download',
        () async {
      var callCount = 0;
      final mockClient = http_testing.MockClient((request) async {
        callCount++;
        return http.Response.bytes(_pngBytes, 200);
      });

      // Populate cache for _hitRejectMissUrl.
      final setupManager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheDirectoryProvider: () async => testTempDir,
      );
      await firstFileInfo(setupManager.getFileStream(_hitRejectMissUrl));
      await setupManager.dispose();
      callCount = 0; // reset after initial download

      // Create a synthetic file the miss interceptor will return.
      final syntheticFilePath =
          '${testTempDir.path}/synthetic_hit_reject_miss.png';
      await io.File(syntheticFilePath).writeAsBytes(_pngBytes);
      final syntheticFile = const LocalFileSystem().file(syntheticFilePath);
      final syntheticValidTill = DateTime.now().add(const Duration(days: 7));
      final syntheticFileInfo = FileInfo(
        syntheticFile,
        FileSource.Cache,
        syntheticValidTill,
        _hitRejectMissUrl,
      );

      var onHitWasCalled = false;
      final rejectingHit = _TrackingRejectingHitInterceptor(
        onCalled: () => onHitWasCalled = true,
      );
      final resolvingMiss = _ResolvingMissInterceptor(syntheticFileInfo);

      final manager = DefaultCacheManager(
        httpClientFactory: () => mockClient,
        cacheDirectoryProvider: () async => testTempDir,
        cacheInterceptors: [rejectingHit, resolvingMiss],
      );
      addTearDown(manager.dispose);

      final result =
          await firstFileInfo(manager.getFileStream(_hitRejectMissUrl));

      // onHit fired (proves the hit path was reached, not just a plain miss).
      expect(onHitWasCalled, isTrue,
          reason: 'onHit must have fired for a cached URL');
      // Miss interceptor resolved → no HTTP call.
      expect(callCount, equals(0),
          reason: 'miss interceptor resolved, so no re-download expected');
      // Got the synthetic FileInfo.
      expect(result.file.path, equals(syntheticFile.path));
    });
  });
}

// ── Test interceptor implementations ────────────────────────────────────────

class _ResolvingHitInterceptor extends CacheInterceptor {
  const _ResolvingHitInterceptor(this.replacement);

  final FileInfo replacement;

  @override
  void onHit(CacheHitData data, CacheHitHandler handler) {
    handler.resolve(replacement);
  }
}

class _RejectingHitInterceptor extends CacheInterceptor {
  @override
  void onHit(CacheHitData data, CacheHitHandler handler) {
    handler.reject();
  }
}

class _ResolvingMissInterceptor extends CacheInterceptor {
  const _ResolvingMissInterceptor(this.synthetic);

  final FileInfo synthetic;

  @override
  void onMiss(CacheMissData data, CacheMissHandler handler) {
    handler.resolve(synthetic);
  }
}

class _RejectingStoreInterceptor extends CacheInterceptor {
  @override
  void onStore(CacheStoreData data, CacheStoreHandler handler) {
    handler.reject();
  }
}

class _TrackingRejectingHitInterceptor extends CacheInterceptor {
  _TrackingRejectingHitInterceptor({required this.onCalled});

  final void Function() onCalled;

  @override
  void onHit(CacheHitData data, CacheHitHandler handler) {
    onCalled();
    handler.reject();
  }
}
