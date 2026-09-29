import 'package:grumpy_annotations/grumpy_annotations.dart';

@config
class GlobalSettings {
  const GlobalSettings({this.port = 0});
  @ConfigField(min: 1)
  final int port;
}
