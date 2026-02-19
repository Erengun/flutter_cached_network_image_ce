import 'package:file/file.dart';

/// Base class for responses from the cache manager.
///
/// A [FileResponse] is either a [FileInfo] object for fully downloaded files
/// or a [DownloadProgress] object for when a file is being downloaded.
abstract class FileResponse {
  const FileResponse(this.originalUrl);

  /// Url from which the file was fetched.
  final String originalUrl;
}

/// Progress of the file that is being downloaded from the [originalUrl].
class DownloadProgress extends FileResponse {
  const DownloadProgress(super.originalUrl, this.totalSize, this.downloaded);

  /// Download progress as a double between 0 and 1.
  /// When the final size is unknown or the downloaded size exceeds the total
  /// size, [progress] is null.
  double? get progress {
    if (totalSize == null || downloaded > totalSize!) return null;
    return downloaded / totalSize!;
  }

  /// Final size of the download. If total size is unknown this will be null.
  final int? totalSize;

  /// Total of currently downloaded bytes.
  final int downloaded;
}

/// Enum for whether the file is coming from the cache or is just downloaded.
// ignore: constant_identifier_names
enum FileSource { NA, Cache, Online }

/// FileInfo contains the fetched [File] next to some info on the validity and
/// the origin of the file.
class FileInfo extends FileResponse {
  const FileInfo(
    this.file,
    this.source,
    this.validTill,
    String originalUrl, {
    this.statusCode = 200,
  }) : super(originalUrl);

  /// The fetched file.
  final File file;

  /// Source of the file, can be cache or online (web).
  final FileSource source;

  /// Validity date of the file. After this date the validity is not guaranteed
  /// and the CacheManager will try to update the file.
  final DateTime validTill;

  /// HTTP status code of the response.
  final int statusCode;
}
