import 'package:grumpy_annotations/grumpy_annotations.dart';

String? validateToken(String value) =>
    value == 'valid' ? null : 'Invalid token';

@config
class GlobalSettings {
  const GlobalSettings({this.token});
  @ConfigField(
    validate: validateToken,
    runtimeValidationDescription: 'Token must be valid.',
  )
  final String? token;
}
