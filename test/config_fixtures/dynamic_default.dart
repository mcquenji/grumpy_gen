import 'package:grumpy_annotations/grumpy_annotations.dart';

@config
class GlobalSettings {
  String get token => DateTime.now().toString();
}
