import 'dart:async';
import 'dart:ui' as ui show Codec, FrameInfo;

import 'package:cached_network_image_ce/src/gif_frame_duration.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

/// Slows down animations by this factor to help in development.
double get timeDilation => _timeDilation;
double _timeDilation = 1;

/// An ImageStreamCompleter with support for loading multiple images.
class MultiImageStreamCompleter extends ImageStreamCompleter {
  /// The constructor to create an MultiImageStreamCompleter. The [codec]
  /// should be a stream with the images that should be shown. The
  /// [chunkEvents] should indicate the [ImageChunkEvent]s of the first image
  /// to show.
  MultiImageStreamCompleter({
    required Stream<ui.Codec> codec,
    required double scale,
    Stream<ImageChunkEvent>? chunkEvents,
    InformationCollector? informationCollector,
    this.minimumGifFrameDuration = const Duration(milliseconds: 100),
  })  : _informationCollector = informationCollector,
        _scale = scale {
    codec.listen(
      (event) {
        if (_timer != null) {
          // A previously buffered codec was never decoded from; drop it.
          _nextImageCodec?.dispose();
          _nextImageCodec = event;
        } else {
          _handleCodecReady(event);
        }
      },
      onError: (Object error, StackTrace stack) {
        reportError(
          context: ErrorDescription('resolving an image codec'),
          exception: error,
          stack: stack,
          informationCollector: informationCollector,
          silent: true,
        );
      },
    );
    if (chunkEvents != null) {
      _chunkSubscription = chunkEvents.listen(
        reportImageChunkEvent,
        onError: (Object error, StackTrace stack) {
          reportError(
            context: ErrorDescription('loading an image'),
            exception: error,
            stack: stack,
            informationCollector: informationCollector,
            silent: true,
          );
        },
      );
    }
  }

  ui.Codec? _codec;
  ui.Codec? _nextImageCodec;
  final double _scale;
  final InformationCollector? _informationCollector;

  /// The minimum frame duration applied to GIF images when decoded frame
  /// durations are extremely short.
  ///
  /// Defaults to 100ms.
  final Duration minimumGifFrameDuration;
  ui.FrameInfo? _nextFrame;

  // When the current was first shown.
  Duration? _shownTimestamp;

  // The requested duration for the current frame;
  Duration? _frameDuration;

  // How many frames have been emitted so far.
  int _framesEmitted = 0;
  Timer? _timer;
  StreamSubscription<ImageChunkEvent>? _chunkSubscription;

  // Used to guard against registering multiple _handleAppFrame callbacks for the same frame.
  bool _frameCallbackScheduled = false;

  // The codecs with a `getNextFrame()` call currently awaiting a result. A
  // codec that is replaced mid-decode stays here until its decode returns, so
  // a superseded codec finishing cannot make the current codec look idle, and
  // the pending decode is known to be that codec's last user.
  final _decodingCodecs = <ui.Codec>{};

  /// We must avoid disposing a completer if it never had a listener, even
  /// if all [keepAlive] handles get disposed.
  bool __hadAtLeastOneListener = false;

  bool __disposed = false;

  void _switchToNewCodec() {
    _timer = null;
    _handleCodecReady(_nextImageCodec!);
    _nextImageCodec = null;
  }

  void _handleCodecReady(ui.Codec codec) {
    final previousCodec = _codec;
    _codec = codec;
    _framesEmitted = 0;

    if (previousCodec != null &&
        previousCodec != codec &&
        !_decodingCodecs.contains(previousCodec)) {
      // Nothing is decoding from the outgoing codec, so it can be released
      // here. If a decode is still pending it owns the disposal instead, as
      // disposing a codec with a frame in flight would fail that decode.
      previousCodec.dispose();
    }

    if (hasListeners) {
      _decodeNextFrameAndSchedule();
    }
  }

  void _handleAppFrame(Duration timestamp) {
    _frameCallbackScheduled = false;
    if (!hasListeners) return;
    final nextFrame = _nextFrame;
    if (nextFrame == null) {
      // A replacement codec started a new decode after this callback was
      // scheduled, releasing the frame it was scheduled to emit. The new
      // decode schedules a callback of its own.
      return;
    }
    if (_isFirstFrame() || _hasFrameDurationPassed(timestamp)) {
      // Take the frame before `_emitFrame`, which notifies listeners
      // synchronously: a listener that re-adds itself from that callback can
      // start a decode, whose prologue would otherwise release the frame still
      // being read here.
      _nextFrame = null;
      _shownTimestamp = timestamp;
      _frameDuration = clampGifFrameDuration(
        nextFrame.duration,
        minimumGifFrameDuration: minimumGifFrameDuration,
      );
      _emitFrame(ImageInfo(image: nextFrame.image.clone(), scale: _scale));
      nextFrame.image.dispose();
      if (_framesEmitted % _codec!.frameCount == 0 && _nextImageCodec != null) {
        _switchToNewCodec();
      } else {
        final completedCycles = _framesEmitted ~/ _codec!.frameCount;
        if (_codec!.repetitionCount == -1 ||
            completedCycles <= _codec!.repetitionCount) {
          _decodeNextFrameAndSchedule();
        }
      }
      return;
    }
    final delay = _frameDuration! - (timestamp - _shownTimestamp!);
    _timer = Timer(delay * timeDilation, _scheduleAppFrame);
  }

