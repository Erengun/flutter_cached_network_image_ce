// Copyright 2020 Rene Floor. All rights reserved.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:cached_network_image_ce/src/gif_frame_duration.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter_test/flutter_test.dart';

class FakeFrameInfo implements FrameInfo {
  const FakeFrameInfo(this._duration, this._image);

  final Duration _duration;
  final Image _image;

  @override
  Duration get duration => _duration;

  @override
  Image get image => _image;

  int get imageHandleCount => image.debugGetOpenHandleStackTraces()!.length;

  FakeFrameInfo clone() {
    return FakeFrameInfo(
      _duration,
      _image.clone(),
    );
  }
}

class MockCodec implements Codec {
  @override
  int frameCount = 1;

  @override
  int repetitionCount = 1;

  int numFramesAsked = 0;

  Completer<FrameInfo> _nextFrameCompleter = Completer<FrameInfo>();

  @override
  Future<FrameInfo> getNextFrame() {
    numFramesAsked += 1;
    return _nextFrameCompleter.future;
  }

  void completeNextFrame(FrameInfo frameInfo) {
    _nextFrameCompleter.complete(frameInfo);
    _nextFrameCompleter = Completer<FrameInfo>();
  }

  void failNextFrame(String err) {
    _nextFrameCompleter.completeError(err);
  }

  int numDisposals = 0;

  bool get disposed => numDisposals > 0;

  @override
  void dispose() {
    numDisposals += 1;
  }
}

class FakeEventReportingImageStreamCompleter extends ImageStreamCompleter {
  FakeEventReportingImageStreamCompleter({
    Stream<ImageChunkEvent>? chunkEvents,
  }) {
    if (chunkEvents != null) {
      chunkEvents.listen(
        (ImageChunkEvent event) {
          reportImageChunkEvent(event);
        },
      );
    }
  }
}

