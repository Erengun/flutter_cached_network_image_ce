# Cached Network Image — Community Edition

[![pub package](https://img.shields.io/pub/v/cached_network_image_ce.svg)](https://pub.dev/packages/cached_network_image_ce)

A Flutter library to show images from the internet and keep them in the cache directory. Community maintained fork of [`cached_network_image`](https://pub.dev/packages/cached_network_image).

## Why this fork?

The [original `cached_network_image`](https://github.com/Baseflow/flutter_cached_network_image) by Baseflow has been **unmaintained for over 2 years**, with no updates, bug fixes, or responses to issues and pull requests. This community edition was created to:

- **Keep the package alive** — continue fixing bugs and adding features the community needs.
- **Replace `sqflite` with `hive_ce` for cache storage** — the original package depended on `flutter_cache_manager` (also by Baseflow) which used `sqflite` under the hood. This community edition uses [`hive_ce`](https://pub.dev/packages/hive_ce) instead, which is more performant and actively maintained.
- **Stay up-to-date** with the latest Flutter and Dart SDK versions.

## How to use

The `CachedNetworkImage` can be used directly or through the `ImageProvider`.
Both `CachedNetworkImage` and `CachedNetworkImageProvider` have minimal support for web (currently without caching).

With a placeholder:
```dart
CachedNetworkImage(
  imageUrl: 'https://via.placeholder.com/350x150',
  placeholder: (context, url) => CircularProgressIndicator(),
  errorWidget: (context, url, error) => Icon(Icons.error),
),
```

Or with a progress indicator:
```dart
CachedNetworkImage(
  imageUrl: 'https://via.placeholder.com/350x150',
  progressIndicatorBuilder: (context, url, downloadProgress) =>
      CircularProgressIndicator(value: downloadProgress.progress),
  errorWidget: (context, url, error) => Icon(Icons.error),
),
```

```dart
Image(image: CachedNetworkImageProvider(url))
```

When you want to have both the placeholder functionality and want to get the image provider to use in another widget you can provide an `imageBuilder`:
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

## How it works

The cached network images stores and retrieves files using the [flutter_cache_manager](https://pub.dev/packages/flutter_cache_manager).

## FAQ

### My app crashes when the image loading failed. (I know, this is not really a question.)
Does it really crash though? The debugger might pause, as the Dart VM doesn't recognize it as a caught exception; the console might print errors; even your crash reporting tool might report it (I know, that really sucks). However, does it really crash? Probably everything is just running fine. If you really get an app crash you are fine to report an issue, but do that with a small example so we can reproduce that crash.

## Contributing

Contributions are welcome! Please see the [contributing guide](CONTRIBUTING.md) for details.

## License

This project is licensed under the MIT License.
