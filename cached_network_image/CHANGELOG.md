## [4.6.4] - 2026-03-24

* **Fix:** Resolve `HiveError` crashes caused by URL string keys exceeding 255 characters. Long cache keys are now automatically hashed using SHA-256 to remain under Hive's 255-character length limit.

## [4.6.3] - 2026-03-15

* **Fix:** Handle exceptions when closing the Hive cache box and Hive instance during `dispose()`. (PR #17)
  * `PathNotFoundException` (e.g. when the cache directory was deleted before dispose) is now silently swallowed so callers can dispose without wrapping in try-catch.
* **Feat:** Ensure the cache directory exists before any file read/write operation. (PR #17)
  * Prevents `PathNotFoundException` on first use when the OS or test harness removes the temp directory between initialisation and the first cache put/get.
* Added regression tests for cache-directory resilience and for safe disposal after `emptyCache()`. (PR #17)

## [4.6.2] - 2026-03-04

* **Fix:** Handle Hive box corruption gracefully during cache initialization.
  * When `openBox` encounters a corrupted box with unknown typeIds (e.g., from removed adapters), catch `HiveError`, safely delete the box, and retry initialization.
  * Cleans up orphaned cache files after box recovery to prevent stale data.
  * Regression tests added for box corruption recovery on both IO and web platforms.
  * Issue #12: Fixes production crash "HiveError: Cannot read, unknown typeId" reported via Firebase Crashlytics.

## [4.6.1] - 2026-03-04

* **Fix:** Re-export `ConnectionParameters` from the main `cached_network_image_ce` barrel file so it is accessible without a separate `cached_network_image_platform_interface_ce` import.
* **Fix:** Added missing `connectionParameters` parameter to the stub `DefaultCacheManager` for unsupported platforms.
* Added example demonstrating `DefaultCacheManager` with `ConnectionParameters`.

## [4.6.0] - 2026-03-03

* **Feature:** Added optional HTTP timeout support via `ConnectionParameters` on `DefaultCacheManager`.
  * `connectionTimeout` limits time waiting for response headers.
  * `requestTimeout` applies an inactivity timeout while streaming response bytes.
  * Existing behavior is preserved when `connectionParameters` is not provided.
* Added tests for timeout behavior and client cleanup on timeout.

## [4.5.0] - 2026-03-02

* **Feature:** Added web platform support. The package can now be used in Flutter web apps.
  * Web caching uses Hive CE backed by IndexedDB — no new dependencies needed.
  * Image bytes and metadata are stored in Hive boxes on web instead of the file system.
  * Disk-based image resizing is skipped on web (originals are cached as-is).
  * The `DefaultCacheManager` is now conditionally imported per platform (IO/web).

## [4.4.0] - 2026-02-27

* **Feature:** Skip placeholder and fade animations when images are loaded from disk cache. Cached images now appear instantly without unnecessary visual flicker.
* Added `disablePlaceholderOnCacheHit` parameter (default `true`) to opt out of this behavior.
* `CachedNetworkImage` is now a `StatefulWidget` to support async cache pre-checking.

## [4.3.0] - 2026-02-26

* **Feature/Deprecation:** Added `errorBuilder` to `CachedNetworkImage` and `CachedImageWidget`, which aligns with Flutter's standard `ImageErrorWidgetBuilder`. The old `errorWidget` property is now deprecated.
* **Fix:** Resolved a memory leak where `errorListener` would prevent `CachedNetworkImage` from being garbage collected. Uses `addEphemeralErrorListener` on Flutter >= 3.16.

## [4.2.0] - 2026-02-23

* **Feature:** Added SVG support via new `unsupportedImageBuilder` callback
  * New `UnsupportedImageFormatException` thrown when image format is not supported by Flutter's standard codec
  * New `ImageFormatDetector` utility with content sniffing for SVG detection
  * Images are still cached normally; only rendering path differs
  * Example app updated with SVG demo using `flutter_svg`
  * 24 new tests added (18 format detection + 6 widget integration)
  * See README for usage example

## [4.1.1] - 2026-02-20

* **Fix:** Removed global `Hive.init()` usage from `DefaultCacheManager` to avoid conflicts with host app Hive initialization
* **Fix:** Added initialization synchronization in `DefaultCacheManager` to prevent parallel cold-start race conditions
* **Fix:** Switched cache metadata box opening to explicit `openBox(path: ...)` on a private Hive instance for reliable isolation
* **Feature:** Added optional `cacheDirectoryProvider` parameter to `DefaultCacheManager` so apps can control cache storage location
* **Tests:** Added regression tests for Hive init conflicts, concurrent initialization races, and cache directory resilience scenarios

## [4.1.0] - 2026-02-19

* **Feature:** Added `httpClientFactory` parameter to `DefaultCacheManager` for HTTP client dependency injection, enabling easy mocking in tests
* **Refactor:** Replaced raw `Map<String, dynamic>` with typed `CacheEntryMetadata` class for all cache metadata operations
* **Tests:** Comprehensive test coverage (131 tests, 86% coverage)
  * `DefaultCacheManager`: HTTP download success/errors, progress reporting, header forwarding, cache hit/miss/stale behavior, cleanup logic (31 tests)
  * Leak tests: StreamController closure, `http.Client` cleanup, file sink closure, `ImageLoader` chunkEvents, `MultiImageStreamCompleter` disposal, Hive box lifecycle (19 tests)
  * `ImageLoader`, `CachedNetworkImageProvider`, `CacheEntryMetadata` coverage
* **Fix:** Resolved analyzer warnings across all packages

## [4.0.1] - 2026-02-19

* Added `repository` field for pub.dev source code display
* Updated README with benchmarks and architectural details
* Updated dependencies to `_ce` suffixed packages

## [3.4.1] - 2024-08-13

* Target js_interop for Wasm support

## [3.4.0] - 2024-04-10

* Change how errors are reported by ImageLoader. Emitting errors as streams instead of re-throwing.
* Improved debug console messages
* Update dependencies
* added static field defaultCacheManager to CachedNetworkImageProvider
* Expose scale of CachedNetworkImageProvider on CachedNetworkImage

## [3.3.1] - 2023-12-31

* Adding an errorListener prevents automatic reporting to global error handler.

## [3.3.0] - 2023-09-25

* Add error to ErrorListener
* Update to Dart 3
* Remove [`load`](https://github.com/flutter/flutter/pull/132679), use `loadImage` instead `loadBuffer`

Minor code clean-ups:

* Add topics in pubspec
* Specify types
* Update example

## [3.2.3] - 2022-11-25

* Correctly dispose image stream handler

## [3.2.2] - 2022-08-31

* loadBuffer is added and used instead of load

## [3.2.1] - 2022-05-16

* Update to Flutter 3

## [3.2.0] - 2021-11-29

* Add option to set the log level of the cache manager, for example:

```dart
CachedNetworkImage.logLevel = CacheManagerLogLevel.debug;
```

* Update cache manager dependency.

## [3.1.0+1] - 2021-11-04

* Update Readme

## [3.1.0] - 2021-07-16

* Separate Web and IO implementations

## [3.0.0] - 2021-03-27

* Migrate to null safety
* Fix "Cannot clone a disposed image" error
* Update dependencies.

## [3.0.0-nullsafety] - 2021-01-02

* Migrate to null safety

## [2.5.1] - 2021-03-09

* Update dependencies

## [2.5.0] - 2020-12-22

* Add support for resizing images in disk cache.

```dart
CachedNetworkImage(
  maxHeightDiskCache: 200,
  imageUrl: 'https://via.placeholder.com/3000x2000',
);
```

## [2.4.1] - 2020-12-01

* Fix a bug that an image is disposed when it shouldn't.

## [2.4.0] - 2020-11-30

* Added support for a cache key which is different from the image url.

## [2.3.3] - 2020-10-16

* Support for flutter_cache_manager 2.x.x.

## [2.3.2] - 2020-09-10

* Fixed placeholders and error widgets, those are not always centered anymore.
* Evict an image from ImageCache if image fails to load.
* Added method to evict an image from memory and disk cache.

## [2.3.1] - 2020-08-25

* Fixed fading when the image has no placeholder or progress indicator.

## [2.3.0] - 2020-08-25

* Improved image loading by using OctoImage. OctoImage uses the native callbacks of the ImageProvider instead of
 loading the file when the ImageWidget is build the first time.
* Set minimal Flutter version to 1.20.0; first compatible stable version.
* Added choice for rendering of images on web. Defaults to standard HTML ImageElement, but gives the option to use a
 custom HTTP Get for headers and skia support.
* Use a MultiImageStreamCompleter for when an image that is available in the cache is updated.

## [2.3.0-rc] - 2020-06-20

* Added choice for rendering of images on web. Defaults to standard HTML ImageElement, but gives the option to use a
 custom HTTP Get for headers and skia support.
* Use a MultiImageStreamCompleter for when an image that is available in the cache is updated.
* Increase minimal version of Flutter to 1.19.0-2.0.pre (currently requires Beta) due to an error listener bug.

## [2.3.0-beta.1] - 2020-05-28

* Improved web support: support for headers and skia.

## [2.3.0-beta] - 2020-05-20

* Rewrote image widget by using OctoImage.

## [2.2.0+1] - 2020-05-05

* Fix ImageProvider not using provided headers.

## [2.2.0] - 2020-04-30

* Upgrades on CachedNetworkImageProvider:
  * Support for download progress.
  * Basic web support (no caching).

## [2.1.0+1] - 2020-04-10

* Update minimal Dart sdk version

## [2.1.0] - 2020-04-10

* Update CacheManager
* Added option for progress indicator

## [2.0.0] - 2019-12-31

* Public release of 2.0 version

## [2.0.0-rc.1] - 2019-11-04

* Revert scaling of image due to issues with BoxFit.

## [2.0.0-rc] - 2019-10-17

* BREAKING CHANGE: Compatibility for [breaking change in Flutter 1.10.15](https://groups.google.com/forum/#!topic/flutter-announce/lUKzLAd8OG8)

## [1.1.3] - 2019-11-04

* Revert scaling of image due to issues with BoxFit.

## [1.1.2+1] - 2019-10-17

* Fix for widgets declared with infinite size.

## [1.1.2] - 2019-10-16

* Add filterQuality property.
* Scale image to size when showing in widget.
* Better error handling.
* Fix for useOldImageOnUrlChange.
* Update cache manager to 1.1.2.

## [1.1.1] - 2019-07-23

* Updated cache manager for error handling fix

## [1.1.0] - 2019-07-13

* Improved performance
* Keep fetched files in sync with filemanager.
* Better error handling.
* Added extra example to show the imageBuilder

## [1.0.0] - 2019-06-27

* Updated dependencies

## [0.8.0] - 2019-05-06

* Fixed compile error on informationCollector by temporarily disabling it.

## [0.7.0] - 2019-03-06

* BREAKING CHANGE: Renamed ErrorWidgetBuilder to LoadingErrorWidgetBuilder
* LoadingErrorWidgetBuilder returns an Object instead of an Exception
* Fixed BoxFit to also work when size is not defined

## [0.6.2] - 2019-02-27

* Added option to blend image with color
* Added option in CacheManager to clear the cache

## [0.6.1] - 2019-02-25 BREAKING CHANGES

* No longer assume infinite size.

## [0.6.0] - 2019-02-18 BREAKING CHANGES

* Breaking changes in API and behaviour
* Very much improved though
* Adapted for new cache manager library
* Completely rewritten image view
* Now using builders for placeholder and error widgets
* Added optional builder to customize the image

## [0.5.1] - 2018-11-19

* Fixed error throwing

## [0.5.0] - 2018-10-13

* Updated cache manager for http 0.12.0

## [0.4.2] - 2018-08-30

* Updated cache manager dependency

## [0.4.1] - 2018-04-27

* Improved error handling when a file could not be loaded.

## [0.4.0] - 2018-04-14

* Added optional headers.
* Changed to Dart 2.0
* Fixed bug when updating widget with new url

## [0.3.0] - 2018-02-09

* Added CachedNetworkImage with placeholder and error widgets.

## [0.2.1] - 2018-01-08

* Moved from OneFrameImageStreamCompleter to MultiFrameImageStreamCompleter.
* Updated CacheManager dependency for critical bug fix.

## [0.2.0] - 2017-12-29

* **Breaking change** Removed CachedNetworkImage. From now on only the ImageProvider is supported. For a placeholder use `FadeInImage`. See also ["Fallback for Network Images"](https://github.com/flutter/flutter/issues/6229).
* Moved CacheManager to a separate library for a more generic purpose.

## [0.1.0] - 2017-12-21

* **Breaking change**. Upgraded to Gradle 4.1 and Android Studio Gradle plugin
  3.0.1. Older Flutter projects need to upgrade their Gradle setup as well in
  order to use this version. Instructions can be found
  [here](https://github.com/flutter/flutter/wiki/Updating-Flutter-projects-to-Gradle-4.1-and-Android-Studio-Gradle-plugin-3.0.1).

## [0.0.2] - 10 December 2017

Added an ImageProvider and improved documentation

## [0.0.1] - 2 December 2017

Initial release, should be polished
