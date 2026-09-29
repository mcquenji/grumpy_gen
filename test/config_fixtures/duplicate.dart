import 'package:grumpy_annotations/grumpy_annotations.dart';

@config
class GlobalSettings {
  const GlobalSettings({this.port = 8080});
  final int port;
}

@Config(.local)
class LocalSettings {
  const LocalSettings({this.port = 9000});
  final int port;
}
