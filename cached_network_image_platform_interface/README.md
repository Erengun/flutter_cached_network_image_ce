# cached_network_image_platform_interface_ce

Platform interface package for `cached_network_image_ce` and platform
implementations.

## Exposed API highlights

* Base cache manager contracts (`BaseCacheManager`, `CacheManager`,
  `ImageCacheManager`)
* File response and progress models (`FileInfo`, `DownloadProgress`)
* Error and format helpers (`HttpExceptionWithStatus`,
  `UnsupportedImageFormatException`, `ImageFormatDetector`)
* Network timeout configuration object (`ConnectionParameters`)
