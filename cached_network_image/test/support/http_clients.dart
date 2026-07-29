import 'package:http/http.dart' as http;

class AbortTrackingClient extends http.BaseClient {
  AbortTrackingClient({
    required this.onAbort,
    required this.onClose,
  });

  final void Function() onAbort;
  final void Function() onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.Abortable;
    await abortable.abortTrigger;
    onAbort();
    throw http.RequestAbortedException(request.url);
  }

  @override
  void close() {
    onClose();
  }
}
