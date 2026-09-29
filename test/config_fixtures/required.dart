import 'package:grumpy_annotations/grumpy_annotations.dart';

@config
class GlobalSettings {
  const GlobalSettings({required this.port});
  final int port;
}
