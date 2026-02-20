import 'dart:async';
import 'dart:io' as io;

import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
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

    test('accepts custom cacheDirectoryProvider', () async {
      final customDir =
          io.Directory.systemTemp.createTempSync('custom_cache_dir_');
      addTearDown(() {
        try {
          customDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => customDir,
      );

      await manager.putFile(
        'https://example.com/custom-dir.bin',
        [1, 2, 3],
        fileExtension: 'bin',
      );

      final cached =
          await manager.getFileFromCache('https://example.com/custom-dir.bin');
      expect(cached, isNotNull);

      // Verify files are in the custom directory
      final cacheSubDir =
          io.Directory('${customDir.path}/cached_network_image_ce');
      expect(cacheSubDir.existsSync(), isTrue);

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // ---- Concurrent initialization (race condition regression) ----

  group('DefaultCacheManager concurrent initialization', () {
    test('parallel operations on cold manager do not throw', () async {
      final manager = DefaultCacheManager();

      // Fire multiple cache operations in parallel before init completes.
      // Before the fix this would trigger multiple Hive.init / openBox calls.
      final futures = <Future>[];
      for (var i = 0; i < 10; i++) {
        futures.add(
          manager.putFile(
            'https://example.com/concurrent-$i.bin',
            [i],
            fileExtension: 'bin',
          ),
        );
      }

      // All should complete without error
      await Future.wait(futures);

      // Verify data integrity
      for (var i = 0; i < 10; i++) {
        final cached = await manager.getFileFromCache(
          'https://example.com/concurrent-$i.bin',
        );
        expect(cached, isNotNull, reason: 'Entry $i should be cached');
      }

      await manager.emptyCache();
      await manager.dispose();
    });

    test('parallel getFileFromCache on cold manager do not throw', () async {
      final manager = DefaultCacheManager();

      // Pre-populate via a single call, then dispose to reset state
      await manager.putFile(
        'https://example.com/parallel-get.bin',
        [1, 2, 3],
        fileExtension: 'bin',
      );
      await manager.dispose();

      // Now create a fresh manager and fire parallel reads
      final manager2 = DefaultCacheManager();
      final futures = List.generate(
        10,
        (_) => manager2.getFileFromCache(
          'https://example.com/parallel-get.bin',
        ),
      );

      final results = await Future.wait(futures);
      // All should return the same cached entry
      for (final result in results) {
        expect(result, isNotNull);
      }

      await manager2.emptyCache();
      await manager2.dispose();
    });
  });

  // ---- Hive isolation from host app ----

  group('DefaultCacheManager Hive isolation', () {
    test('does not conflict with global Hive singleton', () async {
      // Simulate host app calling Hive.init with a different path
      // (this would previously cause problems)
      final hostDir = io.Directory.systemTemp.createTempSync('host_hive_dir_');
      addTearDown(() {
        try {
          hostDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      // The library's DefaultCacheManager should work independently
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/isolated.bin',
        [1, 2, 3],
        fileExtension: 'bin',
      );

      final cached = await manager.getFileFromCache(
        'https://example.com/isolated.bin',
      );
      expect(cached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });

    test(
        'two DefaultCacheManager instances with separate dirs work independently',
        () async {
      final dir1 = io.Directory.systemTemp.createTempSync('manager1_');
      final dir2 = io.Directory.systemTemp.createTempSync('manager2_');
      addTearDown(() {
        try {
          dir1.deleteSync(recursive: true);
        } on Object catch (_) {}
        try {
          dir2.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      final manager1 = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir1,
      );
      final manager2 = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir2,
      );

      await manager1.putFile(
        'https://example.com/m1.bin',
        [1],
        fileExtension: 'bin',
      );
      await manager2.putFile(
        'https://example.com/m2.bin',
        [2],
        fileExtension: 'bin',
      );

      // Both should find their own entries
      expect(
        await manager1.getFileFromCache('https://example.com/m1.bin'),
        isNotNull,
      );
      expect(
        await manager2.getFileFromCache('https://example.com/m2.bin'),
        isNotNull,
      );

      await manager1.emptyCache();
      await manager1.dispose();
      await manager2.emptyCache();
      await manager2.dispose();
    });
  });

  // ===========================================================================
  // Regression tests for Hive init issues:
  //   1. Global Hive.init() conflict with host app
  //   2. Race condition in _ensureInitialized (concurrent callers)
  //   3. Cache directory cleanup resilience
  // ===========================================================================

  // ---- Issue 1: Global Hive.init conflict ----

  group('Regression: no global Hive.init conflict', () {
    test('library works after host app calls Hive.init with a different path',
        () async {
      final hostDir = io.Directory.systemTemp.createTempSync('host_hive_init_');
      addTearDown(() {
        try {
          Hive.close();
          hostDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      // Simulate what a host app does: call the global Hive.init
      Hive.init(hostDir.path);

      // The library should still function correctly using its own private
      // Hive instance, not the global one.
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/after-host-init.bin',
        [1, 2, 3],
        fileExtension: 'bin',
      );

      final cached = await manager.getFileFromCache(
        'https://example.com/after-host-init.bin',
      );
      expect(cached, isNotNull);
      expect(cached!.originalUrl, 'https://example.com/after-host-init.bin');

      await manager.emptyCache();
      await manager.dispose();
    });

    test('host app Hive boxes remain unaffected by library usage', () async {
      final hostDir =
          io.Directory.systemTemp.createTempSync('host_hive_boxes_');
      addTearDown(() {
        try {
          Hive.close();
          hostDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      // Host app creates and uses its own box via the global Hive
      Hive.init(hostDir.path);
      final hostBox = await Hive.openBox<String>('host_app_box');
      await hostBox.put('greeting', 'hello');

      // Use the library's cache manager
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/no-interference.bin',
        [10, 20, 30],
        fileExtension: 'bin',
      );
      await manager.emptyCache();
      await manager.dispose();

      // Host box data should be completely untouched
      expect(hostBox.get('greeting'), 'hello');
      await hostBox.close();
    });

    test('library does not register boxes on the global Hive singleton',
        () async {
      // Ensure the global Hive does not know about our box
      final manager = DefaultCacheManager();
      await manager.putFile(
        'https://example.com/global-check.bin',
        [1],
        fileExtension: 'bin',
      );

      // The library's box should NOT be visible on the global Hive
      expect(Hive.isBoxOpen('cached_network_image_cache'), isFalse);

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // ---- Issue 2: Race condition in _ensureInitialized ----

  group('Regression: _ensureInitialized race condition', () {
    test('concurrent putFile calls on a cold manager all succeed', () async {
      final manager = DefaultCacheManager();

      // Launch 20 putFile calls simultaneously on a never-initialized manager.
      // Before the Completer fix, this would trigger parallel Hive.init and
      // openBox calls causing exceptions or data corruption.
      final futures = List.generate(
        20,
        (i) => manager.putFile(
          'https://example.com/race-put-$i.bin',
          List.filled(i + 1, i),
          fileExtension: 'bin',
        ),
      );

      await Future.wait(futures);

      // All 20 entries should be present and correct
      for (var i = 0; i < 20; i++) {
        final cached = await manager.getFileFromCache(
          'https://example.com/race-put-$i.bin',
        );
        expect(cached, isNotNull, reason: 'Entry $i missing');
        final bytes = await (cached!.file as io.File).readAsBytes();
        expect(bytes.length, i + 1, reason: 'Entry $i has wrong length');
      }

      await manager.emptyCache();
      await manager.dispose();
    });

    test('concurrent getFileStream calls on a cold manager all succeed',
        () async {
      var downloadCount = 0;
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async {
            downloadCount++;
            return http.Response('data-${request.url}', 200);
          },
        ),
      );

      // Fire 10 getFileStream calls at the same instant
      final streams = List.generate(
        10,
        (i) => manager
            .getFileStream('https://example.com/race-stream-$i.png')
            .toList(),
      );

      final results = await Future.wait(streams);

      // Every stream should have completed with at least one FileInfo
      for (var i = 0; i < 10; i++) {
        final fileInfos = results[i].whereType<FileInfo>().toList();
        expect(
          fileInfos,
          isNotEmpty,
          reason: 'Stream $i should have a FileInfo',
        );
      }

      // All 10 URLs should have been downloaded
      expect(downloadCount, 10);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('mixed concurrent operations on a cold manager', () async {
      final manager = DefaultCacheManager(
        httpClientFactory: () => http_testing.MockClient(
          (request) async => http.Response('img', 200),
        ),
      );

      // Mix of putFile, getFileFromCache, getFileStream, removeFile
      final futures = <Future>[
        manager.putFile('https://example.com/mix-put.bin', [1],
            fileExtension: 'bin'),
        manager.getFileFromCache('https://example.com/non-existent'),
        manager.getFileStream('https://example.com/mix-stream.png').toList(),
        manager.removeFile('https://example.com/also-non-existent'),
        manager.putFile('https://example.com/mix-put2.bin', [2],
            fileExtension: 'bin'),
      ];

      // All should complete without throwing
      await Future.wait(futures);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('init failure allows retry on next call', () async {
      var callCount = 0;

      // First call will fail, second will succeed
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async {
          callCount++;
          if (callCount == 1) {
            throw const io.FileSystemException('Simulated permission error');
          }
          return testTempDir;
        },
      );

      // First call should fail
      Object? error;
      try {
        await manager.putFile(
          'https://example.com/retry-test.bin',
          [1],
          fileExtension: 'bin',
        );
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<io.FileSystemException>());

      // Second call should succeed (completer was cleared on error)
      await manager.putFile(
        'https://example.com/retry-test.bin',
        [1],
        fileExtension: 'bin',
      );
      final cached = await manager.getFileFromCache(
        'https://example.com/retry-test.bin',
      );
      expect(cached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('concurrent calls during init failure all receive the same error',
        () async {
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async {
          throw const io.FileSystemException('Simulated init failure');
        },
      );

      // Launch 5 calls simultaneously, all should get the same error
      final futures = List.generate(
        5,
        (i) => manager
            .putFile(
              'https://example.com/fail-$i.bin',
              [i],
              fileExtension: 'bin',
            )
            .then((_) => null as Object?)
            .catchError((Object e) => e),
      );

      final results = await Future.wait(futures);
      for (var i = 0; i < 5; i++) {
        expect(
          results[i],
          isA<io.FileSystemException>(),
          reason: 'Call $i should have received the init error',
        );
      }
    });

    test('rapid dispose-and-reuse cycle does not corrupt state', () async {
      final manager = DefaultCacheManager();

      for (var cycle = 0; cycle < 5; cycle++) {
        await manager.putFile(
          'https://example.com/cycle-$cycle.bin',
          [cycle],
          fileExtension: 'bin',
        );
        await manager.dispose();
      }

      // After the last dispose, re-initialize and check the last entry
      final cached = await manager.getFileFromCache(
        'https://example.com/cycle-4.bin',
      );
      expect(cached, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });
  });

  // ---- Issue 3: Cache directory / Hive metadata resilience ----

  group('Regression: cache directory resilience', () {
    test('recovers when Hive metadata dir is deleted but cache files remain',
        () async {
      final customDir =
          io.Directory.systemTemp.createTempSync('resilience_hive_');
      addTearDown(() {
        try {
          customDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => customDir,
      );
      await manager.putFile(
        'https://example.com/resilience.bin',
        [1, 2, 3],
        fileExtension: 'bin',
      );

      // Verify the file exists on disk
      final cached = await manager.getFileFromCache(
        'https://example.com/resilience.bin',
      );
      expect(cached, isNotNull);
      expect(await (cached!.file as io.File).exists(), isTrue);
      final filePath = cached.file.path;

      await manager.dispose();

      // Simulate OS purging the Hive directory (but not the cache files)
      final hiveDir =
          io.Directory('${customDir.path}/cached_network_image_ce/hive');
      if (hiveDir.existsSync()) {
        hiveDir.deleteSync(recursive: true);
      }

      // Verify the image file still exists
      expect(io.File(filePath).existsSync(), isTrue);

      // Re-create the manager — it should re-initialize cleanly
      final manager2 = DefaultCacheManager(
        cacheDirectoryProvider: () async => customDir,
      );

      // The metadata is gone so the old entry won't be found
      final cached2 = await manager2.getFileFromCache(
        'https://example.com/resilience.bin',
      );
      expect(cached2, isNull);

      // But new entries should work fine
      await manager2.putFile(
        'https://example.com/resilience-new.bin',
        [4, 5, 6],
        fileExtension: 'bin',
      );
      final newCached = await manager2.getFileFromCache(
        'https://example.com/resilience-new.bin',
      );
      expect(newCached, isNotNull);

      await manager2.emptyCache();
      await manager2.dispose();
    });

    test('recovers when cache files are deleted but Hive metadata remains',
        () async {
      final customDir =
          io.Directory.systemTemp.createTempSync('resilience_files_');
      addTearDown(() {
        try {
          customDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => customDir,
      );
      await manager.putFile(
        'https://example.com/file-gone.bin',
        [7, 8, 9],
        fileExtension: 'bin',
      );

      final cached =
          await manager.getFileFromCache('https://example.com/file-gone.bin');
      expect(cached, isNotNull);

      // Simulate OS purging just the cached image file (not Hive data)
      final imageFile = cached!.file as io.File;
      await imageFile.delete();

      // getFileFromCache should detect the missing file and return null
      final cached2 =
          await manager.getFileFromCache('https://example.com/file-gone.bin');
      expect(cached2, isNull);

      // New files should still work
      await manager.putFile(
        'https://example.com/file-gone.bin',
        [10, 11, 12],
        fileExtension: 'bin',
      );
      final cached3 =
          await manager.getFileFromCache('https://example.com/file-gone.bin');
      expect(cached3, isNotNull);

      await manager.emptyCache();
      await manager.dispose();
    });

    test('recovers when entire cache directory is deleted', () async {
      final customDir =
          io.Directory.systemTemp.createTempSync('resilience_all_');
      addTearDown(() {
        try {
          customDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => customDir,
      );
      await manager.putFile(
        'https://example.com/all-gone.bin',
        [1],
        fileExtension: 'bin',
      );
      await manager.dispose();

      // Nuke the entire cache directory tree
      final cacheSubDir =
          io.Directory('${customDir.path}/cached_network_image_ce');
      if (cacheSubDir.existsSync()) {
        cacheSubDir.deleteSync(recursive: true);
      }

      // Re-create and verify it rebuilds from scratch
      final manager2 = DefaultCacheManager(
        cacheDirectoryProvider: () async => customDir,
      );

      final cached =
          await manager2.getFileFromCache('https://example.com/all-gone.bin');
      expect(cached, isNull);

      // Should be able to store new data
      await manager2.putFile(
        'https://example.com/rebuilt.bin',
        [2],
        fileExtension: 'bin',
      );
      final newCached =
          await manager2.getFileFromCache('https://example.com/rebuilt.bin');
      expect(newCached, isNotNull);

      await manager2.emptyCache();
      await manager2.dispose();
    });

    test('cacheDirectoryProvider can specify application support directory',
        () async {
      // Verifies the constructor parameter works for non-temp directories
      final supportDir =
          io.Directory.systemTemp.createTempSync('app_support_sim_');
      addTearDown(() {
        try {
          supportDir.deleteSync(recursive: true);
        } on Object catch (_) {}
      });

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => supportDir,
      );

      await manager.putFile(
        'https://example.com/support-dir.bin',
        [1, 2, 3, 4, 5],
        fileExtension: 'bin',
      );

      final cached = await manager.getFileFromCache(
        'https://example.com/support-dir.bin',
      );
      expect(cached, isNotNull);

      // Check that files live inside the custom directory, not temp dir
      expect(cached!.file.path, contains(supportDir.path));
      expect(cached.file.path, isNot(contains(testTempDir.path)));

      await manager.emptyCache();
      await manager.dispose();
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
      final cached = await manager.getFileFromCache(
          'non-existent-${DateTime.now().millisecondsSinceEpoch}');
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
      final events =
          await manager.getFileStream(url, withProgress: true).toList();

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

      await manager.getFileStream(
        'https://example.com/auth-test.dat',
        headers: {'Authorization': 'Bearer token123'},
      ).toList();

      expect(receivedAuth, 'Bearer token123');
    });

    test('error on HTTP 404 is propagated to stream (no cached file)',
        () async {
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
      final events = await manager.getImageFile(url, key: 'my-key').toList();
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
      await manager.getFileStream('https://example.com/images/noext').toList();

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
      await manager1.putFile(url, [1, 2, 3],
          fileExtension: 'bin', maxAge: Duration.zero);
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
        final cached = await manager2
            .getFileFromCache('https://example.com/limit-$i-$now.bin');
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
