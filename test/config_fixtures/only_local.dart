import 'package:grumpy_annotations/grumpy_annotations.dart';

@Config(.local)
class LocalSettings {
  const LocalSettings({this.name});
  final String? name;
}
