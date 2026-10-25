import 'package:cached_network_image_ce/cached_network_image.dart';
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
}
