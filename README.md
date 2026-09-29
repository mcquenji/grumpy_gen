# grumpy_gen

Source gen to enhance projects using [grumpy](https://github.com/mcquenji/grumpy) or [grumpy_flutter](https://github.com/mcquenji/grumpy_flutter).

## Routes

`grumpy_gen` can generate typed route helpers for any library that declares exactly one concrete `RootModule`.

If the root also extends `AppModule`, the generated output includes Flutter navigation helpers on `BuildContext`. Otherwise it generates only the generic static path API.

### Setup

1. Add a `part` directive to the library that contains the root module.
2. Run `dart run build_runner build`.

Example:

```dart
import 'package:grumpy_flutter/grumpy_flutter.dart';

part 'app.routes.dart';

class App extends AppModule<AppConfig> {
  App(super.cfg);

  @override
  List<FlutterRoute<AppConfig>> get routes => [
    ModuleRoute(path: '/settings', module: Settings()),
    ScreenRoute(path: '/dashboard', view: DashboardScreen()),
  ];

  @override
  Screen get notFoundScreen => NotFoundScreen();

  @override
  Widget buildApp() => const Widget();
}
```

### Generated APIs

For every `RootModule`, `grumpy_gen` emits a `GrumpyRoutes` static container with full-path strings.

Example usage:

```dart
final dashboard = GrumpyRoutes.dashboard;
final advancedSettings = GrumpyRoutes.settings.advanced;
final settingsPrefix = GrumpyRoutes.settings.path;
```

For roots that also extend `AppModule`, `grumpy_gen` additionally emits a typed `BuildContext` extension:

```dart
context.to.dashboard();
context.to.settings.advanced();
context.to.users.id(userId).details();
```

Parameterized path segments are represented as explicit segment methods. A route like `/users/:id/details` becomes:

```dart
GrumpyRoutes.users.id(userId).details
context.to.users.id(userId).details()
```

Module boundaries without a root leaf are still generated as typed namespace objects and expose `.path`, but Flutter `call()` is intentionally not generated for them.

### What Gets Scanned

The generator walks all routes reachable from the root and follows:

- `LeafRoute`
- `ScreenRoute`
- `LeafRoute.root`
- `ScreenRoute.root`
- `ModuleRoute`
- `ShellScreenRoute`
- `Route.root([...])`

Path joining follows the runtime router semantics:

- `ShellScreenRoute` contributes no path segment
- `ModuleRoute` descendants are rooted under the module boundary path
- nested children are flattened into full absolute paths

### Current Limitations

Route generation is intentionally static in v1. The generator currently expects route trees to be declared with direct constructor calls and list literals.

Supported:

```dart
@override
List<FlutterRoute<AppConfig>> get routes => [
  ScreenRoute(path: '/dashboard', view: DashboardScreen()),
  ModuleRoute(path: '/slots', module: Slots()),
];
```

Not supported:

```dart
@override
List<FlutterRoute<AppConfig>> get routes => buildRoutes();
```

or route lists built with control flow or spreads.

If a library contains multiple concrete `RootModule` implementations, generation fails with a clear error.


## Application configuration

Add `grumpy_gen` and `build_runner` as development dependencies to a grumpy_cli application. Annotate one global model with `@config` and optionally one local model with `@Config(.local)`, then run:

```sh
fvm dart run build_runner build
```

The config builder scans only handwritten Dart libraries in your package's `lib/` directory. Annotations in dependencies do not add settings. Reusable packages instead provide interfaces and default mixins for the application's models to implement.

Generation produces an immutable `AppConfig`, typed setting handles, `schema.json`, and a Markdown settings reference. By default, import `lib/src/shared/domain/models/app_config.g.dart`. Pass `AppConfig.defaults()` into your CliApp constructor; after loading configuration, `AppConfig()` resolves the invocation snapshot from DI.

Global and local models may not declare overlapping property names. Local files accept every global property plus local-only properties. Every property must be nullable or have a statically evaluable default. The generated model implements both source models, preserving inherited interfaces for module generic constraints.

Descriptions come from Dartdoc. Defaults come from constant field initializers, constructor defaults, and simple constant getter bodies, including inherited mixins. `@ConfigField` adds numeric ranges, length bounds, patterns, choices, examples, or custom codecs. `@Deprecated` is included in schemas. Generation rejects unsupported defaults and invalid serializable examples instead of executing application code.

Supported inferred values include strings, booleans, integers, doubles, enums, URIs, IoPath, typed lists, string-keyed maps, and immutable structured objects with named constructor parameters. A custom `valueType` is a top-level/static zero-argument CliValueType factory; supply its JSON Schema through `schema`. Runtime-only validators require `runtimeValidationDescription` and are not executed by the generator.

Configure artifact locations and the editor schema URI in the consuming application's `build.yaml`:

```yaml
targets:
  $default:
    builders:
      grumpy_gen:grumpy_config:
        options:
          model_output: lib/src/shared/domain/models/app_config.g.dart
          schema_output: schema.json
          docs_output: docs/configuration.md
          schema_uri: https://example.com/my-tool/schema.json
```

Schemas contain `$defs/global` and `$defs/local`; fields are optional in both files. Runtime validation uses generated declarations without fetching the schema URI. Commit generated artifacts and regenerate in CI before checking for diffs. The grumpy_cli example includes a `tool/generate_config_schema.dart --check` helper for schema/reference freshness.

CLI command helper generation remains deferred. The existing route builder skips CliApp roots.
