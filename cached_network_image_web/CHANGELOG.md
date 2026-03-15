## [2.1.1] - 2026-03-15

* **Fix:** Enforce that HTTP headers can only be used with `HttpGet`. (PR #16)
  * `HtmlImage` loader now throws an `ArgumentError` (instead of an assertion) when headers are supplied, providing a clear actionable message at runtime.
  * `ImageLoader` automatically switches to `HttpGet` when headers are provided, matching documented behaviour.
  * Improved error messages across both loaders to guide users toward the correct loader type.
* Added `@TestOn('browser')` annotation to the web test file so tests are skipped gracefully on non-browser platforms. (PR #16)

## [2.1.0] - 2026-02-23

* **Feature:** Added SVG format detection in `HttpGet` loader path
* Updated to use `ImageFormatDetector` from platform interface 5.1.0
* Throws `UnsupportedImageFormatException` for SVG bytes before decoding

## [2.0.1] - 2026-02-19

* Renamed package to `cached_network_image_web_ce`
* Updated dependency to `cached_network_image_platform_interface_ce`
* Added `repository` field for pub.dev source code display

## [1.3.1] - 2024-08-13

* Target js_interop for Wasm support

## [1.3.0] - 2024-08-01

* Update dependencies
* Update SDK version to 3.0.0

## [1.2.0] - 2024-04-29

* Replace deprecated `webOnlyInstantiateImageCodecFromUrl` to `createImageCodecFromUrl` from `dart:ui_web`

## [1.1.1] - 2023-12-31

* Removed errorListener from ImageLoader interface

## [1.1.0] - 2023-09-25

* Add error to ErrorListener
* Specify types
* Update example
* Remove [`load`](https://github.com/flutter/flutter/pull/132679), use `loadImage` instead `loadBuffer`

## [1.0.2] - 2022-08-31

* Added loadBufferAsync and deprecated loadAsync

## [1.0.1] - 2021-08-02

* Bug: fixed CORS issues in HTML image version.

## [1.0.0] - 2021-07-16

* Initial release
