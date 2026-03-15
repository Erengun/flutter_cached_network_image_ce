# Cached Network Image — Community Edition

[![pub package](https://img.shields.io/pub/v/cached_network_image_ce.svg)](https://pub.dev/packages/cached_network_image_ce)
[![License: MIT](https://img.shields.io/badge/license-MIT-purple.svg)](https://opensource.org/licenses/MIT)

A Flutter library to show images from the internet and keep them in the cache directory.

**This is the actively maintained, high-performance community fork of [`cached_network_image`](https://pub.dev/packages/cached_network_image).**

---

## 📖 The Story: Why this fork?

The original `cached_network_image` package by Baseflow is a titan in the Flutter ecosystem, used by millions. However, it has been **effectively unmaintained since August 2024**, leaving over 300 issues unresolved, including critical memory leaks and scroll performance bugs.

As the Flutter ecosystem evolved, the original architecture began to show its age. It relied on `sqflite` for cache management—a heavy, SQL-based solution that requires platform channels to communicate with native code. For a simple task like "checking if an image exists," this overhead caused UI jank in heavy lists.

**We created the Community Edition (`_ce`) to fix this.**

We didn't just fork it to merge dependabot PRs. We re-engineered the caching layer.

### ⚡ The Architectural Shift: SQLite vs. Hive

We replaced the heavy `sqflite` dependency with **[`hive_ce`](https://pub.dev/packages/hive_ce)**.

* **Old Way (`sqflite`):** serialized data → Platform Channel → Java/Obj-C → SQLite → Disk. (Slow, blocking).
* **New Way (`hive_ce`):** Dart Memory → Direct Disk Access. (Instant, non-blocking).

The result? **Zero-jank scrolling.**

### 🚀 Benchmarks

We benchmarked the cache metadata operations (checking, writing, and deleting cache entries) on an iPhone Simulator. The results speak for themselves:

| Operation | Payload Size | Original (`sqflite`) | **CE (`hive_ce`)** | **Improvement** |
| :--- | :--- | :--- | :--- | :--- |
| **Read (Hit Check)** | 10 KB | 16 ms | **2 ms** | ⚡ **8.00x Faster** |
| **Write (New Image)** | 10 KB | 116 ms | **29 ms** | 🚀 **4.00x Faster** |
| **Delete (Cleanup)** | 10 KB | 55 ms | **19 ms** | 🧹 **2.89x Faster** |
| **Read (Large)** | 1 MB | 8 ms | **1 ms** | ⚡ **8.00x Faster** |

*Note: "Read" is the most critical operation for scrolling performance, as every list item checks the cache before rendering.*

---

## 🛠 Features

* **Drop-in Replacement:** 99% API compatible with the original package.
* **High Performance:** Powered by `hive_ce` for instant cache lookups.
* **Actively Maintained:** Regular updates, bug fixes, and community-driven roadmap.
* **True Web Support:** Unlike the original package, CE provides **full, persistent image caching** on the Web via IndexedDB (`hive_ce`), completely avoiding RAM freezes by using native image decoding sizes.

## 📦 Installation

Run the following command:

```sh
flutter pub add cached_network_image_ce
```

## 💻 How to use

The API is identical to the original package. You can use `CachedNetworkImage` directly or via `ImageProvider`. Both approaches are fully supported with persistent IndexedDB caching on the web platform out-of-the-box.

### Basic Usage with Placeholder

```dart
import 'package:cached_network_image_ce/cached_network_image.dart';

CachedNetworkImage(
  imageUrl: 'https://via.placeholder.com/350x150',
  placeholder: (context, url) => CircularProgressIndicator(),
  errorWidget: (context, url, error) => Icon(Icons.error),
),
```

### With Progress Indicator

```dart
CachedNetworkImage(
  imageUrl: 'https://via.placeholder.com/350x150',
  progressIndicatorBuilder: (context, url, downloadProgress) =>
      CircularProgressIndicator(value: downloadProgress.progress),
  errorWidget: (context, url, error) => Icon(Icons.error),
),
```

### Advanced Usage (ImageBuilder)

Use this when you need an `ImageProvider` for things like `DecorationImage`:

```dart
CachedNetworkImage(
  imageUrl: 'https://via.placeholder.com/200x150',
  imageBuilder: (context, imageProvider) => Container(
    decoration: BoxDecoration(
      image: DecorationImage(
        image: imageProvider,
        fit: BoxFit.cover,
        colorFilter: ColorFilter.mode(Colors.red, BlendMode.colorBurn),
      ),
    ),
  ),
  placeholder: (context, url) => CircularProgressIndicator(),
  errorWidget: (context, url, error) => Icon(Icons.error),
),
```

### Direct ImageProvider Usage

```dart
Image(image: CachedNetworkImageProvider(url))
```

### Network Timeouts (DefaultCacheManager)

You can configure network timeouts at the cache manager level using
`ConnectionParameters`.

```dart
final cacheManager = DefaultCacheManager(
  connectionParameters: ConnectionParameters(
    connectionTimeout: const Duration(seconds: 10),
    requestTimeout: const Duration(seconds: 30),
  ),
);

CachedNetworkImage(
  imageUrl: 'https://example.com/image.jpg',
  cacheManager: cacheManager,
  errorBuilder: (context, url, error) => const Icon(Icons.error),
)
```

Timeout behavior:

* `connectionTimeout`: max time waiting for response headers.
* `requestTimeout`: inactivity timeout while streaming response bytes.

Both fields are optional and nullable. If `connectionParameters` is not
provided, existing behavior is preserved (no timeout is applied).

On Flutter Web, timeout settings apply when using
`ImageRenderMethodForWeb.HttpGet`. The `HtmlImage` render method uses the
browser image pipeline and bypasses the cache manager HTTP path.

**Web Platform Headers Support:** Custom headers (like `Authorization`) are
**only supported with `ImageRenderMethodForWeb.HttpGet`**. The default
`HtmlImage` render method does not support custom headers. If you need to
send headers to authenticate image requests on Web, you must explicitly set:

```dart
CachedNetworkImage(
  imageUrl: 'https://api.example.com/image.jpg',
  httpHeaders: {'Authorization': 'Bearer token'},
  imageRenderMethodForWeb: ImageRenderMethodForWeb.HttpGet,
),
```

Note: Using `HttpGet` on Web disables the browser's default image caching
mechanisms, so images are cached via the `cache_manager` instead.

### SVG Support

Flutter's built-in image codec doesn't support SVG. When `CachedNetworkImage`
detects SVG bytes it throws an `UnsupportedImageFormatException`. Use the
`unsupportedImageBuilder` callback to render them with any SVG package you
prefer (e.g. [`flutter_svg`](https://pub.dev/packages/flutter_svg)):

Before using `SvgPicture.memory`, add `flutter_svg` to `pubspec.yaml`
(`dependencies: flutter_svg: ^2.2.1`) and import
`package:flutter_svg/flutter_svg.dart`.

```dart
CachedNetworkImage(
  imageUrl: 'https://example.com/image.svg',
  unsupportedImageBuilder: (context, url, bytes) {
    // `bytes` are the already-cached file bytes.
    return SvgPicture.memory(bytes); // from flutter_svg
  },
  placeholder: (context, url) => CircularProgressIndicator(),
  errorWidget: (context, url, error) => Icon(Icons.error),
),
```

The image is still downloaded and cached normally — only the **rendering**
path is different. If `unsupportedImageBuilder` is not set, the error falls
through to `errorWidget` with an `UnsupportedImageFormatException`.

## ❓ FAQ

**Q: Will I lose my users' existing cache if I migrate?**
A: Yes. Because we switched the storage engine from SQLite to Hive, the old cache files will be ignored. Users will re-download images once as they browse. This is a one-time migration cost for a permanent performance gain.

**Q: My app crashes/pauses on errors?**
A: In Debug mode, Flutter may pause on exceptions even if they are caught. This is expected behavior for network errors (404s). In Release mode, these are handled silently by the `errorWidget`.

**Q: Why is web caching slower or using Hive for image bytes?**
A: On Mobile & Desktop (IO), this package stores image bytes directly on the incredibly fast native file system, and uses Hive *only* for metadata. The Web platform, however, lacks a native file system. Therefore, for web we use `hive_ce` to store both metadata and the actual image bytes in IndexedDB. Serializing large byte arrays in and out of IndexedDB introduces overhead that isn't present on IO. 
*Alternative:* If persistent caching across sessions isn't critical for your web users, consider conditionally using the standard `Image.network` on the web, which relies on the browser's built-in memory/HTTP caching to achieve faster decoding.

## 🤝 Contributing

We welcome contributions! If you want to help maintain this essential package, please check the [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

This project is licensed under the MIT License.
