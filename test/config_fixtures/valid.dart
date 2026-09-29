import 'package:grumpy_annotations/grumpy_annotations.dart';

abstract interface class ServerConfig {
  int get port;
}

mixin ServerDefaults implements ServerConfig {
  @override
  int get port => 8000 + 80;
}

enum Environment { development, production }

@config
class GlobalSettings with ServerDefaults {
  const GlobalSettings({
    this.enabled = false,
    this.environment = Environment.development,
    this.tags = const [],
    this.token,
  });

  /// Enable update checks.
  final bool enabled;
  final Environment environment;
  final List<String> tags;
  final String? token;
}

@Config(.local)
class LocalSettings {
  const LocalSettings({this.name});

  /// Workspace name.
  @ConfigField(minLength: 1, examples: ['demo'])
  final String? name;
}
