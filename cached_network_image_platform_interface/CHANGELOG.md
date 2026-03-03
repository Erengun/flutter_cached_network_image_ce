## [5.2.0] - 2026-03-03

* **Feature:** Added `ConnectionParameters` configuration class.
	* Includes optional `connectionTimeout` and `requestTimeout` fields.
	* Enables cache managers to apply HTTP timeout behavior while preserving current behavior when omitted.

## [5.1.0] - 2026-02-23

* **Feature:** Added `UnsupportedImageFormatException` for non-codec-decodable formats (e.g., SVG)
* **Feature:** Added `ImageFormatDetector` utility with SVG content sniffing
* Exported new types for use by platform implementations

## [5.0.1] - 2026-02-19

* Renamed package to `cached_network_image_platform_interface_ce`
* Added `repository` field for pub.dev source code display

## [4.1.1] - 2024-08-13

* Target js_interop for Wasm support

## [4.1.0] - 2024-08-01

* Update dependencies
* Update SDK version to 3.0.0

## [4.0.0] - 2023-12-31

* Removed errorListener from ImageLoader interface

## [3.0.0] - 2023-09-25

* Add error to ErrorListener
* Specify types
* Remove [`load`](https://github.com/flutter/flutter/pull/132679), use `loadImage` instead `loadBuffer`

## [2.0.0] - 2022-08-31

* Added loadBufferAsync for Flutter 3.3

## [1.0.0] - 2021-07-16

* Initial release
