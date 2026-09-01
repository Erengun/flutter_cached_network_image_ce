import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:file/memory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'fake_cache_manager.dart';
import 'image_data.dart';

void main() {
  const url = 'https://example.com/image.png';

  group('CachedNetworkImage.preCache', () {
    test('downloads and returns FileInfo via getFileStream', () async {
      final cacheManager = FakeCacheManager();
      cacheManager.returns(url, kTransparentImage);

      final result = await CachedNetworkImage.preCache(
        imageUrl: url,
        cacheManager: cacheManager,
      );

      expect(result, isA<FileInfo>());
      expect(result.originalUrl, url);
      verify(
        () => cacheManager.getFileStream(
          url,
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
        ),
      ).called(1);
    });

    test('passes cacheKey as key to getFileStream', () async {
      const cacheKey = 'custom-key';
      final cacheManager = FakeCacheManager();
      cacheManager.returns(url, kTransparentImage);

      await CachedNetworkImage.preCache(
        imageUrl: url,
        cacheKey: cacheKey,
        cacheManager: cacheManager,
      );

      verify(
        () => cacheManager.getFileStream(
          url,
          key: cacheKey,
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
        ),
      ).called(1);
    });

    test('passes headers to getFileStream', () async {
      final headers = {'Authorization': 'Bearer token'};
      final cacheManager = FakeCacheManager();
      cacheManager.returns(url, kTransparentImage);

      await CachedNetworkImage.preCache(
        imageUrl: url,
        headers: headers,
        cacheManager: cacheManager,
      );

      verify(
        () => cacheManager.getFileStream(
          url,
          key: any(named: 'key'),
          headers: headers,
          withProgress: any(named: 'withProgress'),
        ),
      ).called(1);
    });

    test('uses getImageFile when resize params provided', () async {
      final cacheManager = FakeImageCacheManager();
      cacheManager.returns(url, kTransparentImage);

      final result = await CachedNetworkImage.preCache(
        imageUrl: url,
        cacheManager: cacheManager,
        maxWidthDiskCache: 200,
        maxHeightDiskCache: 100,
      );

      expect(result, isA<FileInfo>());
      verify(
        () => cacheManager.getImageFile(
          url,
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
          maxWidth: 200,
          maxHeight: 100,
        ),
      ).called(1);
    });

    test('drains stream fully so stale cache is refreshed', () async {
      final staleFile =
          MemoryFileSystem().systemTempDirectory.childFile('stale.jpg');
      staleFile.writeAsBytesSync(kTransparentImage);
      final freshFile =
          MemoryFileSystem().systemTempDirectory.childFile('fresh.jpg');
      freshFile.writeAsBytesSync(kTransparentImage);

      final staleInfo = FileInfo(
        staleFile,
        FileSource.Cache,
        DateTime.now().subtract(const Duration(hours: 1)),
        url,
      );
      final freshInfo = FileInfo(
        freshFile,
        FileSource.Online,
        DateTime.now().add(const Duration(days: 7)),
        url,
      );

      final cacheManager = FakeCacheManager();
      when(
        () => cacheManager.getFileStream(
          url,
          key: any(named: 'key'),
          headers: any(named: 'headers'),
          withProgress: any(named: 'withProgress'),
        ),
      ).thenAnswer((_) => Stream.fromIterable([staleInfo, freshInfo]));

      final result = await CachedNetworkImage.preCache(
        imageUrl: url,
        cacheManager: cacheManager,
      );

      expect(result.source, FileSource.Online);
      expect(result.validTill.isAfter(DateTime.now()), isTrue);
    });

    test('propagates errors from cache manager', () async {
      final cacheManager = FakeCacheManager();
      cacheManager.throwsNotFound(url);

      expect(
        () => CachedNetworkImage.preCache(
          imageUrl: url,
          cacheManager: cacheManager,
        ),
        throwsA(isA<HttpExceptionWithStatus>()),
      );
    });
  });
}