void main() {
  late Image image20x10;
  late Image image200x100;
  late Image image50x50;
  late Image image300x100;
  setUp(() async {
    image20x10 = await createTestImage(width: 20, height: 10);
    image200x100 = await createTestImage(width: 200, height: 100);
    image50x50 = await createTestImage(width: 50, height: 50);
    image300x100 = await createTestImage(width: 300, height: 100);
  });

  group('clampGifFrameDuration', () {
    test('clamps frame durations at or below 10ms', () {
      expect(
        clampGifFrameDuration(
          const Duration(milliseconds: 10),
          minimumGifFrameDuration: const Duration(milliseconds: 100),
        ),
        const Duration(milliseconds: 100),
      );

      expect(
        clampGifFrameDuration(
          const Duration(milliseconds: 5),
          minimumGifFrameDuration: const Duration(milliseconds: 80),
        ),
        const Duration(milliseconds: 80),
      );
    });

    test('keeps frame durations above 10ms unchanged', () {
      expect(
        clampGifFrameDuration(
          const Duration(milliseconds: 11),
          minimumGifFrameDuration: const Duration(milliseconds: 100),
        ),
        const Duration(milliseconds: 11),
      );
    });
  });

  testWidgets('Codec future fails', (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );
    codecStream.addError('failure message');
    await tester.idle();
    expect(tester.takeException(), 'failure message');
  });

  test('Completer unsubscribes to chunk events when disposed', () async {
    final codecStream = StreamController<Codec>();
    final chunkStream = StreamController<ImageChunkEvent>();

    final MultiImageStreamCompleter completer = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
      chunkEvents: chunkStream.stream,
    );

    expect(chunkStream.hasListener, true);

    chunkStream.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 1, expectedTotalBytes: 3),
    );

    final ImageStreamListener listener =
        ImageStreamListener((ImageInfo info, bool syncCall) {});
    // Cause the completer to dispose.
    completer.addListener(listener);
    completer.removeListener(listener);

    expect(chunkStream.hasListener, false);

    // The above expectation should cover this, but the point of this test is to
    // make sure the completer does not assert that it's disposed and still
    // receiving chunk events. Streams from the network can keep sending data
    // even after evicting an image from the cache, for example.
    chunkStream.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 2, expectedTotalBytes: 3),
    );
  });

  testWidgets('Decoding starts when a listener is added after codec is ready',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    codecStream.add(mockCodec);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 0);

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));
    await tester.idle();
    expect(mockCodec.numFramesAsked, 1);
  });

  testWidgets(
      'Single-frame codec is not re-decoded when a listener is re-added',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages = <ImageInfo>[];
    listener(ImageInfo image, bool synchronousCall) {
      emittedImages.add(image);
    }

    // Keep the completer alive across the gap without listeners, like the
    // ImageCache does for live images.
    final handle = imageStream.keepAlive();
    imageStream.addListener(ImageStreamListener(listener));

    codecStream.add(mockCodec);
    await tester.idle();

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    mockCodec.completeNextFrame(frame1);
    await tester.idle();
    await tester.pump();

    expect(mockCodec.numFramesAsked, 1);
    expect(emittedImages.single.image.isCloneOf(frame1.image), true);

    imageStream.removeListener(ImageStreamListener(listener));
    imageStream.addListener(ImageStreamListener(listener));
    await tester.idle();

    // The already decoded frame is handed to the new listener; the codec must
    // not be asked for another frame. Re-decoding a single-frame codec renders
    // black on the web (CanvasKit lazy images share one <img> element).
    expect(mockCodec.numFramesAsked, 1);
    expect(emittedImages.length, 2);
    expect(emittedImages.last.image.isCloneOf(frame1.image), true);

    imageStream.removeListener(ImageStreamListener(listener));
    handle.dispose();
  });

  testWidgets(
      'A codec arriving while unlistened is decoded when a listener returns',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    firstCodec.frameCount = 1;
    final secondCodec = MockCodec();
    secondCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}

    final handle = imageStream.keepAlive();
    imageStream.addListener(ImageStreamListener(listener));

    codecStream.add(firstCodec);
    await tester.idle();
    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
    );
    await tester.idle();
    await tester.pump();
    expect(firstCodec.numFramesAsked, 1);

    imageStream.removeListener(ImageStreamListener(listener));

    // A fresh codec (cache hit followed by a network refresh) arrives while
    // nothing is listening, so it cannot be decoded yet.
    codecStream.add(secondCodec);
    await tester.idle();
    expect(secondCodec.numFramesAsked, 0);

    imageStream.addListener(ImageStreamListener(listener));
    await tester.idle();
    expect(secondCodec.numFramesAsked, 1);

    imageStream.removeListener(ImageStreamListener(listener));
    handle.dispose();
  });

  testWidgets('Decoding starts when a codec is ready after a listener is added',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));
    await tester.idle();
    expect(mockCodec.numFramesAsked, 0);

    codecStream.add(mockCodec);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 1);
  });

  testWidgets('Adding a second codec triggers start decoding',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    final secondCodec = MockCodec();
    firstCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));
    await tester.idle();
    expect(firstCodec.numFramesAsked, 0);

    codecStream.add(firstCodec);
    await tester.idle();
    expect(firstCodec.numFramesAsked, 1);

    expect(secondCodec.numFramesAsked, 0);

    codecStream.add(secondCodec);
    await tester.idle();
    expect(secondCodec.numFramesAsked, 1);
  });

  testWidgets('An abandoned frame is disposed when the next decode starts',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    final streamListener = ImageStreamListener(listener);
    final handle = imageStream.keepAlive();
    imageStream.addListener(streamListener);
    codecStream.add(mockCodec);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 1);

    // The listener drops while the frame is still decoding, so the frame
    // arrives with nothing to emit it to and is retained.
    imageStream.removeListener(streamListener);
    final frame = FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    mockCodec.completeNextFrame(frame);
    await tester.idle();
    expect(frame.image.debugDisposed, false);

    // A fresh decode must release the abandoned frame instead of leaking it.
    imageStream.addListener(streamListener);
    await tester.idle();
    expect(frame.image.debugDisposed, true);

    imageStream.removeListener(streamListener);
    handle.dispose();
  });

  testWidgets('A frame decoded by a superseded codec is not emitted',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    firstCodec.frameCount = 3;
    final secondCodec = MockCodec();
    secondCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages = <ImageInfo>[];
    imageStream.addListener(
      ImageStreamListener((ImageInfo image, bool synchronousCall) {
        emittedImages.add(image);
      }),
    );

    codecStream.add(firstCodec);
    await tester.idle();
    expect(firstCodec.numFramesAsked, 1);

    // No timer is pending between app frames, so the refreshed codec replaces
    // the first one while the first one still has a decode in flight.
    codecStream.add(secondCodec);
    await tester.idle();
    expect(secondCodec.numFramesAsked, 1);

    final staleFrame =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    firstCodec.completeNextFrame(staleFrame);
    await tester.idle();
    await tester.pump();

    expect(emittedImages, isEmpty);
    expect(staleFrame.image.debugDisposed, true);
  });

  testWidgets('Re-adding a listener mid-decode does not start a second decode',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages = <ImageInfo>[];
    listener(ImageInfo image, bool synchronousCall) {
      emittedImages.add(image);
    }

    final streamListener = ImageStreamListener(listener);
    final handle = imageStream.keepAlive();
    imageStream.addListener(streamListener);
    codecStream.add(mockCodec);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 1);

    // Scrolling the widget out of and back into view while the decode is still
    // in flight must not race a second decode against the first: two frames
    // emitted from one codec dispose each other's backing image on the web.
    imageStream.removeListener(streamListener);
    imageStream.addListener(streamListener);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 1);

    mockCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
    );
    await tester.idle();
    await tester.pump();
    expect(emittedImages, hasLength(1));

    imageStream.removeListener(streamListener);
    handle.dispose();
  });

  testWidgets('A scheduled frame callback survives its frame being replaced',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    firstCodec.frameCount = 3;
    firstCodec.repetitionCount = -1;
    final secondCodec = MockCodec();
    secondCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    imageStream.addListener(
      ImageStreamListener((ImageInfo image, bool synchronousCall) {}),
    );

    codecStream.add(firstCodec);
    await tester.idle();
    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
    );
    await tester.idle();
    await tester.pump(); // first frame shows immediately, next decode starts

    // The second frame is decoded and an app frame callback is scheduled for
    // it, but a replacement codec arrives before that callback runs.
    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image200x100),
    );
    await tester.idle();
    codecStream.add(secondCodec);
    await tester.idle();

    // The queued callback must not dereference the frame that was released.
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);

    secondCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image300x100),
    );
    await tester.idle();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'A listener that re-adds itself during emission does not break '
      'the frame in flight', (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final mockCodec = MockCodec();
    mockCodec.frameCount = 3;
    mockCodec.repetitionCount = -1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final handle = imageStream.keepAlive();
    final emittedImages = <ImageInfo>[];
    var reentered = false;
    late ImageStreamListener streamListener;
    streamListener = ImageStreamListener(
      (ImageInfo image, bool synchronousCall) {
        emittedImages.add(image);
        if (reentered) return;
        reentered = true;
        // Mirrors a widget that is recycled from the image callback itself.
        imageStream.removeListener(streamListener);
        imageStream.addListener(streamListener);
      },
    );
    imageStream.addListener(streamListener);

    codecStream.add(mockCodec);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 1);

    final frame = FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    mockCodec.completeNextFrame(frame);
    await tester.idle();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(reentered, true);
    // Once from `setImage`, once from the replay that `addListener` gives a
    // listener added while an image is already available.
    expect(emittedImages, hasLength(2));
    // The re-add starts the decode; the emitting callback must not start a
    // second one on top of it.
    expect(mockCodec.numFramesAsked, 2);

    imageStream.removeListener(streamListener);
    handle.dispose();
  });

  testWidgets(
      'A superseded codec finishing does not unblock a decode on the current '
      'codec', (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    firstCodec.frameCount = 3;
    final secondCodec = MockCodec();
    secondCodec.frameCount = 3;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    final streamListener = ImageStreamListener(listener);
    final handle = imageStream.keepAlive();
    imageStream.addListener(streamListener);

    codecStream.add(firstCodec);
    await tester.idle();
    expect(firstCodec.numFramesAsked, 1);

    codecStream.add(secondCodec);
    await tester.idle();
    expect(secondCodec.numFramesAsked, 1);

    // The superseded codec finishes first. Its decode is not the current
    // codec's, so it must not make the current codec look idle.
    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
    );
    await tester.idle();

    imageStream.removeListener(streamListener);
    imageStream.addListener(streamListener);
    await tester.idle();
    expect(secondCodec.numFramesAsked, 1);

    imageStream.removeListener(streamListener);
    handle.dispose();
  });

  testWidgets('A replaced codec is disposed exactly once',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    firstCodec.frameCount = 1;
    final secondCodec = MockCodec();
    secondCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    final streamListener = ImageStreamListener(listener);
    final handle = imageStream.keepAlive();
    imageStream.addListener(streamListener);

    codecStream.add(firstCodec);
    await tester.idle();
    expect(firstCodec.numFramesAsked, 1);

    // Replaced while its decode is in flight: disposing it now would fail that
    // decode, so it is deferred to the decode itself.
    codecStream.add(secondCodec);
    await tester.idle();
    expect(firstCodec.numDisposals, 0);

    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
    );
    await tester.idle();
    expect(firstCodec.numDisposals, 1);
    expect(secondCodec.numDisposals, 0);

    imageStream.removeListener(streamListener);
    handle.dispose();
  });

  testWidgets('An idle codec is disposed when it is replaced',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    firstCodec.frameCount = 1;
    final secondCodec = MockCodec();
    secondCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    final streamListener = ImageStreamListener(listener);
    final handle = imageStream.keepAlive();
    imageStream.addListener(streamListener);

    codecStream.add(firstCodec);
    await tester.idle();
    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
    );
    await tester.idle();
    await tester.pump();
    expect(firstCodec.numDisposals, 0);

    codecStream.add(secondCodec);
    await tester.idle();
    expect(firstCodec.numDisposals, 1);
    expect(secondCodec.numDisposals, 0);

    imageStream.removeListener(streamListener);
    handle.dispose();
  });

  testWidgets('A buffered codec that is replaced before use is disposed',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final firstCodec = MockCodec();
    firstCodec.frameCount = 2;
    firstCodec.repetitionCount = -1;
    final secondCodec = MockCodec();
    final thirdCodec = MockCodec();
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    imageStream.addListener(
      ImageStreamListener((ImageInfo image, bool synchronousCall) {}),
    );

    codecStream.add(firstCodec);
    await tester.idle();
    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
    );
    await tester.idle();
    await tester.pump(); // first frame shows immediately
    firstCodec.completeNextFrame(
      FakeFrameInfo(const Duration(milliseconds: 200), image200x100),
    );
    await tester.idle();
    await tester.pump(); // frame duration has not passed: a timer is pending

    // With a timer pending, arriving codecs are buffered rather than installed.
    codecStream.add(secondCodec);
    await tester.idle();
    expect(secondCodec.disposed, false);

    codecStream.add(thirdCodec);
    await tester.idle();
    expect(secondCodec.disposed, true);

    // Drain the pending animation timer so the test ends cleanly.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.idle();
  });

  testWidgets('Decoding does not crash when disposed',
      (WidgetTester tester) async {
    final codecStream = StreamController<Codec>();
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    codecStream.add(mockCodec);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 0);

    listener(ImageInfo image, bool synchronousCall) {}
    final streamListener = ImageStreamListener(listener);
    imageStream.addListener(streamListener);
    await tester.idle();
    expect(mockCodec.numFramesAsked, 1);

    final FrameInfo frame =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    mockCodec.completeNextFrame(frame);
    imageStream.removeListener(streamListener);
    await tester.idle();
  });

  testWidgets('Chunk events of base ImageStreamCompleter are delivered',
      (WidgetTester tester) async {
    final chunkEvents = <ImageChunkEvent>[];
    final streamController = StreamController<ImageChunkEvent>();
    final ImageStreamCompleter imageStream =
        FakeEventReportingImageStreamCompleter(
      chunkEvents: streamController.stream,
    );

    imageStream.addListener(
      ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {},
        onChunk: (ImageChunkEvent event) {
          chunkEvents.add(event);
        },
      ),
    );
    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 1, expectedTotalBytes: 3),
    );
    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 2, expectedTotalBytes: 3),
    );
    await tester.idle();

    expect(chunkEvents.length, 2);
    expect(chunkEvents[0].cumulativeBytesLoaded, 1);
    expect(chunkEvents[0].expectedTotalBytes, 3);
    expect(chunkEvents[1].cumulativeBytesLoaded, 2);
    expect(chunkEvents[1].expectedTotalBytes, 3);
  });

  testWidgets(
      'Chunk events of base ImageStreamCompleter are not buffered before listener registration',
      (WidgetTester tester) async {
    final chunkEvents = <ImageChunkEvent>[];
    final streamController = StreamController<ImageChunkEvent>();
    final ImageStreamCompleter imageStream =
        FakeEventReportingImageStreamCompleter(
      chunkEvents: streamController.stream,
    );

    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 1, expectedTotalBytes: 3),
    );
    await tester.idle();
    imageStream.addListener(
      ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {},
        onChunk: (ImageChunkEvent event) {
          chunkEvents.add(event);
        },
      ),
    );
    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 2, expectedTotalBytes: 3),
    );
    await tester.idle();

    expect(chunkEvents.length, 1);
    expect(chunkEvents[0].cumulativeBytesLoaded, 2);
    expect(chunkEvents[0].expectedTotalBytes, 3);
  });

  testWidgets('Chunk events of MultiImageStreamCompleter are delivered',
      (WidgetTester tester) async {
    final chunkEvents = <ImageChunkEvent>[];
    final codecStream = StreamController<Codec>();
    final streamController = StreamController<ImageChunkEvent>();
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      chunkEvents: streamController.stream,
      scale: 1.0,
    );

    imageStream.addListener(
      ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {},
        onChunk: (ImageChunkEvent event) {
          chunkEvents.add(event);
        },
      ),
    );
    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 1, expectedTotalBytes: 3),
    );
    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 2, expectedTotalBytes: 3),
    );
    await tester.idle();

    expect(chunkEvents.length, 2);
    expect(chunkEvents[0].cumulativeBytesLoaded, 1);
    expect(chunkEvents[0].expectedTotalBytes, 3);
    expect(chunkEvents[1].cumulativeBytesLoaded, 2);
    expect(chunkEvents[1].expectedTotalBytes, 3);
  });

  testWidgets(
      'Chunk events of MultiImageStreamCompleter are not buffered before listener registration',
      (WidgetTester tester) async {
    final chunkEvents = <ImageChunkEvent>[];
    final codecStream = StreamController<Codec>();
    final streamController = StreamController<ImageChunkEvent>();
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      chunkEvents: streamController.stream,
      scale: 1.0,
    );

    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 1, expectedTotalBytes: 3),
    );
    await tester.idle();
    imageStream.addListener(
      ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {},
        onChunk: (ImageChunkEvent event) {
          chunkEvents.add(event);
        },
      ),
    );
    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 2, expectedTotalBytes: 3),
    );
    await tester.idle();

    expect(chunkEvents.length, 1);
    expect(chunkEvents[0].cumulativeBytesLoaded, 2);
    expect(chunkEvents[0].expectedTotalBytes, 3);
  });

  testWidgets('Chunk errors are reported', (WidgetTester tester) async {
    final chunkEvents = <ImageChunkEvent>[];
    final codecStream = StreamController<Codec>();
    final streamController = StreamController<ImageChunkEvent>();
    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      chunkEvents: streamController.stream,
      scale: 1.0,
    );

    imageStream.addListener(
      ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {},
        onChunk: (ImageChunkEvent event) {
          chunkEvents.add(event);
        },
      ),
    );
    streamController.addError(Error());
    streamController.add(
      const ImageChunkEvent(cumulativeBytesLoaded: 2, expectedTotalBytes: 3),
    );
    await tester.idle();

    expect(tester.takeException(), isNotNull);
    expect(chunkEvents.length, 1);
    expect(chunkEvents[0].cumulativeBytesLoaded, 2);
    expect(chunkEvents[0].expectedTotalBytes, 3);
  });

  testWidgets('getNextFrame future fails', (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));
    codecStream.add(mockCodec);
    // MultiImageStreamCompleter only sets an error handler for the next
    // frame future after the codec future has completed.
    // Idling here lets the MultiImageStreamCompleter advance and set the
    // error handler for the nextFrame future.
    await tester.idle();

    mockCodec.failNextFrame('frame completion error');
    await tester.idle();

    expect(tester.takeException(), 'frame completion error');
  });

  testWidgets('ImageStream emits frame (static image)',
      (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages = <ImageInfo>[];
    imageStream.addListener(
      ImageStreamListener((ImageInfo image, bool synchronousCall) {
        emittedImages.add(image);
      }),
    );

    codecStream.add(mockCodec);
    await tester.idle();

    final FrameInfo frame =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    mockCodec.completeNextFrame(frame);
    await tester.idle();

    expect(
      emittedImages
          .every((ImageInfo info) => info.image.isCloneOf(frame.image)),
      true,
    );
  });

  testWidgets('ImageStream emits frames (animated images)',
      (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 2;
    mockCodec.repetitionCount = -1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages = <ImageInfo>[];
    imageStream.addListener(
      ImageStreamListener((ImageInfo image, bool synchronousCall) {
        emittedImages.add(image);
      }),
    );

    codecStream.add(mockCodec);
    await tester.idle();

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    mockCodec.completeNextFrame(frame1);
    await tester.idle();
    // We are waiting for the next animation tick, so at this point no frames
    // should have been emitted.
    expect(emittedImages.length, 0);

    await tester.pump();
    expect(emittedImages.single.image.isCloneOf(frame1.image), true);

    final FrameInfo frame2 =
        FakeFrameInfo(const Duration(milliseconds: 400), image200x100);
    mockCodec.completeNextFrame(frame2);

    await tester.pump(const Duration(milliseconds: 100));
    // The duration for the current frame was 200ms, so we don't emit the next
    // frame yet even though it is ready.
    expect(emittedImages.length, 1);

    await tester.pump(const Duration(milliseconds: 100));
    expect(emittedImages[0].image.isCloneOf(frame1.image), true);
    expect(emittedImages[1].image.isCloneOf(frame2.image), true);

    // Let the pending timer for the next frame to complete so we can cleanly
    // quit the test without pending timers.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets(
    'short GIF frame durations are clamped to minimumGifFrameDuration',
    (WidgetTester tester) async {
      final mockCodec = MockCodec()
        ..frameCount = 2
        ..repetitionCount = -1;

      final codecStream = StreamController<Codec>();

      final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
        codec: codecStream.stream,
        scale: 1.0,
        minimumGifFrameDuration: const Duration(milliseconds: 100),
      );

      final emittedImages = <ImageInfo>[];
      imageStream.addListener(
        ImageStreamListener((ImageInfo image, bool synchronousCall) {
          emittedImages.add(image);
        }),
      );

      codecStream.add(mockCodec);
      await tester.idle();

      final FrameInfo frame1 =
          FakeFrameInfo(const Duration(milliseconds: 10), image20x10);
      mockCodec.completeNextFrame(frame1);
      await tester.idle();
      await tester.pump();

      expect(emittedImages.length, 1);
      expect(emittedImages.single.image.isCloneOf(frame1.image), true);

      final FrameInfo frame2 =
          FakeFrameInfo(const Duration(milliseconds: 200), image200x100);
      mockCodec.completeNextFrame(frame2);
      await tester.idle();

      // The first frame duration is 10ms, but it should be clamped to 100ms.
      await tester.pump(const Duration(milliseconds: 99));
      expect(emittedImages.length, 1);

      await tester.pump(const Duration(milliseconds: 1));
      expect(emittedImages.length, 2);
      expect(emittedImages[1].image.isCloneOf(frame2.image), true);

      await tester.pump(const Duration(milliseconds: 200));
    },
  );

  testWidgets('animation wraps back', (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 2;
    mockCodec.repetitionCount = -1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages = <ImageInfo>[];
    imageStream.addListener(
      ImageStreamListener((ImageInfo image, bool synchronousCall) {
        emittedImages.add(image);
      }),
    );

    codecStream.add(mockCodec);
    await tester.idle();

    final frame1 = FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    final frame2 =
        FakeFrameInfo(const Duration(milliseconds: 400), image200x100);

    mockCodec.completeNextFrame(frame1.clone());
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // first animation frame shows on first app frame.
    mockCodec.completeNextFrame(frame2.clone());
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(const Duration(milliseconds: 200)); // emit 2nd frame.
    mockCodec.completeNextFrame(frame1.clone());
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(const Duration(milliseconds: 400)); // emit 3rd frame

    expect(emittedImages[0].image.isCloneOf(frame1.image), true);
    expect(emittedImages[1].image.isCloneOf(frame2.image), true);
    expect(emittedImages[2].image.isCloneOf(frame1.image), true);

    // Let the pending timer for the next frame to complete so we can cleanly
    // quit the test without pending timers.
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('animation doesnt repeat more than specified',
      (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 2;
    mockCodec.repetitionCount = 0;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages = <ImageInfo>[];
    imageStream.addListener(
      ImageStreamListener((ImageInfo image, bool synchronousCall) {
        emittedImages.add(image);
      }),
    );

    codecStream.add(mockCodec);
    await tester.idle();

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    final FrameInfo frame2 =
        FakeFrameInfo(const Duration(milliseconds: 400), image200x100);

    mockCodec.completeNextFrame(frame1);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // first animation frame shows on first app frame.
    mockCodec.completeNextFrame(frame2);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(const Duration(milliseconds: 200)); // emit 2nd frame.
    mockCodec.completeNextFrame(frame1);
    // allow another frame to complete (but we shouldn't be asking for it as
    // this animation should not repeat.
    await tester.idle();
    await tester.pump(const Duration(milliseconds: 400));

    expect(emittedImages[0].image.isCloneOf(frame1.image), true);
    expect(emittedImages[1].image.isCloneOf(frame2.image), true);
  });

  testWidgets('frames are only decoded when there are listeners',
      (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 2;
    mockCodec.repetitionCount = -1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));
    final handle = imageStream.keepAlive();

    codecStream.add(mockCodec);
    await tester.idle();

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    final FrameInfo frame2 =
        FakeFrameInfo(const Duration(milliseconds: 400), image200x100);

    mockCodec.completeNextFrame(frame1);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // first animation frame shows on first app frame.
    mockCodec.completeNextFrame(frame2);
    imageStream.removeListener(ImageStreamListener(listener));
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(const Duration(milliseconds: 400)); // emit 2nd frame.

    // Decoding of the 3rd frame should not start as there are no registered
    // listeners to the stream
    expect(mockCodec.numFramesAsked, 2);

    imageStream.addListener(ImageStreamListener(listener));
    await tester.idle(); // let nextFrameFuture complete
    expect(mockCodec.numFramesAsked, 3);

    handle.dispose();
  });

  testWidgets('multiple stream listeners', (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 2;
    mockCodec.repetitionCount = -1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    final emittedImages1 = <ImageInfo>[];
    listener1(ImageInfo image, bool synchronousCall) {
      emittedImages1.add(image);
    }

    final emittedImages2 = <ImageInfo>[];
    listener2(ImageInfo image, bool synchronousCall) {
      emittedImages2.add(image);
    }

    imageStream.addListener(ImageStreamListener(listener1));
    imageStream.addListener(ImageStreamListener(listener2));

    codecStream.add(mockCodec);
    await tester.idle();

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    final FrameInfo frame2 =
        FakeFrameInfo(const Duration(milliseconds: 400), image200x100);

    mockCodec.completeNextFrame(frame1);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // first animation frame shows on first app frame.

    expect(emittedImages1.single.image.isCloneOf(frame1.image), true);
    expect(emittedImages2.single.image.isCloneOf(frame1.image), true);

    mockCodec.completeNextFrame(frame2);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // next app frame will schedule a timer.
    imageStream.removeListener(ImageStreamListener(listener1));

    await tester.pump(const Duration(milliseconds: 400)); // emit 2nd frame.
    expect(emittedImages1.single.image.isCloneOf(frame1.image), true);
    expect(emittedImages2[0].image.isCloneOf(frame1.image), true);
    expect(emittedImages2[1].image.isCloneOf(frame2.image), true);
  });

  testWidgets('timer is canceled when listeners are removed',
      (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 2;
    mockCodec.repetitionCount = -1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));

    codecStream.add(mockCodec);
    await tester.idle();

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    final FrameInfo frame2 =
        FakeFrameInfo(const Duration(milliseconds: 400), image200x100);

    mockCodec.completeNextFrame(frame1);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // first animation frame shows on first app frame.

    mockCodec.completeNextFrame(frame2);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump();

    imageStream.removeListener(ImageStreamListener(listener));
    // The test framework will fail this if there are pending timers at this
    // point.
  });

  testWidgets('error handlers can intercept errors',
      (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter streamUnderTest = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    Object? capturedException;
    errorListener(Object exception, StackTrace? stackTrace) {
      capturedException = exception;
    }

    streamUnderTest.addListener(
      ImageStreamListener(
        (ImageInfo image, bool synchronousCall) {},
        onError: errorListener,
      ),
    );

    codecStream.add(mockCodec);
    // MultiImageStreamCompleter only sets an error handler for the next
    // frame future after the codec future has completed.
    // Idling here lets the MultiImageStreamCompleter advance and set the
    // error handler for the nextFrame future.
    await tester.idle();

    mockCodec.failNextFrame('frame completion error');
    await tester.idle();

    // No exception is passed up.
    expect(tester.takeException(), isNull);
    expect(capturedException, 'frame completion error');
  });

  testWidgets('remove and add listener ', (WidgetTester tester) async {
    final mockCodec = MockCodec();
    mockCodec.frameCount = 3;
    mockCodec.repetitionCount = 0;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));

    codecStream.add(mockCodec);

    await tester.idle(); // let nextFrameFuture complete

    imageStream.addListener(ImageStreamListener(listener));
    imageStream.removeListener(ImageStreamListener(listener));

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);

    mockCodec.completeNextFrame(frame1);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // first animation frame shows on first app frame.

    await tester.pump(const Duration(milliseconds: 200)); // emit 2nd frame.
  });

  testWidgets(
      'Keep alive handles do not drive frames or prevent last listener callbacks',
      (WidgetTester tester) async {
    final image10x10 =
        (await tester.runAsync(() => createTestImage(width: 10, height: 10)));
    final mockCodec = MockCodec();
    mockCodec.frameCount = 2;
    mockCodec.repetitionCount = -1;
    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    var onImageCount = 0;
    activeListener(ImageInfo image, bool synchronousCall) {
      onImageCount += 1;
    }

    var lastListenerDropped = false;
    imageStream.addOnLastListenerRemovedCallback(() {
      lastListenerDropped = true;
    });

    expect(lastListenerDropped, false);
    final handle = imageStream.keepAlive();
    expect(lastListenerDropped, false);
    SchedulerBinding.instance
        .debugAssertNoTransientCallbacks('Only passive listeners');

    codecStream.add(mockCodec);
    await tester.idle();

    expect(onImageCount, 0);

    final frame1 = FakeFrameInfo(Duration.zero, image20x10);
    mockCodec.completeNextFrame(frame1);
    await tester.idle();
    SchedulerBinding.instance
        .debugAssertNoTransientCallbacks('Only passive listeners');
    await tester.pump();
    expect(onImageCount, 0);

    imageStream.addListener(ImageStreamListener(activeListener));

    final frame2 = FakeFrameInfo(Duration.zero, image10x10!);
    mockCodec.completeNextFrame(frame2);
    await tester.idle();
    expect(SchedulerBinding.instance.transientCallbackCount, 1);
    await tester.pump();

    expect(onImageCount, 1);

    imageStream.removeListener(ImageStreamListener(activeListener));
    expect(lastListenerDropped, true);

    mockCodec.completeNextFrame(frame1);
    await tester.idle();
    expect(SchedulerBinding.instance.transientCallbackCount, 1);
    await tester.pump();

    expect(onImageCount, 1);

    SchedulerBinding.instance
        .debugAssertNoTransientCallbacks('Only passive listeners');

    mockCodec.completeNextFrame(frame2);
    await tester.idle();
    SchedulerBinding.instance
        .debugAssertNoTransientCallbacks('Only passive listeners');
    await tester.pump();

    expect(onImageCount, 1);

    handle.dispose();
  });

  testWidgets('Multi-frame image is completed before next image is shown',
      (WidgetTester tester) async {
    final firstCodec = MockCodec();
    firstCodec.frameCount = 3;
    firstCodec.repetitionCount = -1;
    final secondCodec = MockCodec();

    final codecStream = StreamController<Codec>();

    final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
      codec: codecStream.stream,
      scale: 1.0,
    );

    listener(ImageInfo image, bool synchronousCall) {}
    imageStream.addListener(ImageStreamListener(listener));

    codecStream.add(firstCodec);
    await tester.idle();

    final FrameInfo frame1 =
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
    final FrameInfo frame2 =
        FakeFrameInfo(const Duration(milliseconds: 400), image200x100);
    final FrameInfo frame3 =
        FakeFrameInfo(const Duration(milliseconds: 200), image300x100);

    firstCodec.completeNextFrame(frame1);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(); // first animation frame shows on first app frame.

    firstCodec.completeNextFrame(frame2);
    await tester.idle(); // let nextFrameFuture complete
    await tester.pump(const Duration(milliseconds: 100)); // second frame is
    // not yet shown, but ready.

    codecStream.add(secondCodec);
    await tester.idle(); // let nextFrameFuture complete

    await tester.pump(const Duration(milliseconds: 300)); // emit 2nd frame.
    firstCodec.completeNextFrame(frame3);
    await tester.idle(); // let nextFrameFuture complete
    expect(secondCodec.numFramesAsked, 0);
    await tester.pump(const Duration(milliseconds: 200)); // emit 3rd frame.
    await tester.idle();

    // emit 1st frame 2nd image
    await tester.pump(const Duration(milliseconds: 200));

    // Decoding of the 3rd frame should not start as we switched images
    expect(firstCodec.numFramesAsked, 3);
    expect(secondCodec.numFramesAsked, 1);
  });

  testWidgets(
    'animate: false emits only the first frame of an animated image',
    (WidgetTester tester) async {
      final mockCodec = MockCodec()
        ..frameCount = 3
        ..repetitionCount = -1;
      final codecStream = StreamController<Codec>();

      final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
        codec: codecStream.stream,
        scale: 1.0,
        animate: false,
      );

      final emittedImages = <ImageInfo>[];
      imageStream.addListener(
        ImageStreamListener((ImageInfo image, bool synchronousCall) {
          emittedImages.add(image);
        }),
      );

      codecStream.add(mockCodec);
      await tester.idle();

      final FrameInfo frame1 =
          FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
      mockCodec.completeNextFrame(frame1);
      await tester.idle();

      await tester.pump();
      expect(emittedImages.single.image.isCloneOf(frame1.image), true);
      expect(mockCodec.numFramesAsked, 1);

      // No further frames are decoded or emitted, and no timer is left behind.
      await tester.pump(const Duration(milliseconds: 400));
      expect(emittedImages.length, 1);
      expect(mockCodec.numFramesAsked, 1);
    },
  );

  testWidgets(
    'animate: false keeps its decoded frame across a listener re-add',
    (WidgetTester tester) async {
      final mockCodec = MockCodec()
        ..frameCount = 3
        ..repetitionCount = -1;
      final codecStream = StreamController<Codec>();

      final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
        codec: codecStream.stream,
        scale: 1.0,
        animate: false,
      );
      // The ImageCache holds a handle for every live entry, so the completer
      // survives its last listener leaving.
      final handle = imageStream.keepAlive();

      final emittedImages = <ImageInfo>[];
      final listener = ImageStreamListener(
        (ImageInfo image, bool synchronousCall) => emittedImages.add(image),
      );
      imageStream.addListener(listener);

      codecStream.add(mockCodec);
      await tester.idle();

      final FrameInfo frame1 =
          FakeFrameInfo(const Duration(milliseconds: 200), image20x10);
      mockCodec.completeNextFrame(frame1);
      await tester.idle();

      // The listener leaves before the scheduled app frame runs, as happens
      // when the image scrolls off screen while it is still loading.
      imageStream.removeListener(listener);
      await tester.pump();
      expect(emittedImages, isEmpty);

      imageStream.addListener(listener);
      await tester.pump();

      // The frame already in hand is shown; the codec is not advanced.
      expect(mockCodec.numFramesAsked, 1);
      expect(emittedImages.single.image.isCloneOf(frame1.image), true);

      handle.dispose();
    },
  );

  testWidgets(
    'animate: false shows a replacement codec without waiting',
    (WidgetTester tester) async {
      final firstCodec = MockCodec()
        ..frameCount = 2
        ..repetitionCount = -1;
      final secondCodec = MockCodec()
        ..frameCount = 2
        ..repetitionCount = -1;
      final thirdCodec = MockCodec()
        ..frameCount = 2
        ..repetitionCount = -1;
      final codecStream = StreamController<Codec>();

      final ImageStreamCompleter imageStream = MultiImageStreamCompleter(
        codec: codecStream.stream,
        scale: 1.0,
        animate: false,
      );

      final emittedImages = <ImageInfo>[];
      imageStream.addListener(
        ImageStreamListener(
          (ImageInfo image, bool synchronousCall) => emittedImages.add(image),
        ),
      );

      codecStream.add(firstCodec);
      await tester.idle();
      firstCodec.completeNextFrame(
        FakeFrameInfo(const Duration(milliseconds: 200), image20x10),
      );
      await tester.idle();
      await tester.pump();
      expect(emittedImages.length, 1);

      // A paused image has no frame duration to wait out, so a replacement
      // codec is shown as soon as its first frame is decoded.
      codecStream.add(secondCodec);
      await tester.idle();
      final FrameInfo secondFrame =
          FakeFrameInfo(const Duration(milliseconds: 400), image200x100);
      secondCodec.completeNextFrame(secondFrame);
      await tester.idle();
      await tester.pump();
      expect(emittedImages.length, 2);
      expect(emittedImages.last.image.isCloneOf(secondFrame.image), true);

      // No timer is left armed, so a further codec is handled rather than
      // buffered and stranded.
      codecStream.add(thirdCodec);
      await tester.idle();
      expect(thirdCodec.numFramesAsked, 1);
      final FrameInfo thirdFrame =
          FakeFrameInfo(const Duration(milliseconds: 200), image50x50);
      thirdCodec.completeNextFrame(thirdFrame);
      await tester.idle();
      await tester.pump();
      expect(emittedImages.length, 3);
      expect(emittedImages.last.image.isCloneOf(thirdFrame.image), true);
    },
  );
}
