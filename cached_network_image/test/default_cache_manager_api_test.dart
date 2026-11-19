import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cleanup API has the same conditional-export surface', () async {
    final manager = DefaultCacheManager(
      maxNrOfCacheObjects: 2,
      maxIdleDuration: const Duration(hours: 1),
      cleanupOnInitialize: false,
      cleanupStrategy: const LruCleanupStrategy(),
    );

    expect(manager.maxIdleDuration, const Duration(hours: 1));
    expect(manager.cleanupOnInitialize, isFalse);
    expect(manager.startCleanup, isA<Future<void> Function()>());

    await manager.dispose();
  });

  test('deferred cleanup trims real browser storage after replacement',
      () async {
    final manager = DefaultCacheManager(
      maxNrOfCacheObjects: 1,
      cleanupOnInitialize: false,
      cleanupStrategy: const LruCleanupStrategy(),
    );
    addTearDown(() async {
      try {
        await manager.emptyCache();
      } finally {
        await manager.dispose();
      }
    });
    final now = DateTime.utc(2026);
    await withClock(Clock.fixed(now), () async {
      await manager.putFile('https://example.com/old.png', [0], key: 'old');
    });
    await withClock(
      Clock.fixed(now.add(const Duration(seconds: 1))),
      () async {
        const url = 'https://example.com/replaced.png';
        await Future.wait([
          manager.putFile(url, [1], key: 'replacement'),
          manager.putFile(url, [2, 3], key: 'replacement'),
        ]);
        expect(await manager.getCacheSize(), 3);
      },
    );

    await withClock(
      Clock.fixed(now.add(const Duration(minutes: 1))),
      manager.startCleanup,
    );
    expect(await manager.getFileFromCache('old'), isNull);
    final replacement = await manager.getFileFromCache('replacement');
    expect(await replacement!.file.readAsBytes(), [2, 3]);
    expect(await manager.getCacheSize(), 2);
  }, skip: !kIsWeb);
}