  bool _isFirstFrame() {
    return _frameDuration == null;
  }

  bool _hasFrameDurationPassed(Duration timestamp) {
    return timestamp - _shownTimestamp! >= _frameDuration!;
  }

  Future<void> _decodeNextFrameAndSchedule() async {
    final codec = _codec!;
    if (_decodingCodecs.contains(codec)) {
      // A decode of this codec is already pending. A second concurrent decode
      // would emit two frames that dispose each other's image.
      return;
    }

    // This will be null if we gave it away. If not, it's still ours and it
    // must be disposed of.
    _nextFrame?.image.dispose();
    _nextFrame = null;
    ui.FrameInfo? frame;
    _decodingCodecs.add(codec);
    try {
      frame = await codec.getNextFrame();
    } on Object catch (exception, stack) {
      reportError(
        context: ErrorDescription('resolving an image frame'),
        exception: exception,
        stack: stack,
        informationCollector: _informationCollector,
        silent: true,
      );
    } finally {
      _decodingCodecs.remove(codec);
    }

    if (_codec != codec) {
      // A newer codec was installed while this frame was decoding. The frame
      // belongs to the old codec and must not be emitted under the new one,
      // and this decode was the outgoing codec's last user, so it performs the
      // disposal that `_handleCodecReady` deferred.
      frame?.image.dispose();
      codec.dispose();
      return;
    }
    if (frame == null) {
      // The decode failed and was already reported.
      return;
    }
    _nextFrame = frame;

    if (codec.frameCount == 1) {
      // ImageStreamCompleter listeners removed while waiting for next frame to
      // be decoded.
      // There's no reason to emit the frame without active listeners.
      if (!hasListeners) {
        return;
      }

      // This is not an animated image, just return it and don't schedule more
      // frames.
      _emitFrame(ImageInfo(image: _nextFrame!.image.clone(), scale: _scale));
      _nextFrame!.image.dispose();
      _nextFrame = null;
      return;
    }
    _scheduleAppFrame();
  }

  void _scheduleAppFrame() {
    if (_frameCallbackScheduled) {
      return;
    }
    _frameCallbackScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback(_handleAppFrame);
  }

  void _emitFrame(ImageInfo imageInfo) {
    // Count the frame before setImage, which notifies listeners synchronously:
    // a listener that drops and re-adds itself from that callback must not see
    // a state that claims nothing has been emitted from this codec yet.
    _framesEmitted += 1;
    setImage(imageInfo);
  }

  @override
  void addListener(ImageStreamListener listener) {
    __hadAtLeastOneListener = true;
    // Only decode when nothing has been emitted from the current codec yet, or
    // when the image is animated. Re-decoding an already decoded single-frame
    // codec renders black on the web, where CanvasKit images lazily reference a
    // single shared <img> element that is cleared when the previous frame is
    // disposed.
    if (!hasListeners &&
        _codec != null &&
        (_framesEmitted == 0 || _codec!.frameCount > 1)) {
      _decodeNextFrameAndSchedule();
    }
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
      __maybeDispose();
    }
  }

  int __keepAliveHandles = 0;

  @override
  ImageStreamCompleterHandle keepAlive() {
    final delegateHandle = super.keepAlive();
    return _MultiImageStreamCompleterHandle(this, delegateHandle);
  }

  void __maybeDispose() {
    if (!__hadAtLeastOneListener ||
        __disposed ||
        hasListeners ||
        __keepAliveHandles != 0) {
      return;
    }

    __disposed = true;

    _chunkSubscription?.onData(null);
    _chunkSubscription?.cancel();
    _chunkSubscription = null;
  }
}

class _MultiImageStreamCompleterHandle implements ImageStreamCompleterHandle {
  _MultiImageStreamCompleterHandle(this._completer, this._delegateHandle) {
    _completer!.__keepAliveHandles += 1;
  }

  MultiImageStreamCompleter? _completer;
  final ImageStreamCompleterHandle _delegateHandle;

  /// Call this method to signal the [ImageStreamCompleter] that it can now be
  /// disposed when its last listener drops.
  ///
  /// This method must only be called once per object.
  @override
  void dispose() {
    assert(_completer != null);
    assert(_completer!.__keepAliveHandles > 0);
    assert(!_completer!.__disposed);

    _delegateHandle.dispose();

    _completer!.__keepAliveHandles -= 1;
    _completer!.__maybeDispose();
    _completer = null;
  }
}
