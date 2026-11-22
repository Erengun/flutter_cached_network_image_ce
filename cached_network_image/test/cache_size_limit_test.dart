import 'dart:io' as io;

import 'package:cached_network_image_ce/cached_network_image.dart'
    show CleanupStrategy, LruCleanupStrategy;
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

void main() {
  group('IO byte limit', () {
    test('defaults to no byte limit', () {
      expect(DefaultCacheManager().maxCacheSizeInBytes, isNull);
    });

    test('rejects a non-positive limit', () {
      expect(
        () => DefaultCacheManager(maxCacheSizeInBytes: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a store over the limit evicts in strategy order without startCleanup',
        () async {
      final dir = _temporaryDirectory('byte_limit_store_');
      final t0 = DateTime.utc(2026, 1, 1);
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 100,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(manager.dispose);

      await withClock(Clock.fixed(t0), () {
        return manager.putFile('https://example.com/a', _bytes(40), key: 'a');
      });
      await withClock(Clock.fixed(t0.add(const Duration(minutes: 1))), () {
        return manager.putFile('https://example.com/b', _bytes(40), key: 'b');
      });
      await withClock(Clock.fixed(t0.add(const Duration(minutes: 2))), () {
        return manager.putFile('https://example.com/c', _bytes(40), key: 'c');
      });
      await _waitForEviction();

      expect(await manager.getFileFromCache('a'), isNull);
      expect(await manager.getFileFromCache('b'), isNotNull);
      expect(await manager.getFileFromCache('c'), isNotNull);
      expect(await manager.getCacheSize(), lessThanOrEqualTo(100));
    });

    test('byte eviction does not enforce the count cap', () async {
      final dir = _temporaryDirectory('byte_limit_count_cap_');
      final t0 = DateTime.utc(2026, 1, 1);
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxNrOfCacheObjects: 2,
        maxCacheSizeInBytes: 1000,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(manager.dispose);

      for (var i = 0; i < 4; i++) {
        await withClock(Clock.fixed(t0.add(Duration(minutes: i))), () {
          return manager.putFile(
            'https://example.com/count-$i',
            _bytes(10),
            key: 'count-$i',
          );
        });
      }
      await _waitForEviction();

      for (var i = 0; i < 4; i++) {
        expect(await manager.getFileFromCache('count-$i'), isNotNull);
      }
    });

    test(
        'protected entries keep the cache over the limit until cleanup after '
        'expiry', () async {
      final dir = _temporaryDirectory('byte_limit_protected_');
      final t0 = DateTime.utc(2026, 1, 1);
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 50,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(manager.dispose);

      await withClock(Clock.fixed(t0), () async {
        await manager.putFile('https://example.com/a', _bytes(40), key: 'a');
        await manager.putFile('https://example.com/b', _bytes(40), key: 'b');
      });
      await _waitForEviction();

      // Check under t0 so the reads do not extend protection past t0 + 30 s.
      await withClock(Clock.fixed(t0), () async {
        expect(await manager.getFileFromCache('a'), isNotNull);
        expect(await manager.getFileFromCache('b'), isNotNull);
      });

      await withClock(
        Clock.fixed(t0.add(const Duration(seconds: 31))),
        manager.debugRunCleanup,
      );

      final present = [
        await manager.getFileFromCache('a'),
        await manager.getFileFromCache('b'),
      ].where((file) => file != null);
      expect(present, hasLength(1));
    });

    test('startup sweep enforces the byte limit', () async {
      final dir = _temporaryDirectory('byte_limit_startup_');
      final t0 = DateTime.utc(2026, 1, 1);
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
      );
      await withClock(Clock.fixed(t0), () async {
        for (var i = 0; i < 3; i++) {
          await writer.putFile(
            'https://example.com/startup-$i',
            _bytes(40),
            key: 'startup-$i',
          );
        }
      });
      await writer.dispose();

      final reader = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 100,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(reader.dispose);

      await withClock(
        Clock.fixed(t0.add(const Duration(hours: 1))),
        reader.debugRunCleanup,
      );

      expect(await reader.getCacheSize(), lessThanOrEqualTo(100));
    });

    test('entries without length count as zero bytes', () async {
      final dir = _temporaryDirectory('byte_limit_legacy_');
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
      );
      await writer.putFile(
        'https://example.com/legacy',
        _bytes(50),
        key: 'legacy',
      );
      await writer.dispose();

      final box = await Hive.openBox<Map>(
        'cached_network_image_cache',
        path: '${dir.path}/cached_network_image_ce/hive',
      );
      final legacy = Map<dynamic, dynamic>.from(box.get('legacy')!)
        ..remove('length');
      await box.put('legacy', legacy);
      await box.close();

      final reader = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 10,
        cleanupOnInitialize: false,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(reader.dispose);

      await reader.putFile('https://example.com/new', _bytes(5), key: 'new');
      await _waitForEviction();

      expect(await reader.getFileFromCache('legacy'), isNotNull);
      expect(await reader.getFileFromCache('new'), isNotNull);
    });

    test('concurrent stores over the limit settle under it', () async {
      final dir = _temporaryDirectory('byte_limit_concurrent_');
      final t0 = DateTime.utc(2026, 1, 1);
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 100,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(manager.dispose);

      await withClock(Clock.fixed(t0), () {
        return Future.wait([
          for (var i = 0; i < 10; i++)
            manager.putFile(
              'https://example.com/concurrent-$i',
              _bytes(30),
              key: 'concurrent-$i',
            ),
        ]);
      });
      await _waitForEviction();

      await withClock(
        Clock.fixed(t0.add(const Duration(seconds: 31))),
        manager.debugRunCleanup,
      );

      expect(await manager.getCacheSize(), lessThanOrEqualTo(100));
    });

    test('dispose during byte eviction is clean', () async {
      final dir = _temporaryDirectory('byte_limit_dispose_');
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 10,
        cleanupStrategy: const LruCleanupStrategy(),
      );

      await manager.putFile('https://example.com/d0', _bytes(10), key: 'd0');
      await manager.putFile('https://example.com/d1', _bytes(10), key: 'd1');
      await manager.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('overwriting a key counts only the new length', () async {
      final dir = _temporaryDirectory('byte_limit_overwrite_');
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 100,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(manager.dispose);

      await manager.putFile('https://example.com/k', _bytes(30), key: 'k');
      await manager.putFile('https://example.com/k', _bytes(60), key: 'k');
      await _waitForEviction();

      expect(await manager.getFileFromCache('k'), isNotNull);
      expect(await manager.getCacheSize(), 60);
    });

    test('a sweep retry under the byte limit does not enforce the count cap',
        () async {
      final dir = _temporaryDirectory('byte_limit_retry_count_cap_');
      final t0 = DateTime.utc(2026, 1, 1);
      var now = t0;
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxNrOfCacheObjects: 2,
        maxCacheSizeInBytes: 1000,
        cleanupOnInitialize: false,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      addTearDown(manager.dispose);

      await withClock(Clock(() => now), () async {
        for (var i = 0; i < 3; i++) {
          await manager.putFile(
            'https://example.com/retry-$i',
            _bytes(10),
            key: 'retry-$i',
          );
        }

        // All entries are protected, so the sweep arms a retry that fires
        // 10 ms later, when their protection has expired.
        now = t0.add(const Duration(seconds: 29, milliseconds: 990));
        await manager.debugRunCleanup();
        now = t0.add(const Duration(seconds: 31));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });

      for (var i = 0; i < 3; i++) {
        expect(await manager.getFileFromCache('retry-$i'), isNotNull);
      }
    });

    test('no limit: stores above the count cap trigger no runtime sweep',
        () async {
      final dir = _temporaryDirectory('byte_limit_none_');
      final t0 = DateTime.utc(2026, 1, 1);
      final strategy = _CountingLruCleanupStrategy();
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxNrOfCacheObjects: 2,
        cleanupStrategy: strategy,
      );
      addTearDown(manager.dispose);

      await manager.debugRunCleanup();
      await withClock(Clock.fixed(t0), () async {
        for (var i = 0; i < 3; i++) {
          await manager.putFile(
            'https://example.com/none-$i',
            [i],
            key: 'none-$i',
          );
        }
      });
      await _waitForEviction();

      expect(strategy.calls, 0);
    });
  });

  group('IO oversized entries', () {
    test('oversized download is delivered but not cached', () async {
      final dir = _temporaryDirectory('oversized_download_');
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 10,
        httpClientFactory: () => _respondWith(_bytes(20)),
      );
      addTearDown(manager.dispose);
      const url = 'https://example.com/oversized';

      final info = await manager
          .getFileStream(url)
          .where((response) => response is FileInfo)
          .cast<FileInfo>()
          .last;
      addTearDown(() => _deleteQuietly(info.file.path));

      expect(await info.file.exists(), isTrue);
      expect(await info.file.length(), 20);
      expect(info.file.path, isNot(startsWith(dir.path)));
      expect(await manager.getFileFromCache(url), isNull);
      expect(await manager.getCacheSize(), 0);
    });

    test('oversized download removes the previous entry for the key', () async {
      final dir = _temporaryDirectory('oversized_previous_');
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 10,
        httpClientFactory: () => _respondWith(_bytes(20)),
      );
      addTearDown(manager.dispose);
      const url = 'https://example.com/previous';

      final oldFile =
          await manager.putFile(url, _bytes(5), maxAge: Duration.zero);
      final info = await manager
          .getFileStream(url)
          .where((response) => response is FileInfo)
          .cast<FileInfo>()
          .last;
      addTearDown(() => _deleteQuietly(info.file.path));

      expect(info.source, FileSource.Online);
      expect(await manager.getFileFromCache(url), isNull);
      expect(await oldFile.exists(), isFalse);
    });

    test('oversized putFile is returned but not cached', () async {
      final dir = _temporaryDirectory('oversized_put_');
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 10,
      );
      addTearDown(manager.dispose);
      const url = 'https://example.com/put';

      final file = await manager.putFile(url, _bytes(20));
      addTearDown(() => _deleteQuietly(file.path));

      expect(await file.exists(), isTrue);
      expect(await file.length(), 20);
      expect(await manager.getFileFromCache(url), isNull);
    });

    test('entry exactly at the limit is cached', () async {
      final dir = _temporaryDirectory('oversized_exact_');
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxCacheSizeInBytes: 10,
      );
      addTearDown(manager.dispose);
      const url = 'https://example.com/exact';

      await manager.putFile(url, _bytes(10));

      expect(await manager.getFileFromCache(url), isNotNull);
    });
  });
}

List<int> _bytes(int length) => List.filled(length, 0);

http.Client _respondWith(List<int> bytes) =>
    http_testing.MockClient((_) async => http.Response.bytes(bytes, 200));

void _deleteQuietly(String filePath) {
  try {
    io.File(filePath).deleteSync();
  } on Object catch (_) {}
}

Future<void> _waitForEviction() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

final class _CountingLruCleanupStrategy extends CleanupStrategy {
  int calls = 0;

  @override
  List<MapEntry<String, CacheEntryMetadata>> sortForEviction(
    List<MapEntry<String, CacheEntryMetadata>> entries,
  ) {
    calls++;
    return entries
      ..sort(
        (a, b) => a.value.effectiveTouchedAt.compareTo(
          b.value.effectiveTouchedAt,
        ),
      );
  }
}

io.Directory _temporaryDirectory(String prefix) {
  final directory = io.Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    try {
      directory.deleteSync(recursive: true);
    } on Object catch (_) {}
  });
  return directory;
}
