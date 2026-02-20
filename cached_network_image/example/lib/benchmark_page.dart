import 'dart:math';
import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart' as ce;
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart' as original;

class BenchmarkContent extends StatefulWidget {
  const BenchmarkContent({super.key});

  @override
  State<BenchmarkContent> createState() => _BenchmarkContentState();
}

class _BenchmarkContentState extends State<BenchmarkContent>
    with AutomaticKeepAliveClientMixin {
  final List<BenchmarkResult> _results = [];
  bool _running = false;
  String _status = 'Tap "Run Benchmark" to start';

  static const int _numEntries = 100;
  static const List<int> _fileSizes = [10240, 102400, 1048576];
  static const List<String> _fileSizeLabels = ['10 KB', '100 KB', '1 MB'];

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FilledButton.icon(
        onPressed: _running ? null : _runBenchmark,
        icon: _running
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.play_arrow),
        label: Text(_running ? 'Running...' : 'Run'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_status),
          if (_results.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final r = _results[index];
                  final speedup =
                      r.originalMs > 0 ? r.originalMs / r.ceMs : 0.0;
                  final speedupColor = speedup > 1 ? Colors.green : Colors.red;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                '${r.operation} · ${r.fileSize} · ×${r.count}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                              const Spacer(),
                              Text(
                                '${speedup.toStringAsFixed(2)}x',
                                style: TextStyle(
                                  color: speedupColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              _label('sqflite', '${r.originalMs} ms'),
                              const SizedBox(width: 16),
                              _label('hive_ce', '${r.ceMs} ms'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _label(String title, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$title: ',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        Text(value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Future<void> _runBenchmark() async {
    setState(() {
      _running = true;
      _results.clear();
      _status = 'Initializing...';
    });

    final originalManager = original.DefaultCacheManager();
    final ceManager = ce.DefaultCacheManager();

    try {
      for (var sizeIdx = 0; sizeIdx < _fileSizes.length; sizeIdx++) {
        final fileSize = _fileSizes[sizeIdx];
        final sizeLabel = _fileSizeLabels[sizeIdx];
        final testData = _generateTestData(fileSize);

        // ---- WRITE ----
        setState(
            () => _status = 'Writing $sizeLabel × $_numEntries (sqflite)...');
        await originalManager.emptyCache();

        final originalWriteSw = Stopwatch()..start();
        for (var i = 0; i < _numEntries; i++) {
          await originalManager.putFile(
            'https://example.com/original/$sizeIdx/$i.jpg',
            testData,
            key: 'original_${sizeIdx}_$i',
            fileExtension: 'jpg',
          );
        }
        originalWriteSw.stop();

        setState(
            () => _status = 'Writing $sizeLabel × $_numEntries (hive_ce)...');
        await ceManager.emptyCache();

        final ceWriteSw = Stopwatch()..start();
        for (var i = 0; i < _numEntries; i++) {
          await ceManager.putFile(
            'https://example.com/ce/$sizeIdx/$i.jpg',
            testData,
            key: 'ce_${sizeIdx}_$i',
            fileExtension: 'jpg',
          );
        }
        ceWriteSw.stop();

        _results.add(BenchmarkResult(
          operation: 'Write',
          fileSize: sizeLabel,
          count: _numEntries,
          originalMs: originalWriteSw.elapsedMilliseconds,
          ceMs: ceWriteSw.elapsedMilliseconds,
        ));
        setState(() {});

        // ---- READ ----
        setState(
            () => _status = 'Reading $sizeLabel × $_numEntries (sqflite)...');

        final originalReadSw = Stopwatch()..start();
        for (var i = 0; i < _numEntries; i++) {
          await originalManager.getFileFromCache('original_${sizeIdx}_$i');
        }
        originalReadSw.stop();

        setState(
            () => _status = 'Reading $sizeLabel × $_numEntries (hive_ce)...');

        final ceReadSw = Stopwatch()..start();
        for (var i = 0; i < _numEntries; i++) {
          await ceManager.getFileFromCache('ce_${sizeIdx}_$i');
        }
        ceReadSw.stop();

        _results.add(BenchmarkResult(
          operation: 'Read',
          fileSize: sizeLabel,
          count: _numEntries,
          originalMs: originalReadSw.elapsedMilliseconds,
          ceMs: ceReadSw.elapsedMilliseconds,
        ));
        setState(() {});

        // ---- DELETE ----
        setState(
            () => _status = 'Deleting $sizeLabel × $_numEntries (sqflite)...');

        final originalDeleteSw = Stopwatch()..start();
        for (var i = 0; i < _numEntries; i++) {
          await originalManager.removeFile('original_${sizeIdx}_$i');
        }
        originalDeleteSw.stop();

        setState(
            () => _status = 'Deleting $sizeLabel × $_numEntries (hive_ce)...');

        final ceDeleteSw = Stopwatch()..start();
        for (var i = 0; i < _numEntries; i++) {
          await ceManager.removeFile('ce_${sizeIdx}_$i');
        }
        ceDeleteSw.stop();

        _results.add(BenchmarkResult(
          operation: 'Delete',
          fileSize: sizeLabel,
          count: _numEntries,
          originalMs: originalDeleteSw.elapsedMilliseconds,
          ceMs: ceDeleteSw.elapsedMilliseconds,
        ));
        setState(() {});
      }

      // ---- EMPTY CACHE ----
      setState(() => _status = 'Benchmarking emptyCache (100 × 100 KB)...');
      final bulkData = _generateTestData(102400);

      for (var i = 0; i < _numEntries; i++) {
        await originalManager.putFile(
          'https://example.com/original/bulk/$i.jpg',
          bulkData,
          key: 'original_bulk_$i',
          fileExtension: 'jpg',
        );
        await ceManager.putFile(
          'https://example.com/ce/bulk/$i.jpg',
          bulkData,
          key: 'ce_bulk_$i',
          fileExtension: 'jpg',
        );
      }

      final originalEmptySw = Stopwatch()..start();
      await originalManager.emptyCache();
      originalEmptySw.stop();

      final ceEmptySw = Stopwatch()..start();
      await ceManager.emptyCache();
      ceEmptySw.stop();

      _results.add(BenchmarkResult(
        operation: 'Empty Cache',
        fileSize: '100 KB',
        count: _numEntries,
        originalMs: originalEmptySw.elapsedMilliseconds,
        ceMs: ceEmptySw.elapsedMilliseconds,
      ));

      setState(() {
        _running = false;
        _status = 'Benchmark complete! ✅';
      });
    } catch (e, st) {
      setState(() {
        _running = false;
        _status = 'Error: $e\n$st';
      });
    } finally {
      try {
        await originalManager.emptyCache();
        await ceManager.emptyCache();
        await ceManager.dispose();
      } catch (_) {}
    }
  }

  Uint8List _generateTestData(int size) {
    final rng = Random(42);
    return Uint8List.fromList(List.generate(size, (_) => rng.nextInt(256)));
  }
}

class BenchmarkResult {
  const BenchmarkResult({
    required this.operation,
    required this.fileSize,
    required this.count,
    required this.originalMs,
    required this.ceMs,
  });

  final String operation;
  final String fileSize;
  final int count;
  final int originalMs;
  final int ceMs;
}
