// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image_platform_interface_ce/cached_network_image_platform_interface_ce.dart';
import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageRenderMethodForWeb', () {
    test('enum values exist', () {
      expect(ImageRenderMethodForWeb.values.length, 2);
      expect(ImageRenderMethodForWeb.HtmlImage, isNotNull);
      expect(ImageRenderMethodForWeb.HttpGet, isNotNull);
    });
  });

  group('ImageLoader', () {
    test('Default loadImageAsync throws UnimplementedError', () {
      final imageLoader = ImageLoader();
      expect(
        () => imageLoader.loadImageAsync(
          'test.com/image',
          null,
          StreamController<ImageChunkEvent>(),
          decoder,
          MockCacheManager(),
          null,
          null,
          null,
          ImageRenderMethodForWeb.HttpGet,
          () => {},
        ),
        throwsA(const TypeMatcher<UnimplementedError>()),
      );
    });

    test('Default loadBufferAsync throws UnimplementedError', () {
      final imageLoader = ImageLoader();
      expect(
        () => imageLoader.loadBufferAsync(
          'test.com/image',
          null,
          StreamController<ImageChunkEvent>(),
          bufferDecoder,
          MockCacheManager(),
          null,
          null,
          null,
          ImageRenderMethodForWeb.HttpGet,
          () => {},
        ),
        throwsA(const TypeMatcher<UnimplementedError>()),
      );
    });
  });

  group('HttpExceptionWithStatus', () {
    test('constructor sets all properties', () {
      final uri = Uri.parse('https://example.com/image.png');
      final exception = HttpExceptionWithStatus(
        404,
        'Not Found',
        uri: uri,
      );

      expect(exception.statusCode, 404);
      expect(exception.message, 'Not Found');
      expect(exception.uri, uri);
    });

    test('toString includes message and status code', () {
      const exception = HttpExceptionWithStatus(
        500,
        'Internal Server Error',
      );

      final result = exception.toString();
      expect(result, contains('Internal Server Error'));
      expect(result, contains('500'));
    });

    test('toString includes uri when present', () {
      final uri = Uri.parse('https://example.com/image.png');
      final exception = HttpExceptionWithStatus(
        404,
        'Not Found',
        uri: uri,
      );

      final result = exception.toString();
      expect(result, contains('https://example.com/image.png'));
      expect(result, contains('404'));
    });

    test('toString without uri does not contain uri text', () {
      const exception = HttpExceptionWithStatus(
        404,
        'Not Found',
      );

      expect(exception.uri, isNull);
      final result = exception.toString();
      expect(result, contains('Not Found'));
      expect(result, contains('404'));
      expect(result, isNot(contains('uri =')));
    });
  });

  group('DownloadProgress', () {
    test('progress returns correct value', () {
      const progress = DownloadProgress('url', 100, 50);
      expect(progress.progress, 0.5);
      expect(progress.originalUrl, 'url');
      expect(progress.totalSize, 100);
      expect(progress.downloaded, 50);
    });

    test('progress returns null when totalSize is null', () {
      const progress = DownloadProgress('url', null, 50);
      expect(progress.progress, isNull);
    });

    test('progress returns null when downloaded exceeds totalSize', () {
      const progress = DownloadProgress('url', 100, 150);
      expect(progress.progress, isNull);
    });

    test('progress returns 0 when downloaded is 0', () {
      const progress = DownloadProgress('url', 100, 0);
      expect(progress.progress, 0.0);
    });

    test('progress returns 1 when fully downloaded', () {
      const progress = DownloadProgress('url', 100, 100);
      expect(progress.progress, 1.0);
    });
  });

  group('FileInfo', () {
    test('constructor with default statusCode', () {
      final file = MemoryFileSystem().file('/test.png');
      final validTill = DateTime.now().add(const Duration(days: 1));
      final info = FileInfo(
        file,
        FileSource.Online,
        validTill,
        'https://example.com/test.png',
      );

      expect(info.file, file);
      expect(info.source, FileSource.Online);
      expect(info.validTill, validTill);
      expect(info.originalUrl, 'https://example.com/test.png');
      expect(info.statusCode, 200);
    });

    test('constructor with custom statusCode', () {
      final file = MemoryFileSystem().file('/test.png');
      final validTill = DateTime.now().add(const Duration(days: 1));
      final info = FileInfo(
        file,
        FileSource.Cache,
        validTill,
        'https://example.com/test.png',
        statusCode: 202,
      );

      expect(info.statusCode, 202);
      expect(info.source, FileSource.Cache);
    });
  });

  group('FileSource', () {
    test('enum values exist', () {
      expect(FileSource.values.length, 3);
      expect(FileSource.NA, isNotNull);
      expect(FileSource.Cache, isNotNull);
      expect(FileSource.Online, isNotNull);
    });
  });

  group('CacheManagerLogLevel', () {
    test('enum values exist', () {
      expect(CacheManagerLogLevel.values.length, 4);
      expect(CacheManagerLogLevel.none, isNotNull);
      expect(CacheManagerLogLevel.warning, isNotNull);
      expect(CacheManagerLogLevel.debug, isNotNull);
      expect(CacheManagerLogLevel.verbose, isNotNull);
    });
  });

  group('CacheLogger', () {
    test('log records call when log level is sufficient', () {
      final oldLogLevel = CacheManager.logLevel;
      addTearDown(() => CacheManager.logLevel = oldLogLevel);
      CacheManager.logLevel = CacheManagerLogLevel.verbose;

      final logger = _TestCacheLogger();
      logger.log('Test message', CacheManagerLogLevel.verbose);

      expect(logger.calls, hasLength(1));
      expect(logger.calls.first.message, 'Test message');
      expect(logger.calls.first.level, CacheManagerLogLevel.verbose);
    });

    test('log does not record when log level is insufficient', () {
      final oldLogLevel = CacheManager.logLevel;
      addTearDown(() => CacheManager.logLevel = oldLogLevel);
      CacheManager.logLevel = CacheManagerLogLevel.none;

      final logger = _TestCacheLogger();
      logger.log('Test message', CacheManagerLogLevel.verbose);

      expect(logger.calls, isEmpty);
    });
  });

  group('CacheManager', () {
    test('logLevel static get/set works', () {
      final oldLevel = CacheManager.logLevel;
      addTearDown(() => CacheManager.logLevel = oldLevel);

      CacheManager.logLevel = CacheManagerLogLevel.debug;
      expect(CacheManager.logLevel, CacheManagerLogLevel.debug);

      CacheManager.logLevel = CacheManagerLogLevel.verbose;
      expect(CacheManager.logLevel, CacheManagerLogLevel.verbose);

      CacheManager.logLevel = CacheManagerLogLevel.warning;
      expect(CacheManager.logLevel, CacheManagerLogLevel.warning);

      CacheManager.logLevel = CacheManagerLogLevel.none;
      expect(CacheManager.logLevel, CacheManagerLogLevel.none);
    });
  });

  group('cacheLogger global instance', () {
    test('default cacheLogger is a CacheLogger', () {
      expect(cacheLogger, isA<CacheLogger>());
    });

    test('cacheLogger can be replaced', () {
      final original = cacheLogger;
      final custom = CacheLogger();
      cacheLogger = custom;
      expect(cacheLogger, same(custom));
      cacheLogger = original;
    });
  });
}

Future<ui.Codec> decoder(
  ui.ImmutableBuffer buffer, {
  ui.TargetImageSizeCallback? getTargetSize,
}) {
  throw UnimplementedError();
}

Future<ui.Codec> bufferDecoder(
  ui.ImmutableBuffer buffer, {
  bool allowUpscaling = false,
  int? cacheHeight,
  int? cacheWidth,
}) {
  throw UnimplementedError();
}

class MockCacheManager implements BaseCacheManager {
  @override
  Future<void> dispose() {
    throw UnimplementedError();
  }

  @override
  Future<void> emptyCache() {
    throw UnimplementedError();
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<File> putFile(
    String url,
    List<int> fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeFile(String key) {
    throw UnimplementedError();
  }
}

class _LogCall {
  _LogCall(this.message, this.level);
  final String message;
  final CacheManagerLogLevel level;
}

class _TestCacheLogger extends CacheLogger {
  final List<_LogCall> calls = [];

  @override
  void log(String message, CacheManagerLogLevel level) {
    if (CacheManager.logLevel.index >= level.index) {
      calls.add(_LogCall(message, level));
    }
  }
}
