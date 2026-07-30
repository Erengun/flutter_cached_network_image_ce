import 'dart:async';
import 'dart:io' as io;

import 'package:cached_network_image_ce/src/cache/default_cache_manager_web.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/hive_impl.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'support/http_clients.dart';

/// A custom object that forces Hive to write a user-defined typeId into
/// the box file. When the box is later opened without this adapter
/// registered, Hive throws [HiveError] with "unknown typeId".
class _CorruptPayload {
  _CorruptPayload(this.data);
  final String data;
}

/// Adapter with typeId 121 — the exact id reported in issue #12.
class _CorruptPayloadAdapter extends TypeAdapter<_CorruptPayload> {
  @override
  final int typeId = 121;

  @override
  _CorruptPayload read(BinaryReader reader) =>
      _CorruptPayload(reader.readString());

  @override
  void write(BinaryWriter writer, _CorruptPayload obj) =>
      writer.writeString(obj.data);
}

void main() {
  late io.Directory hiveTempDir;
  late HiveInterface testHive;

  setUp(() {
    hiveTempDir =
        io.Directory.systemTemp.createTempSync('web_cache_manager_test_');
    testHive = HiveImpl();
    testHive.init(hiveTempDir.path);
  });

  tearDown(() async {
    await testHive.close();
    try {
      hiveTempDir.deleteSync(recursive: true);
    } on Object catch (_) {}
  });

  // =====================================================================
  // Constructor
  // =====================================================================

  group('WebCacheManager constructor', () {
    test('uses default values', () {
      final manager = DefaultCacheManager(hiveInstance: testHive);
      expect(manager.stalePeriod, const Duration(days: 7));
      expect(manager.maxNrOfCacheObjects, 200);
    });

    test('accepts custom values', () {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        stalePeriod: const Duration(days: 14),
        maxNrOfCacheObjects: 50,
      );
      expect(manager.stalePeriod, const Duration(days: 14));
      expect(manager.maxNrOfCacheObjects, 50);
    });

    test('accepts custom httpClientFactory', () {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('', 200),
        ),
      );
      expect(manager, isA<DefaultCacheManager>());
    });
  });

  // =====================================================================
  // putFile / getFileFromCache / removeFile / emptyCache
  // =====================================================================

  group('WebCacheManager cache operations', () {
    late DefaultCacheManager manager;

    setUp(() {
      manager = DefaultCacheManager(hiveInstance: testHive);
    });

    tearDown(() async {
      try {
        await manager.emptyCache();
        await manager.dispose();
      } on Object catch (_) {}
    });

    test('putFile stores data and getFileFromCache retrieves it', () async {
      final bytes = [1, 2, 3, 4, 5];
      const url = 'https://example.com/put-test.png';

      final file = await manager.putFile(url, bytes, fileExtension: 'png');
      final readBytes = await file.readAsBytes();
      expect(readBytes, bytes);

      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
      expect(cached!.originalUrl, url);
      expect(cached.source, FileSource.Cache);

      final cachedBytes = await cached.file.readAsBytes();
      expect(cachedBytes, bytes);
    });

    test('putFile with custom key', () async {
      const url = 'https://example.com/custom-key.png';
      const key = 'my-custom-key';

      await manager.putFile(url, [1, 2, 3], key: key, fileExtension: 'png');

      // Retrieving by key should work
      final cached = await manager.getFileFromCache(key);
      expect(cached, isNotNull);
      expect(cached!.originalUrl, url);

      // Retrieving by URL should NOT work (key is different)
      final byUrl = await manager.getFileFromCache(url);
      expect(byUrl, isNull);
    });

    test('putFile with eTag stores metadata', () async {
      const url = 'https://example.com/etag-test.png';
      await manager.putFile(
        url,
        [1, 2, 3],
        eTag: '"test-etag-123"',
        fileExtension: 'png',
      );
      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
    });

    test('putFile with custom maxAge', () async {
      const url = 'https://example.com/maxage.png';
      await manager.putFile(
        url,
        [1, 2, 3],
        maxAge: const Duration(hours: 1),
        fileExtension: 'png',
      );

      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
      expect(cached!.validTill.isAfter(DateTime.now()), isTrue);
      // Should expire within ~1 hour, not 30 days
      expect(
        cached.validTill.isBefore(
          DateTime.now().add(const Duration(hours: 2)),
        ),
        isTrue,
      );
    });

    test('putFile overwrites existing entry', () async {
      const url = 'https://example.com/overwrite.png';

      await manager.putFile(url, [1, 2, 3], fileExtension: 'png');
      await manager.putFile(url, [4, 5, 6, 7], fileExtension: 'png');

      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);
      final bytes = await cached!.file.readAsBytes();
      expect(bytes, [4, 5, 6, 7]);
    });

    test('getFileFromCache returns null for non-existent key', () async {
      final cached = await manager.getFileFromCache('non-existent-key');
      expect(cached, isNull);
    });

    test('removeFile deletes the entry', () async {
      const url = 'https://example.com/remove-test.png';
      await manager.putFile(url, [1, 2, 3], fileExtension: 'png');

      final cached = await manager.getFileFromCache(url);
      expect(cached, isNotNull);

      await manager.removeFile(url);

      final afterRemove = await manager.getFileFromCache(url);
      expect(afterRemove, isNull);
    });

    test('emptyCache clears all entries', () async {
      await manager.putFile(
        'https://example.com/empty-1.png',
        [1],
        fileExtension: 'png',
      );
      await manager.putFile(
        'https://example.com/empty-2.png',
        [2],
        fileExtension: 'png',
      );

      await manager.emptyCache();

      expect(
        await manager.getFileFromCache('https://example.com/empty-1.png'),
        isNull,
      );
      expect(
        await manager.getFileFromCache('https://example.com/empty-2.png'),
        isNull,
      );
    });
  });

  // =====================================================================
  // getFileStream — download, cache hit, progress, errors
  // =====================================================================

  group('WebCacheManager getFileStream', () {
    test('downloads and caches a file on first request', () async {
      final responseData = List.generate(100, (i) => i % 256);
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response.bytes(responseData, 200),
        ),
      );

      final events = await manager
          .getFileStream('https://example.com/download.png')
          .toList();

      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, hasLength(1));
      expect(fileInfos.first.source, FileSource.Online);

      final bytes = await fileInfos.first.file.readAsBytes();
      expect(bytes, responseData);

      // Second request should return from cache
      final events2 = await manager
          .getFileStream('https://example.com/download.png')
          .toList();
      final fileInfos2 = events2.whereType<FileInfo>().toList();
      expect(fileInfos2.isNotEmpty, isTrue);
      // First event should be from cache
      expect(fileInfos2.first.source, FileSource.Cache);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('reports download progress when withProgress is true', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient.streaming(
          (request, bodyStream) async {
            final controller = StreamController<List<int>>();
            controller.add([1, 2, 3]);
            controller.add([4, 5, 6]);
            controller.add([7, 8, 9]);
            controller.close();
            return http.StreamedResponse(
              controller.stream,
              200,
              contentLength: 9,
            );
          },
        ),
      );

      final events = await manager
          .getFileStream(
            'https://example.com/progress.png',
            withProgress: true,
          )
          .toList();

      final progressEvents = events.whereType<DownloadProgress>().toList();
      expect(progressEvents, isNotEmpty);
      // Last progress should have received 9 bytes
      expect(progressEvents.last.downloaded, 9);
      expect(progressEvents.last.totalSize, 9);

      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, hasLength(1));

      await manager.emptyCache();
      await manager.dispose();
    });

    test('does not report progress when withProgress is false', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('abc', 200),
        ),
      );

      final events = await manager
          .getFileStream('https://example.com/no-progress.png')
          .toList();

      final progressEvents = events.whereType<DownloadProgress>().toList();
      expect(progressEvents, isEmpty);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('throws HttpExceptionWithStatus on non-200 response', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('not found', 404),
        ),
      );

      Object? error;
      try {
        await manager
            .getFileStream('https://example.com/not-found.png')
            .toList();
      } on Object catch (e) {
        error = e;
      }

      expect(error, isA<HttpExceptionWithStatus>());
      expect((error! as HttpExceptionWithStatus).statusCode, 404);

      await manager.dispose();
    });

    test('throws on 500 status', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('error', 500),
        ),
      );

      Object? error;
      try {
        await manager
            .getFileStream('https://example.com/server-error.png')
            .toList();
      } on Object catch (e) {
        error = e;
      }

      expect(error, isA<HttpExceptionWithStatus>());
      expect((error! as HttpExceptionWithStatus).statusCode, 500);

      await manager.dispose();
    });

    test('forwards custom headers to HTTP request', () async {
      Map<String, String>? receivedHeaders;
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            receivedHeaders = request.headers;
            return http.Response('ok', 200);
          },
        ),
      );

      await manager.getFileStream(
        'https://example.com/headers.png',
        headers: {'Authorization': 'Bearer token123'},
      ).toList();

      expect(receivedHeaders, isNotNull);
      expect(receivedHeaders!['Authorization'], 'Bearer token123');

      await manager.emptyCache();
      await manager.dispose();
    });

    test('uses custom key when provided', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('data', 200),
        ),
      );

      await manager
          .getFileStream(
            'https://example.com/keyed.png',
            key: 'my-stream-key',
          )
          .toList();

      // Should be cached under the custom key
      final cached = await manager.getFileFromCache('my-stream-key');
      expect(cached, isNotNull);

      // The original URL key should NOT have data
      final byUrl =
          await manager.getFileFromCache('https://example.com/keyed.png');
      expect(byUrl, isNull);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('serves stale cache then redownloads', () async {
      var downloadCount = 0;
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        stalePeriod: Duration.zero, // Everything expires immediately
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            downloadCount++;
            return http.Response('data-$downloadCount', 200);
          },
        ),
      );

      // First request — download
      await manager.getFileStream('https://example.com/stale.png').toList();
      expect(downloadCount, 1);

      // Wait a tiny bit to ensure stalePeriod (zero) has passed
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Second request — should serve stale cache AND redownload
      final events2 =
          await manager.getFileStream('https://example.com/stale.png').toList();
      expect(downloadCount, 2);

      // Should have two FileInfo events: one from cache, one from download
      final fileInfos = events2.whereType<FileInfo>().toList();
      expect(fileInfos.length, equals(2));

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // =====================================================================
  // getImageFile — resize key behavior on web
  // =====================================================================

  group('WebCacheManager getImageFile', () {
    test('delegates to getFileStream when no resize params', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('image-bytes', 200),
        ),
      );

      final events =
          await manager.getImageFile('https://example.com/image.png').toList();

      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, hasLength(1));

      await manager.emptyCache();
      await manager.dispose();
    });

    test('stores original under resized key when maxWidth is set', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('original-image', 200),
        ),
      );

      final events = await manager
          .getImageFile(
            'https://example.com/resize.png',
            maxWidth: 300,
          )
          .toList();

      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, hasLength(1));

      // The resized key should exist in cache
      final resizedCached = await manager.getFileFromCache(
        'resized_w300_https://example.com/resize.png',
      );
      expect(resizedCached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('stores original under resized key when maxHeight is set', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('original-image', 200),
        ),
      );

      await manager
          .getImageFile(
            'https://example.com/resize-h.png',
            maxHeight: 200,
          )
          .toList();

      final resizedCached = await manager.getFileFromCache(
        'resized_h200_https://example.com/resize-h.png',
      );
      expect(resizedCached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('builds correct resized key with both width and height', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('img', 200),
        ),
      );

      await manager
          .getImageFile(
            'https://example.com/both.png',
            maxWidth: 400,
            maxHeight: 300,
          )
          .toList();

      final cached = await manager.getFileFromCache(
        'resized_w400_h300_https://example.com/both.png',
      );
      expect(cached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('returns cached resized entry on second call', () async {
      var downloadCount = 0;
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            downloadCount++;
            return http.Response('img-data', 200);
          },
        ),
      );

      await manager
          .getImageFile(
            'https://example.com/cached-resize.png',
            maxWidth: 100,
          )
          .toList();
      expect(downloadCount, 1);

      // Second call should use cache
      final events = await manager
          .getImageFile(
            'https://example.com/cached-resize.png',
            maxWidth: 100,
          )
          .toList();

      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos.first.source, FileSource.Cache);
      // Should NOT download again
      expect(downloadCount, 1);

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // =====================================================================
  // Concurrent initialization
  // =====================================================================

  group('WebCacheManager concurrent initialization', () {
    test('parallel putFile calls on cold manager all succeed', () async {
      final manager = DefaultCacheManager(hiveInstance: testHive);

      final futures = List.generate(
        10,
        (i) => manager.putFile(
          'https://example.com/web-concurrent-$i.png',
          List.filled(i + 1, i),
          fileExtension: 'png',
        ),
      );

      await Future.wait(futures);

      for (var i = 0; i < 10; i++) {
        final cached = await manager.getFileFromCache(
          'https://example.com/web-concurrent-$i.png',
        );
        expect(cached, isNotNull, reason: 'Entry $i should be cached');
        final bytes = await cached!.file.readAsBytes();
        expect(bytes.length, i + 1, reason: 'Entry $i has wrong length');
      }

      await manager.emptyCache();
      await manager.dispose();
    });

    test('mixed concurrent operations on cold manager', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('img', 200),
        ),
      );

      final futures = <Future>[
        manager.putFile(
          'https://example.com/web-mix-put.png',
          [1],
          fileExtension: 'png',
        ),
        manager.getFileFromCache('https://example.com/non-existent'),
        manager
            .getFileStream('https://example.com/web-mix-stream.png')
            .toList(),
        manager.removeFile('https://example.com/also-non-existent'),
      ];

      await Future.wait(futures);

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // =====================================================================
  // Hive box corruption recovery (#12)
  // =====================================================================

  group('WebCacheManager corruption recovery', () {
    test('recovers from corrupted Hive meta box on init', () async {
      // First, create valid entries.
      final manager1 = DefaultCacheManager(hiveInstance: testHive);
      await manager1.putFile(
        'https://example.com/corrupt-web.png',
        [1, 2, 3],
        fileExtension: 'png',
      );
      final cached1 = await manager1.getFileFromCache(
        'https://example.com/corrupt-web.png',
      );
      expect(cached1, isNotNull);
      await manager1.dispose();

      // Poison the meta box by writing an entry with a custom TypeAdapter
      // (typeId 121). When the box is reopened without the adapter,
      // Hive throws HiveError with "unknown typeId".
      final poisonHive = HiveImpl();
      poisonHive.init(hiveTempDir.path);
      poisonHive.registerAdapter(_CorruptPayloadAdapter());
      final poisonBox = await poisonHive.openBox('cached_network_image_cache');
      await poisonBox.put('__corrupt__', _CorruptPayload('bad'));
      await poisonBox.close();
      await poisonHive.close();

      // Re-create manager with a fresh Hive instance (simulating app restart).
      final freshHive = HiveImpl();
      freshHive.init(hiveTempDir.path);
      addTearDown(() => freshHive.close());

      final manager2 = DefaultCacheManager(hiveInstance: freshHive);

      // Old entry is gone (box was wiped), but no crash.
      final cached2 = await manager2.getFileFromCache(
        'https://example.com/corrupt-web.png',
      );
      expect(cached2, isNull);

      // New entries should work fine.
      await manager2.putFile(
        'https://example.com/after-web-recovery.png',
        [4, 5, 6],
        fileExtension: 'png',
      );
      final cached3 = await manager2.getFileFromCache(
        'https://example.com/after-web-recovery.png',
      );
      expect(cached3, isNotNull);
      expect(
        cached3!.originalUrl,
        'https://example.com/after-web-recovery.png',
      );

      await manager2.emptyCache();
      await manager2.dispose();
    });

    test('concurrent callers all succeed after corruption recovery', () async {
      // Create valid data, then poison the box.
      final manager1 = DefaultCacheManager(hiveInstance: testHive);
      await manager1.putFile(
        'https://example.com/pre-corrupt.png',
        [1],
        fileExtension: 'png',
      );
      await manager1.dispose();

      // Poison the meta box with an unregistered typeId entry.
      final poisonHive = HiveImpl();
      poisonHive.init(hiveTempDir.path);
      poisonHive.registerAdapter(_CorruptPayloadAdapter());
      final poisonBox = await poisonHive.openBox('cached_network_image_cache');
      await poisonBox.put('__corrupt__', _CorruptPayload('bad'));
      await poisonBox.close();
      await poisonHive.close();

      final freshHive = HiveImpl();
      freshHive.init(hiveTempDir.path);
      addTearDown(() => freshHive.close());

      final manager2 = DefaultCacheManager(hiveInstance: freshHive);

      // Fire concurrent operations — all should complete without throwing.
      final futures = List.generate(
        10,
        (i) => manager2.putFile(
          'https://example.com/web-concurrent-recovery-$i.png',
          List.filled(i + 1, i),
          fileExtension: 'png',
        ),
      );
      await Future.wait(futures);

      for (var i = 0; i < 10; i++) {
        final cached = await manager2.getFileFromCache(
          'https://example.com/web-concurrent-recovery-$i.png',
        );
        expect(cached, isNotNull, reason: 'Entry $i should exist');
      }

      await manager2.emptyCache();
      await manager2.dispose();
    });
  });

  // =====================================================================
  // Dispose / lifecycle
  // =====================================================================

  group('WebCacheManager dispose lifecycle', () {
    test('dispose closes boxes', () async {
      final manager = DefaultCacheManager(hiveInstance: testHive);
      await manager.putFile(
        'https://example.com/web-dispose.png',
        [1, 2, 3],
        fileExtension: 'png',
      );
      await manager.dispose();

      // Re-opening should work
      final manager2 = DefaultCacheManager(hiveInstance: testHive);
      final cached = await manager2.getFileFromCache(
        'https://example.com/web-dispose.png',
      );
      expect(cached, isNotNull);

      await manager2.emptyCache();
      await manager2.dispose();
    });

    test('double dispose does not throw', () async {
      final manager = DefaultCacheManager(hiveInstance: testHive);
      await manager.putFile(
        'https://example.com/web-double-dispose.png',
        [1, 2],
        fileExtension: 'png',
      );

      await manager.dispose();
      await manager.dispose();
    });

    test('emptyCache followed by dispose is safe', () async {
      final manager = DefaultCacheManager(hiveInstance: testHive);
      await manager.putFile(
        'https://example.com/web-empty-dispose.png',
        [1, 2, 3],
        fileExtension: 'png',
      );

      await manager.emptyCache();
      await manager.dispose();

      final manager2 = DefaultCacheManager(hiveInstance: testHive);
      final cached = await manager2.getFileFromCache(
        'https://example.com/web-empty-dispose.png',
      );
      expect(cached, isNull);

      await manager2.dispose();
    });

    test('operations after dispose re-initialize gracefully', () async {
      final manager = DefaultCacheManager(hiveInstance: testHive);
      await manager.putFile(
        'https://example.com/web-reuse.png',
        [1],
        fileExtension: 'png',
      );
      await manager.dispose();

      // Using the manager after dispose should re-initialize
      final cached = await manager.getFileFromCache(
        'https://example.com/web-reuse.png',
      );
      expect(cached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // =====================================================================
  // Cleanup / eviction
  // =====================================================================

  group('WebCacheManager cleanup', () {
    test('enforces maxNrOfCacheObjects by evicting oldest entries', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        maxNrOfCacheObjects: 3,
        stalePeriod: const Duration(days: 1),
      );

      // Add 5 entries with staggered validTill
      for (var i = 0; i < 5; i++) {
        await manager.putFile(
          'https://example.com/cleanup-$i.png',
          [i],
          maxAge: Duration(hours: i + 1),
          fileExtension: 'png',
        );
      }

      // Trigger cleanup by disposing and re-creating
      await manager.dispose();
      final manager2 =
          DefaultCacheManager(hiveInstance: testHive, maxNrOfCacheObjects: 3);

      // The newest 3 entries should survive, oldest 2 may be cleaned up
      // (cleanup runs in background on init, wait until it finishes via polling)
      bool cleanupSuccess = false;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final oldest = await manager2.getFileFromCache(
          'https://example.com/cleanup-0.png',
        );
        if (oldest == null) {
          cleanupSuccess = true;
          break;
        }
      }

      expect(cleanupSuccess, isTrue,
          reason: 'Background cleanup failed or timed out');

      // At minimum, the newest entries should be available
      final newest = await manager2.getFileFromCache(
        'https://example.com/cleanup-4.png',
      );
      expect(newest, isNotNull);

      await manager2.emptyCache();
      await manager2.dispose();
    });
  });

  // =====================================================================
  // StreamController / http.Client lifecycle (leak checks)
  // =====================================================================

  group('WebCacheManager leak checks', () {
    test('StreamController is closed after successful download', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('data', 200),
        ),
      );

      final stream =
          manager.getFileStream('https://example.com/web-leak-ok.png');
      final events = await stream.toList();
      expect(events.whereType<FileInfo>().isNotEmpty, isTrue);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('StreamController is closed after HTTP error', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('err', 500),
        ),
      );

      Object? error;
      try {
        await manager
            .getFileStream('https://example.com/web-leak-err.png')
            .toList();
      } on Object catch (e) {
        error = e;
      }

      expect(error, isNotNull);
      await manager.dispose();
    });

    test('http.Client is reused across downloads and closed by dispose',
        () async {
      var factoryCalls = 0;
      var closeCalls = 0;
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
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
          .getFileStream('https://example.com/web-client-first.png')
          .toList();
      await manager
          .getFileStream('https://example.com/web-client-second.png')
          .toList();

      expect(factoryCalls, 1);
      expect(closeCalls, 0);

      await manager.dispose();
      expect(closeCalls, 1);

      await manager.dispose();
      expect(closeCalls, 1);
    });

    test('http.Client remains open after HTTP error until dispose', () async {
      var closeCalls = 0;
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
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
            .getFileStream('https://example.com/web-client-err.png')
            .toList();
      } on Object catch (_) {}

      expect(closeCalls, 0);

      await manager.dispose();
      expect(closeCalls, 1);
    });

    test('download after dispose creates and closes a new http.Client',
        () async {
      var factoryCalls = 0;
      var closeCalls = 0;
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
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
          .getFileStream('https://example.com/web-before-dispose.png')
          .toList();
      await manager.dispose();

      await manager
          .getFileStream('https://example.com/web-after-dispose.png')
          .toList();

      expect(factoryCalls, 2);
      expect(closeCalls, 2);

      await manager.dispose();
      expect(closeCalls, 2);
    });
  });

  // =====================================================================
  // ConnectionParameters / timeout tests
  // =====================================================================

  group('WebCacheManager with ConnectionParameters', () {
    late DefaultCacheManager manager;

    tearDown(() async {
      try {
        await manager.emptyCache();
        await manager.dispose();
      } on Object catch (_) {}
    });

    test('connectionParameters defaults to null', () {
      manager = DefaultCacheManager(hiveInstance: testHive);
      expect(manager.connectionParameters, isNull);
    });

    test('accepts connectionParameters', () {
      manager = DefaultCacheManager(
        hiveInstance: testHive,
        connectionParameters: ConnectionParameters(
          connectionTimeout: const Duration(seconds: 10),
          requestTimeout: const Duration(seconds: 30),
        ),
      );
      expect(manager.connectionParameters, isNotNull);
      expect(
        manager.connectionParameters!.connectionTimeout,
        const Duration(seconds: 10),
      );
      expect(
        manager.connectionParameters!.requestTimeout,
        const Duration(seconds: 30),
      );
    });

    test('connectionTimeout triggers TimeoutException when server is slow',
        () async {
      manager = DefaultCacheManager(
        hiveInstance: testHive,
        connectionParameters: ConnectionParameters(
          connectionTimeout: const Duration(milliseconds: 100),
        ),
        httpClientFactory: () => http_testing.MockClient.streaming(
          (request, bodyStream) async {
            await Future<void>.delayed(const Duration(seconds: 10));
            return http.StreamedResponse(const Stream.empty(), 200);
          },
        ),
      );

      final stream =
          manager.getFileStream('https://example.com/slow-connect.png');
      await expectLater(stream, emitsError(isA<TimeoutException>()));
    });

    test('requestTimeout triggers TimeoutException when stream stalls',
        () async {
      manager = DefaultCacheManager(
        hiveInstance: testHive,
        connectionParameters: ConnectionParameters(
          requestTimeout: const Duration(milliseconds: 100),
        ),
        httpClientFactory: () => http_testing.MockClient.streaming(
          (request, bodyStream) async {
            final controller = StreamController<List<int>>();
            // Send one chunk then stall indefinitely.
            controller.add([1, 2, 3, 4]);
            return http.StreamedResponse(
              controller.stream,
              200,
              contentLength: 100,
            );
          },
        ),
      );

      final stream = manager.getFileStream('https://example.com/stalled.png');
      await expectLater(stream, emitsError(isA<TimeoutException>()));
    });

    test('no timeout when connectionParameters is null', () async {
      manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('data', 200),
        ),
      );

      final events = await manager
          .getFileStream('https://example.com/no-timeout.dat')
          .toList();
      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, isNotEmpty);
    });

    test('successful download with connectionParameters set', () async {
      manager = DefaultCacheManager(
        hiveInstance: testHive,
        connectionParameters: ConnectionParameters(
          connectionTimeout: const Duration(seconds: 5),
          requestTimeout: const Duration(seconds: 5),
        ),
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('image-data', 200),
        ),
      );

      final events =
          await manager.getFileStream('https://example.com/fast.png').toList();
      final fileInfos = events.whereType<FileInfo>().toList();
      expect(fileInfos, isNotEmpty);
      expect(fileInfos.first.source.name, 'Online');
    });

    test('client remains open after connection timeout until dispose',
        () async {
      var clientClosed = false;
      var requestAborted = false;

      manager = DefaultCacheManager(
        hiveInstance: testHive,
        connectionParameters: ConnectionParameters(
          connectionTimeout: const Duration(milliseconds: 50),
        ),
        httpClientFactory: () => AbortTrackingClient(
          onAbort: () {
            requestAborted = true;
          },
          onClose: () {
            clientClosed = true;
          },
        ),
      );

      Object? error;
      try {
        await manager
            .getFileStream('https://example.com/close-test.png')
            .toList();
      } on Object catch (caught) {
        error = caught;
      }

      await Future<void>.delayed(Duration.zero);
      expect(error, isA<TimeoutException>());
      expect(requestAborted, isTrue);
      expect(clientClosed, isFalse);
      await manager.dispose();
      expect(clientClosed, isTrue);
    });

    test('connection timeout does not abort response body after headers',
        () async {
      var bodyCompleted = false;
      var abortTriggerCompleted = false;
      var abortedBeforeBodyCompleted = false;

      manager = DefaultCacheManager(
        hiveInstance: testHive,
        connectionParameters: ConnectionParameters(
          connectionTimeout: const Duration(milliseconds: 20),
        ),
        httpClientFactory: () => http_testing.MockClient.streaming(
          (request, bodyStream) async {
            final abortable = request as http.Abortable;
            unawaited(abortable.abortTrigger!.then((_) {
              abortTriggerCompleted = true;
              if (!bodyCompleted) {
                abortedBeforeBodyCompleted = true;
              }
            }));

            final controller = StreamController<List<int>>();
            unawaited(Future<void>.delayed(
              const Duration(milliseconds: 50),
              () async {
                controller.add([1, 2, 3]);
                bodyCompleted = true;
                await controller.close();
              },
            ));
            return http.StreamedResponse(controller.stream, 200);
          },
        ),
      );

      final events = await manager
          .getFileStream('https://example.com/slow-body.png')
          .toList();
      await Future<void>.delayed(Duration.zero);

      expect(events.whereType<FileInfo>(), isNotEmpty);
      expect(bodyCompleted, isTrue);
      expect(abortTriggerCompleted, isTrue);
      expect(abortedBeforeBodyCompleted, isFalse);
    });
  });

  // ---- Hive String Key Length Limit ----

  group('Hive string key length limit fix', () {
    test('handles keys longer than 255 characters without HiveError', () async {
      final manager = DefaultCacheManager(
        hiveInstance: testHive,
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('data', 200),
        ),
      );

      final longKey = 'https://example.com/very-long-url-'.padRight(300, 'a');

      // 1. putFile
      await manager.putFile(longKey, [1, 2, 3], fileExtension: 'bin');

      // 2. getFileFromCache
      final cached = await manager.getFileFromCache(longKey);
      expect(cached, isNotNull);
      expect(cached!.originalUrl, longKey);

      // 3. removeFile
      await manager.removeFile(longKey);
      final cachedAfterRemove = await manager.getFileFromCache(longKey);
      expect(cachedAfterRemove, isNull);

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
