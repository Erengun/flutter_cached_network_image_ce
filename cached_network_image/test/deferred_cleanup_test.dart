import 'dart:async';
import 'dart:io' as io;

import 'package:cached_network_image_ce/cached_network_image.dart'
    show CleanupStrategy, LruCleanupStrategy;
import 'package:cached_network_image_ce/src/cache/cleanup_coordinator.dart';
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/hive_impl.dart';

void main() {
  group('deferred idle cleanup', () {
    test('defaults preserve initialization cleanup based on validTill', () {
      final manager = DefaultCacheManager();

      expect(manager.cleanupOnInitialize, isTrue);
      expect(manager.maxIdleDuration, isNull);
    });

    test('default startup cleanup does not enable runtime capacity sweeps',
        () async {
      final dir = _temporaryDirectory('cleanup_runtime_opt_in_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final strategy = _CountingLruCleanupStrategy();
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        maxNrOfCacheObjects: 2,
        cleanupStrategy: strategy,
      );

      await manager.debugRunCleanup();
      await withClock(Clock.fixed(createdAt), () async {
        for (var i = 0; i < 3; i++) {
          await manager.putFile(
            'https://example.com/default-$i',
            [i],
            key: 'default-$i',
          );
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(strategy.calls, 0);

      await withClock(
        Clock.fixed(createdAt.add(const Duration(seconds: 31))),
        manager.startCleanup,
      );
      expect(strategy.calls, 1);
      await manager.dispose();
    });

    test('deferred initialization leaves expired and excess entries intact',
        () async {
      final dir = _temporaryDirectory('cleanup_deferred_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 2,
      );

      await withClock(Clock.fixed(createdAt), () async {
        for (var i = 0; i < 3; i++) {
          await writer.putFile(
            'https://example.com/deferred-$i',
            [i],
            key: 'deferred-$i',
            maxAge: Duration.zero,
          );
        }
      });
      await writer.dispose();

      final reader = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 2,
      );
      await withClock(
        Clock.fixed(createdAt.add(const Duration(days: 1))),
        () async {
          for (var i = 0; i < 3; i++) {
            expect(await reader.getFileFromCache('deferred-$i'), isNotNull);
          }
        },
      );
      await reader.dispose();
    });

    test('concurrent startCleanup calls share cleanup and remain idempotent',
        () async {
      final dir = _temporaryDirectory('cleanup_concurrent_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 2,
      );
      await withClock(Clock.fixed(createdAt), () async {
        for (var i = 0; i < 4; i++) {
          await writer.putFile(
            'https://example.com/concurrent-$i',
            [i],
            key: 'concurrent-$i',
          );
        }
      });
      await writer.dispose();

      final strategy = _CountingLruCleanupStrategy();
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 2,
        cleanupStrategy: strategy,
      );
      await withClock(
        Clock.fixed(createdAt.add(const Duration(minutes: 1))),
        () async {
          await Future.wait(List.generate(5, (_) => manager.startCleanup()));
          expect(await _existingCount(manager, 'concurrent', 4), 2);
          expect(strategy.calls, 1);

          await manager.startCleanup();
          expect(await _existingCount(manager, 'concurrent', 4), 2);
          expect(strategy.calls, 1);
        },
      );
      await manager.dispose();
    });

    test('recent access retains an entry even when validTill is old', () async {
      final dir = _temporaryDirectory('cleanup_recent_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxIdleDuration: const Duration(hours: 1),
      );
      await withClock(Clock.fixed(createdAt), () async {
        await writer.putFile(
          'https://example.com/recent',
          [1],
          key: 'recent',
          maxAge: const Duration(hours: -1),
        );
      });
      await writer.dispose();

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxIdleDuration: const Duration(hours: 1),
      );
      final accessedAt = createdAt.add(const Duration(hours: 2));
      await withClock(Clock.fixed(accessedAt), () async {
        expect(await manager.getFileFromCache('recent'), isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await withClock(
        Clock.fixed(accessedAt.add(const Duration(seconds: 31))),
        () => manager.startCleanup(),
      );

      expect(await manager.getFileFromCache('recent'), isNotNull);
      await manager.dispose();
    });

    test('entry idle for maxIdleDuration is removed', () async {
      final dir = _temporaryDirectory('cleanup_idle_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxIdleDuration: const Duration(hours: 1),
      );
      await withClock(Clock.fixed(createdAt), () async {
        await writer.putFile(
          'https://example.com/idle',
          [1],
          key: 'idle',
        );
      });
      await writer.dispose();

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxIdleDuration: const Duration(hours: 1),
      );
      await withClock(
        Clock.fixed(createdAt.add(const Duration(hours: 1))),
        () => manager.startCleanup(),
      );

      expect(await manager.getFileFromCache('idle'), isNull);
      await manager.dispose();
    });

    test('legacy entries use validTill as the idle timestamp', () async {
      final dir = _temporaryDirectory('cleanup_legacy_');
      final now = DateTime.utc(2026, 1, 2);
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
      );
      await writer.putFile(
        'https://example.com/legacy-recent',
        [1],
        key: 'legacy-recent',
      );
      await writer.putFile(
        'https://example.com/legacy-old',
        [2],
        key: 'legacy-old',
      );
      await writer.dispose();
      await _makeLegacy(
          dir, 'legacy-recent', now.subtract(const Duration(minutes: 30)));
      await _makeLegacy(
          dir, 'legacy-old', now.subtract(const Duration(hours: 1)));

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxIdleDuration: const Duration(hours: 1),
      );
      await withClock(Clock.fixed(now), () => manager.startCleanup());

      expect(await manager.getFileFromCache('legacy-recent'), isNotNull);
      expect(await manager.getFileFromCache('legacy-old'), isNull);
      await manager.dispose();
    });

    test('startCleanup trims to the limit in LRU order', () async {
      final dir = _temporaryDirectory('cleanup_lru_deferred_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final writer = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 2,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      for (var i = 0; i < 4; i++) {
        await withClock(
          Clock.fixed(createdAt.add(Duration(minutes: i))),
          () => writer.putFile(
            'https://example.com/lru-$i',
            [i],
            key: 'lru-$i',
          ),
        );
      }
      await writer.dispose();

      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 2,
        cleanupStrategy: const LruCleanupStrategy(),
      );
      await withClock(
        Clock.fixed(createdAt.add(const Duration(hours: 1))),
        () => manager.startCleanup(),
      );

      expect(await manager.getFileFromCache('lru-0'), isNull);
      expect(await manager.getFileFromCache('lru-1'), isNull);
      expect(await manager.getFileFromCache('lru-2'), isNotNull);
      expect(await manager.getFileFromCache('lru-3'), isNotNull);
      await manager.dispose();
    });

    test('stores above the limit schedule cleanup only after it is enabled',
        () async {
      final dir = _temporaryDirectory('cleanup_store_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final strategy = _CountingLruCleanupStrategy();
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 2,
        cleanupStrategy: strategy,
      );
      await withClock(Clock.fixed(createdAt), () async {
        for (var i = 0; i < 2; i++) {
          await manager.putFile(
            'https://example.com/store-$i',
            [i],
            key: 'store-$i',
          );
        }
      });

      await withClock(
        Clock.fixed(createdAt.add(const Duration(seconds: 31))),
        () => manager.startCleanup(),
      );
      expect(strategy.calls, 0);

      await withClock(
        Clock.fixed(createdAt.add(const Duration(seconds: 32))),
        () async {
          await manager.putFile(
            'https://example.com/store-2',
            [2],
            key: 'store-2',
          );
          await manager.startCleanup();
        },
      );
      expect(await _existingCount(manager, 'store', 3), 2);
      expect(strategy.calls, 1);
      await manager.dispose();
    });

    test('dispose resets runtime cleanup before the manager is reused',
        () async {
      final dir = _temporaryDirectory('cleanup_dispose_reset_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 1,
      );

      await manager.startCleanup();
      await manager.dispose();

      await withClock(Clock.fixed(createdAt), () {
        return manager.putFile(
          'https://example.com/reused-old',
          [1],
          key: 'reused-old',
        );
      });
      await withClock(
        Clock.fixed(createdAt.add(const Duration(seconds: 31))),
        () => manager.putFile(
          'https://example.com/reused-new',
          [2],
          key: 'reused-new',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(await manager.getFileFromCache('reused-old'), isNotNull);
      expect(await manager.getFileFromCache('reused-new'), isNotNull);
      await manager.dispose();
    });

    test('capacity cleanup keeps the file returned by putFile', () async {
      final dir = _temporaryDirectory('cleanup_put_file_');
      final createdAt = DateTime.utc(2026, 1, 1);
      final manager = DefaultCacheManager(
        cacheDirectoryProvider: () async => dir,
        cleanupOnInitialize: false,
        maxNrOfCacheObjects: 1,
      );

      await withClock(Clock.fixed(createdAt), () {
        return manager.putFile(
          'https://example.com/old',
          [1],
          key: 'old',
          maxAge: const Duration(days: 1),
        );
      });
      await withClock(
        Clock.fixed(createdAt.add(const Duration(seconds: 31))),
        manager.startCleanup,
      );

      await withClock(
        Clock.fixed(createdAt.add(const Duration(seconds: 32))),
        () async {
          final file = await manager.putFile(
            'https://example.com/new',
            [2],
            key: 'new',
            maxAge: const Duration(minutes: 1),
          );
          await manager.startCleanup();
          expect(await file.readAsBytes(), [2]);
        },
      );

      expect(await manager.getFileFromCache('new'), isNotNull);
      expect(await manager.getFileFromCache('old'), isNull);
      await manager.dispose();
    });
  });

  group('CleanupCoordinator', () {
    test('active claims remain isolated across reset', () async {
      final coordinator = CleanupCoordinator(
        servedEntryGracePeriod: const Duration(milliseconds: 10),
        servedEntryPruneThreshold: 64,
      );
      final oldPathLease = await coordinator.beginPathUse('same-path');
      final oldStoreLease =
          await coordinator.beginStore('same-key', path: 'old-path');
      final oldEvictionLease = coordinator.beginEviction('evicted-key')!;
      final oldDeletionLease = coordinator.beginPathDeletion('deleted-path')!;

      coordinator.reset();
      var currentPathAcquired = false;
      final currentPathFuture = () async {
        final lease = await coordinator.beginPathUse('deleted-path');
        currentPathAcquired = true;
        return lease;
      }();
      var currentStoreAcquired = false;
      final currentStoreFuture = () async {
        final lease = await coordinator.beginStore('evicted-key');
        currentStoreAcquired = true;
        return lease;
      }();
      await Future<void>.delayed(Duration.zero);
      expect(currentPathAcquired, isFalse);
      expect(currentStoreAcquired, isFalse);

      oldDeletionLease();
      oldEvictionLease();
      final waitedPathLease = await currentPathFuture;
      final waitedStoreLease = await currentStoreFuture;
      final currentPathLease = await coordinator.beginPathUse('same-path');
      final currentStoreLease =
          await coordinator.beginStore('same-key', path: 'new-path');
      oldPathLease();
      oldStoreLease();

      expect(coordinator.beginPathDeletion('same-path'), isNull);
      expect(coordinator.isStoring('same-key', path: 'new-path'), isTrue);
      currentPathLease();
      currentStoreLease();
      final currentDeletionLease = coordinator.beginPathDeletion('same-path');
      expect(currentDeletionLease, isNotNull);
      currentDeletionLease!();
      waitedPathLease();
      waitedStoreLease();

      final currentEvictionLease = coordinator.beginEviction('evicted-key')!;
      oldEvictionLease();
      expect(coordinator.isEvicting('evicted-key'), isTrue);
      currentEvictionLease();
      final currentDeletedPathLease =
          coordinator.beginPathDeletion('deleted-path')!;
      oldDeletionLease();
      expect(coordinator.beginPathDeletion('deleted-path'), isNull);
      currentDeletedPathLease();
    });

    test('capacity retry fires once protection can expire', () async {
      final coordinator = CleanupCoordinator(
        servedEntryGracePeriod: const Duration(milliseconds: 10),
        servedEntryPruneThreshold: 64,
      )..capacityCleanupEnabled = true;
      final retried = Completer<void>();
      final now = DateTime.utc(2026, 1, 1);
      coordinator.markServed('key', now);
      coordinator.scheduleCapacityRetry(now, () async {
        if (!retried.isCompleted) retried.complete();
      });

      await retried.future.timeout(const Duration(seconds: 1));
      coordinator.reset();
    });
  });
}

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

Future<int> _existingCount(
  DefaultCacheManager manager,
  String prefix,
  int count,
) async {
  var existing = 0;
  for (var i = 0; i < count; i++) {
    if (await manager.getFileFromCache('$prefix-$i') != null) existing++;
  }
  return existing;
}

Future<void> _makeLegacy(
  io.Directory directory,
  String key,
  DateTime validTill,
) async {
  final hive = HiveImpl();
  final box = await hive.openBox<Map>(
    'cached_network_image_cache',
    path: '${directory.path}/cached_network_image_ce/hive',
  );
  final metadata = Map<String, dynamic>.from(box.get(key)!);
  metadata
    ..remove('touchedAt')
    ..['validTill'] = validTill.millisecondsSinceEpoch;
  await box.put(key, metadata);
  await box.close();
  await hive.close();
}
