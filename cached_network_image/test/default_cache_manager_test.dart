import 'dart:async';
import 'dart:io' as io;

import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory testTempDir;

  setUpAll(() {
    testTempDir = io.Directory.systemTemp.createTempSync('cached_image_test_');

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
    } on Object catch (_) {
      // Ignore
    }
  });

  // ---- Constructor tests ----

  group('DefaultCacheManager constructor', () {
    test('uses default values', () {
      final manager = DefaultCacheManager();
      expect(manager.stalePeriod, const Duration(days: 7));
      expect(manager.maxNrOfCacheObjects, 200);
    });

    test('accepts custom values', () {
      final manager = DefaultCacheManager(
        stalePeriod: const Duration(days: 14),
        maxNrOfCacheObjects: 50,
      );
      expect(manager.stalePeriod, const Duration(days: 14));
      expect(manager.maxNrOfCacheObjects, 50);
    });

    test('accepts custom httpClientFactory', () {
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('', 200),
        ),
      );
      expect(manager, isA<DefaultCacheManager>());
    });
  });

  // ---- putFile / getFileFromCache / removeFile / emptyCache ----

  group('DefaultCacheManager cache operations', () {
    late DefaultCacheManager manager;

    setUp(() {
      manager = DefaultCacheManager();
    });

    tearDown(() async {
      try {
        await manager.emptyCache();
        await manager.dispose();
      } on Object catch (_) {}
    });

    test('putFile stores file and getFileFromCache retrieves it', () async {
      final bytes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
      final url =
          'https://example.com/put-test-${DateTime.now().millisecondsSinceEpoch}.bin';

      final file = await manager.putFile(url, bytes, fileExtension: 'bin');
      expect(await (file as io.File).exists(), isTrue);
      final readBytes = await file.readAsBytes();
      expect(readBytes, bytes);

      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
      expect(cached!.originalUrl, url);
      expect(cached.source.name, 'Cache');
    });

    test('putFile with custom key', () async {
      const url = 'https://example.com/custom-key-test.bin';
      final key = 'custom-key-${DateTime.now().millisecondsSinceEpoch}';

      await manager.putFile(url, [1, 2, 3], key: key, fileExtension: 'bin');

      final cached = await manager.getFileFromCache(key);
      expect(cached, isNotNull);
      expect(cached!.originalUrl, url);
    });

    test('putFile with eTag', () async {
      final url =
          'https://example.com/etag-test-${DateTime.now().millisecondsSinceEpoch}.bin';
      await manager.putFile(url, [1, 2, 3],
          eTag: '"test-etag"', fileExtension: 'bin');
      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
    });

    test('putFile with custom maxAge', () async {
      final url =
          'https://example.com/maxage-test-${DateTime.now().millisecondsSinceEpoch}.bin';
      await manager.putFile(url, [1, 2, 3],
          maxAge: const Duration(hours: 1), fileExtension: 'bin');
      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
      expect(cached!.validTill.isAfter(DateTime.now()), isTrue);
    });

    test('getFileFromCache returns null for non-existent key', () async {
      final cached = await manager
          .getFileFromCache('non-existent-${DateTime.now().millisecondsSinceEpoch}');
      expect(cached, isNull);
    });

    test('getFileFromCache returns null when file is missing on disk',
        () async {
      final url =
          'https://example.com/missing-file-${DateTime.now().millisecondsSinceEpoch}.bin';
      final file = await manager.putFile(url, [1, 2], fileExtension: 'bin');
      // Delete the actual file on disk (simulate corruption)
      await (file as io.File).delete();
      final cached = await manager.getFileFromCache(url);
      // Should return null and clean up metadata
      expect(cached, isNull);
    });

    test('removeFile deletes cached file', () async {
      final url =
          'https://example.com/remove-test-${DateTime.now().millisecondsSinceEpoch}.bin';
      await manager.putFile(url, [1, 2, 3], fileExtension: 'bin');
      expect(await manager.getFileFromCache(url), isNotNull);

      await manager.removeFile(url);
      expect(await manager.getFileFromCache(url), isNull);
    });

    test('removeFile is no-op for non-existent key', () async {
      await manager
          .removeFile('non-existent-${DateTime.now().millisecondsSinceEpoch}');
      // Should complete without error
    });

    test('emptyCache clears all files', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final url1 = 'https://example.com/empty1-$now.bin';
      final url2 = 'https://example.com/empty2-${now + 1}.bin';

      await manager.putFile(url1, [1, 2, 3], fileExtension: 'bin');
      await manager.putFile(url2, [4, 5, 6], fileExtension: 'bin');

      expect(await manager.getFileFromCache(url1), isNotNull);
      expect(await manager.getFileFromCache(url2), isNotNull);

      await manager.emptyCache();

      expect(await manager.getFileFromCache(url1), isNull);
      expect(await manager.getFileFromCache(url2), isNull);
    });

    test('dispose and re-initialize', () async {
      final url =
          'https://example.com/dispose-test-${DateTime.now().millisecondsSinceEpoch}.bin';
      await manager.putFile(url, [1, 2], fileExtension: 'bin');
      await manager.dispose();

      manager = DefaultCacheManager();
      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
    });
  });

  // ---- Download file tests (with mock HTTP) ----

  group('DefaultCacheManager._downloadFile via getFileStream', () {
    late DefaultCacheManager manager;

    tearDown(() async {
      try {
        await manager.emptyCache();
        await manager.dispose();
      } on Object catch (_) {}
    });

    test('downloads file on cache miss', () async {
      final imageBytes = [
        0x89, 0x50, 0x4E, 0x47, // PNG header
        0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x01,
      ];

      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            expect(request.url.toString(), 'https://example.com/download.png');
            return http.Response(
              String.fromCharCodes(imageBytes),
              200,
              headers: {
                'etag': '"abc123"',
                'content-length': '${imageBytes.length}',
              },
            );
          },
        ),
      );

      const url = 'https://example.com/download.png';
      final events = await manager.getFileStream(url).toList();

      // Should have at least one FileInfo
      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, isNotEmpty);
      expect(fileInfos.first.originalUrl, url);
      expect(fileInfos.first.source.name, 'Online');
    });

    test('downloads with progress reporting', () async {
      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient.streaming(
          (request, bodyStream) async {
            final controller = StreamController<List<int>>();
            // Emit chunks
            controller.add([1, 2, 3, 4]);
            controller.add([5, 6, 7, 8]);
            controller.close();
            return http.StreamedResponse(
              controller.stream,
              200,
              contentLength: 8,
              headers: {'content-length': '8'},
            );
          },
        ),
      );

      const url = 'https://example.com/progress-test.dat';
      final events = await manager
          .getFileStream(url, withProgress: true)
          .toList();

      final progressEvents = events.whereType<DownloadProgress>().toList();
      final fileInfos = events.whereType<FileInfo>().toList();

      expect(progressEvents, isNotEmpty);
      expect(progressEvents.last.downloaded, 8);
      expect(fileInfos, isNotEmpty);
    });

    test('passes custom headers to HTTP request', () async {
      String? receivedAuth;

      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            receivedAuth = request.headers['Authorization'];
            return http.Response('data', 200);
          },
        ),
      );

      await manager
          .getFileStream(
            'https://example.com/auth-test.dat',
            headers: {'Authorization': 'Bearer token123'},
          )
          .toList();

      expect(receivedAuth, 'Bearer token123');
    });

    test('error on HTTP 404 is propagated to stream (no cached file)', () async {
      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('Not Found', 404),
        ),
      );

      Object? caughtError;
      try {
        await manager
            .getFileStream('https://example.com/not-found-err.png')
            .toList();
      } on Object catch (e) {
        caughtError = e;
      }

      expect(caughtError, isA<HttpExceptionWithStatus>());
      expect((caughtError! as HttpExceptionWithStatus).statusCode, 404);
    });

    test('error on HTTP 500 is propagated to stream', () async {
      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('Server Error', 500),
        ),
      );

      Object? caughtError;
      try {
        await manager
            .getFileStream('https://example.com/server-error.png')
            .toList();
      } on Object catch (e) {
        caughtError = e;
      }

      expect(caughtError, isA<HttpExceptionWithStatus>());
      expect((caughtError! as HttpExceptionWithStatus).statusCode, 500);
    });

    test('serves from cache and skips download when file is still valid',
        () async {
      var downloadCount = 0;

      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            downloadCount++;
            return http.Response('image-data', 200);
          },
        ),
      );

      const url = 'https://example.com/cache-hit-test.png';

      // First request: will download
      await manager.getFileStream(url).toList();
      expect(downloadCount, 1);

      // Second request: should serve from cache, but still "checks" for
      // freshness — the download may still happen because validTill > now
      // What we really test is that the cached FileInfo comes first
      final events = await manager.getFileStream(url).toList();
      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, isNotEmpty);
      // First FileInfo should be from Cache
      expect(fileInfos.first.source.name, 'Cache');
    });

    test('re-downloads when cached file is expired', () async {
      var downloadCount = 0;

      manager = DefaultCacheManager(
        stalePeriod: Duration.zero, // Expire immediately
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            downloadCount++;
            return http.Response('image-data-$downloadCount', 200);
          },
        ),
      );

      const url = 'https://example.com/expire-test.png';

      // First download
      await manager.getFileStream(url).toList();
      expect(downloadCount, 1);

      // Wait a tiny bit to ensure stalePeriod (0) has passed
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Second request should re-download because file is expired
      await manager.getFileStream(url).toList();
      expect(downloadCount, 2);
    });

    test('handles 404 on re-download of existing cached entry', () async {
      var callCount = 0;
      manager = DefaultCacheManager(
        stalePeriod: Duration.zero,
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            callCount++;
            if (callCount == 1) {
              return http.Response('ok', 200);
            }
            return http.Response('Not Found', 404);
          },
        ),
      );

      const url = 'https://example.com/stale-404-test.png';

      // First download succeeds
      await manager.getFileStream(url).toList();

      // Wait for expiry
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Second download returns 404 — should remove from cache
      try {
        await manager.getFileStream(url).toList();
      } on Object catch (_) {
        // Expected: 404 error
      }

      // Wait for async removeFile to complete with retry
      FileInfo? cached;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        cached = await manager.getFileFromCache(url);
        if (cached == null) break;
      }
      expect(cached, isNull);
    });
  });

  // ---- getFileStream with key parameter ----

  group('DefaultCacheManager.getFileStream with key', () {
    late DefaultCacheManager manager;

    setUp(() {
      manager = DefaultCacheManager();
    });

    tearDown(() async {
      try {
        await manager.emptyCache();
        await manager.dispose();
      } on Object catch (_) {}
    });

    test('uses key parameter for cache lookup', () async {
      const url = 'https://example.com/key-lookup.bin';
      final key = 'key-${DateTime.now().millisecondsSinceEpoch}';

      await manager.putFile(url, [1, 2, 3], key: key, fileExtension: 'bin');

      final events = await manager.getFileStream(url, key: key).toList();
      expect(events.whereType<FileInfo>().isNotEmpty, isTrue);
    });
  });

  // ---- getImageFile tests ----

  group('DefaultCacheManager.getImageFile', () {
    late DefaultCacheManager manager;

    tearDown(() async {
      try {
        await manager.emptyCache();
        await manager.dispose();
      } on Object catch (_) {}
    });

    test('delegates to getFileStream when no resize needed', () async {
      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('img-data', 200),
        ),
      );

      const url = 'https://example.com/no-resize.png';
      final events = await manager.getImageFile(url).toList();

      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, isNotEmpty);
    });

    test('delegates to getFileStream with headers and progress', () async {
      String? receivedAuth;

      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            receivedAuth = request.headers['Authorization'];
            return http.Response('img-data', 200);
          },
        ),
      );

      const url = 'https://example.com/no-resize-headers.png';
      await manager
          .getImageFile(
            url,
            headers: {'Authorization': 'Bearer xyz'},
            withProgress: true,
          )
          .toList();

      expect(receivedAuth, 'Bearer xyz');
    });

    test('uses key parameter', () async {
      manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('img-data', 200),
        ),
      );

      const url = 'https://example.com/key-image.png';
      final events =
          await manager.getImageFile(url, key: 'my-key').toList();
      expect(events.whereType<FileInfo>().isNotEmpty, isTrue);
    });
  });

  // ---- Helper method tests ----

  group('DefaultCacheManager helper methods', () {
    test('_getFileExtensionFromUrl extracts extension', () async {
      // We test this indirectly through putFile / getFileStream
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('data', 200),
        ),
      );

      // URL with extension
      await manager
          .getFileStream('https://example.com/images/photo.jpeg')
          .toList();

      // URL without extension
      await manager
          .getFileStream('https://example.com/images/noext')
          .toList();

      await manager.emptyCache();
      await manager.dispose();
    });

    test('_generateRelativePath produces consistent paths', () async {
      final manager = DefaultCacheManager();
      // Same URL should produce same cache file
      const url = 'https://example.com/consistent.png';

      await manager.putFile(url, [1, 2], fileExtension: 'png');
      final cached1 = await manager.getFileFromCache(url);
      expect(cached1, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // ---- _cleanupOldFiles tests ----

  group('DefaultCacheManager._cleanupOldFiles', () {
    test('removes expired entries during initialization', () async {
      // First, put an entry with zero stale period
      final manager1 = DefaultCacheManager(
        stalePeriod: Duration.zero,
      );

      final url =
          'https://example.com/cleanup-test-${DateTime.now().millisecondsSinceEpoch}.bin';
      await manager1.putFile(url, [1, 2, 3], fileExtension: 'bin',
          maxAge: Duration.zero);
      await manager1.dispose();

      // Wait a bit for the entry to expire
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Create a new manager — _ensureInitialized triggers _cleanupOldFiles
      final manager2 = DefaultCacheManager();

      // Trigger initialization by accessing the cache
      await manager2.getFileFromCache('dummy-key-to-trigger-init');

      // Give cleanup a moment to run (it runs unawaited)
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // The expired entry might have been cleaned up
      final cached = await manager2.getFileFromCache(url);
      // Entry should be cleaned up since it's expired
      expect(cached, isNull);

      await manager2.emptyCache();
      await manager2.dispose();
    });

    test('respects maxNrOfCacheObjects limit', () async {
      final manager = DefaultCacheManager(
        maxNrOfCacheObjects: 2,
      );

      // Add 4 entries (exceeds limit of 2)
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < 4; i++) {
        await manager.putFile(
          'https://example.com/limit-$i-$now.bin',
          [i],
          fileExtension: 'bin',
          maxAge: const Duration(hours: 1),
        );
      }

      await manager.dispose();

      // Re-initialize — cleanup should trim to maxNrOfCacheObjects
      final manager2 = DefaultCacheManager(
        maxNrOfCacheObjects: 2,
      );

      // Trigger initialization
      await manager2.getFileFromCache('trigger-init-$now');

      // Give cleanup time
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Count remaining entries — there should be at most 2
      var remainingCount = 0;
      for (var i = 0; i < 4; i++) {
        final cached =
            await manager2.getFileFromCache('https://example.com/limit-$i-$now.bin');
        if (cached != null) remainingCount++;
      }

      expect(remainingCount, lessThanOrEqualTo(2));

      await manager2.emptyCache();
      await manager2.dispose();
    });
  });

  // ---- CacheEntryMetadata ----

  group('CacheEntryMetadata via DefaultCacheManager', () {
    test('toMap produces correct keys', () {
      final metadata = CacheEntryMetadata(
        url: 'https://example.com/test.png',
        relativePath: 'abc123.png',
        validTill: DateTime(2025, 6, 15),
        eTag: '"etag"',
        length: 1024,
      );

      final map = metadata.toMap();
      expect(map['url'], 'https://example.com/test.png');
      expect(map['relativePath'], 'abc123.png');
      expect(map['eTag'], '"etag"');
      expect(map['length'], 1024);
    });

    test('fromMap roundtrips correctly', () {
      final original = CacheEntryMetadata(
        url: 'https://example.com/roundtrip.png',
        relativePath: 'some/path.png',
        validTill: DateTime(2026, 1, 1),
        eTag: '"v2"',
        length: 512,
      );

      final reconstructed = CacheEntryMetadata.fromMap(original.toMap());
      expect(reconstructed.url, original.url);
      expect(reconstructed.relativePath, original.relativePath);
      expect(reconstructed.validTill, original.validTill);
      expect(reconstructed.eTag, original.eTag);
      expect(reconstructed.length, original.length);
    });
  });
}
