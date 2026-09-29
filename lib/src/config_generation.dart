import 'dart:convert';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:glob/glob.dart';
import 'package:source_gen/source_gen.dart';

import 'route_generation.dart';

/// Generates one application's config model, editor schema and settings guide.
Builder grumpyConfigBuilder(BuilderOptions options) =>
    GrumpyConfigBuilder(options);

/// Package-scoped builder: dependency annotations never add application settings.
class GrumpyConfigBuilder implements Builder {
  /// Configures artifact paths and the optional hosted schema URI.
  GrumpyConfigBuilder(BuilderOptions options)
    : modelPath =
          options.config['model_output'] as String? ??
          'lib/src/shared/domain/models/app_config.g.dart',
      schemaPath = options.config['schema_output'] as String? ?? 'schema.json',
      docsPath =
          options.config['docs_output'] as String? ?? 'docs/configuration.md',
      schemaUri = options.config['schema_uri'] as String? {
    if (!modelPath.startsWith('lib/') || !modelPath.endsWith('.g.dart')) {
      throw ArgumentError('model_output must be a .g.dart file below lib/.');
    }
    for (final path in [modelPath, schemaPath, docsPath]) {
      if (path.startsWith('/') || path.split('/').contains('..')) {
        throw ArgumentError(
          'Config output paths must stay inside the package.',
        );
      }
    }
  }

  /// Generated application model asset.
  final String modelPath;

  /// Generated JSON Schema asset.
  final String schemaPath;

  /// Generated settings reference asset.
  final String docsPath;

  /// Optional schema URI used only for editor metadata.
  final String? schemaUri;

  @override
  Map<String, List<String>> get buildExtensions => {
    r'$package$': [modelPath, schemaPath, docsPath],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final libraries = <LibraryElement>[];
    final assets = await buildStep.findAssets(Glob('lib/**.dart')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final asset in assets) {
      if (RegExp(r'\.(g|freezed|routes)\.dart$').hasMatch(asset.path)) continue;
      if (await buildStep.resolver.isLibrary(asset)) {
        libraries.add(await buildStep.resolver.libraryFor(asset));
      }
    }
    final artifacts = await generateConfigArtifacts(
      libraries,
      BuildStepRouteAstResolver(buildStep.resolver),
      schemaUri: schemaUri ?? schemaPath,
    );
    if (artifacts == null) return;
    for (final entry in {
      modelPath: artifacts.model,
      schemaPath: artifacts.schema,
      docsPath: artifacts.documentation,
    }.entries) {
      await buildStep.writeAsString(
        AssetId(buildStep.inputId.package, entry.key),
        entry.value,
      );
    }
  }
}

/// Deterministic application configuration artifacts.
class ConfigArtifacts {
  /// Creates the generated Dart, JSON Schema and Markdown documents.
  const ConfigArtifacts(this.model, this.schema, this.documentation);

  /// Dart library containing AppConfig and its typed setting handles.
  final String model;

  /// Scope-specific JSON Schema document.
  final String schema;

  /// Developer-facing settings reference.
  final String documentation;
}

/// Analyzes only the supplied source libraries, without executing application code.
Future<ConfigArtifacts?> generateConfigArtifacts(
  Iterable<LibraryElement> libraries,
  RouteAstResolver resolver, {
  String? schemaUri,
}) async {
  final models = <String, ClassElement>{};
  for (final library in libraries) {
    for (final model in library.classes) {
      final annotation = _annotation(model, 'Config');
      if (annotation == null) continue;
      final scope = annotation
          .getField('scope')!
          .getField('_name')!
          .toStringValue()!;
      if (models.containsKey(scope)) {
        _fail(
          'Only one $scope config model is allowed; also found ${models[scope]!.name}.',
          model,
        );
      }
      if (model.name == 'AppConfig') {
        _fail('AppConfig is reserved for generated configuration.', model);
      }
      models[scope] = model;
    }
  }
  if (models.isEmpty) return null;
  if (!models.containsKey('global')) {
    _fail('Declare one global model with @config.', models.values.first);
  }
  return _ConfigEmitter(resolver, models, schemaUri).generate();
}

Never _fail(String message, Element element) =>
    throw InvalidGenerationSourceError(message, element: element);

DartObject? _annotation(Element element, String name) {
  for (final item in element.metadata.annotations) {
    final value = item.computeConstantValue();
    final type = value?.type;
    if (type is InterfaceType &&
        type.element.name == name &&
        type.element.library.uri.toString().startsWith(
          'package:grumpy_annotations/',
        )) {
      return value;
    }
  }
  return null;
}

Object? _jsonConstant(DartObject value) {
  if (value.isNull) return null;
  if (value.toBoolValue() case final bool v) return v;
  if (value.toIntValue() case final int v) return v;
  if (value.toDoubleValue() case final double v) return v;
  if (value.toStringValue() case final String v) return v;
  if (value.toListValue() case final List<DartObject> values) {
    return values.map(_jsonConstant).toList();
  }
  if (value.toMapValue() case final Map<DartObject?, DartObject?> values) {
    return {
      for (final e in values.entries)
        e.key!.toStringValue()!: _jsonConstant(e.value!),
    };
  }
  if (value.type case InterfaceType(element: EnumElement())) {
    return value.getField('_name')!.toStringValue();
  }
  if (value.type case InterfaceType(:final element)) {
    if (element.name == 'IoPath') {
      return value.getField('value')!.toStringValue();
    }
    final fields = element.fields.where(
      (field) => !field.isStatic && field.isPublic && field.isOriginDeclaration,
    );
    if (fields.isNotEmpty) {
      return {
        for (final field in fields)
          field.name!: _jsonConstant(value.getField(field.name!)!),
      };
    }
  }
  throw const FormatException('Expected a serializable constant.');
}

String _literal(Object? value) {
  if (value is Map) {
    return '{${value.entries.map((e) => '${_literal(e.key)}: ${_literal(e.value)}').join(', ')}}';
  }
  if (value is List) return '[${value.map(_literal).join(', ')}]';
  return jsonEncode(value).replaceAll(r'$', r'\$');
}

void _validateValue(
  Object? value,
  Map<String, Object?> schema,
  String property,
) {
  if (schema['anyOf'] case final List alternatives) {
    for (final alternative in alternatives) {
      try {
        _validateValue(
          value,
          Map<String, Object?>.from(alternative as Map),
          property,
        );
        return;
      } on FormatException {
        /* Try the next declared type. */
      }
    }
    throw FormatException('Invalid default or example for $property.');
  }
  final validType = switch (schema['type']) {
    'null' => value == null,
    'string' => value is String,
    'boolean' => value is bool,
    'integer' => value is int,
    'number' => value is num,
    'array' => value is List,
    'object' => value is Map,
    _ => true,
  };
  if (!validType) {
    throw FormatException(
      'Default or example for $property has the wrong type.',
    );
  }
  if (schema['enum'] case final List choices) {
    if (!choices.any((choice) => jsonEncode(choice) == jsonEncode(value))) {
      throw FormatException(
        'Default or example for $property is not an allowed choice.',
      );
    }
  }
  if (value is num) {
    if ((schema['minimum'] is num && value < (schema['minimum'] as num)) ||
        (schema['maximum'] is num && value > (schema['maximum'] as num))) {
      throw FormatException(
        'Default or example for $property is outside its range.',
      );
    }
  }
  if (value is String &&
      schema['pattern'] is String &&
      !RegExp(schema['pattern'] as String).hasMatch(value)) {
    throw FormatException(
      'Default or example for $property does not match its pattern.',
    );
  }
  final length = value is String
      ? value.runes.length
      : value is List
      ? value.length
      : value is Map
      ? value.length
      : null;
  final suffix = value is String
      ? 'Length'
      : value is List
      ? 'Items'
      : 'Properties';
  if (length != null &&
      ((schema['min$suffix'] is int &&
              length < (schema['min$suffix'] as int)) ||
          (schema['max$suffix'] is int &&
              length > (schema['max$suffix'] as int)))) {
    throw FormatException(
      'Default or example for $property has an invalid length.',
    );
  }
  if (value is List && schema['items'] is Map) {
    for (final item in value) {
      _validateValue(
        item,
        Map<String, Object?>.from(schema['items'] as Map),
        property,
      );
    }
  }
  if (value is Map && schema['properties'] is Map) {
    final properties = schema['properties'] as Map;
    for (final entry in value.entries) {
      if (!properties.containsKey(entry.key)) {
        throw FormatException(
          'Unknown default property $property.${entry.key}.',
        );
      }
      _validateValue(
        entry.value,
        Map<String, Object?>.from(properties[entry.key] as Map),
        '$property.${entry.key}',
      );
    }
  }
}

class _Property {
  _Property(
    this.name,
    this.type,
    this.codec,
    this.schema,
    this.description,
    this.defaultValue,
    this.nullable,
  );
  final String name, type, codec, description;
  final Map<String, Object?> schema;
  final Object? defaultValue;
  final bool nullable;
}

class _ConfigEmitter {
  _ConfigEmitter(this.resolver, this.models, this.schemaUri);
  final RouteAstResolver resolver;
  final Map<String, ClassElement> models;
  final String? schemaUri;
  final imports = <String, String>{};
  final visiting = <InterfaceElement>{};

  String symbol(Element element) {
    final library = element.library!;
    if (library.uri.toString() == 'dart:core') return element.name!;
    final uri = library.uri.toString().startsWith('package:grumpy_io/')
        ? 'package:grumpy_io/grumpy_io.dart'
        : library.uri.toString();
    final prefix = imports.putIfAbsent(uri, () => '_c${imports.length}');
    return '$prefix.${element.name}';
  }

  String typeName(DartType type) {
    if (type is! InterfaceType) {
      throw FormatException('Unsupported config type $type.');
    }
    final args = type.typeArguments.isEmpty
        ? ''
        : '<${type.typeArguments.map(typeName).join(', ')}>';
    return '${symbol(type.element)}$args${type.nullabilitySuffix == NullabilitySuffix.question ? '?' : ''}';
  }

  String function(DartObject value) {
    final element = value.toFunctionValue();
    if (element == null) {
      throw const FormatException('Expected a static function tear-off.');
    }
    final enclosing = element.enclosingElement;
    return enclosing is InterfaceElement
        ? '${symbol(enclosing)}.${element.name}'
        : symbol(element);
  }

  Future<Object?> expression(Expression node) async {
    if (node is NullLiteral) return null;
    if (node is BooleanLiteral) return node.value;
    if (node is IntegerLiteral) return node.value;
    if (node is DoubleLiteral) return node.value;
    if (node is SimpleStringLiteral) return node.value;
    if (node is ParenthesizedExpression) return expression(node.expression);
    if (node is PrefixExpression && node.operator.lexeme == '-') {
      return -(await expression(node.operand) as num);
    }
    if (node is ListLiteral) {
      final result = <Object?>[];
      for (final item in node.elements) {
        if (item is! Expression) {
          throw const FormatException(
            'Collection control flow is not a static default.',
          );
        }
        result.add(await expression(item));
      }
      return result;
    }
    if (node is SetOrMapLiteral && node.isMap) {
      final result = <String, Object?>{};
      for (final item in node.elements) {
        if (item is! MapLiteralEntry) {
          throw const FormatException(
            'Use explicit map entries for config defaults.',
          );
        }
        result[await expression(item.key) as String] = await expression(
          item.value,
        );
      }
      return result;
    }
    if (node is InstanceCreationExpression) {
      final constructor = node.constructorName.element;
      if (constructor == null || !constructor.isConst) {
        throw const FormatException(
          'Object defaults must use const constructors.',
        );
      }
      final values = <String, Object?>{};
      var index = 0;
      for (final argument in node.argumentList.arguments) {
        if (argument is NamedExpression) {
          values[argument.name.label.name] = await expression(
            argument.expression,
          );
        } else {
          values[constructor.formalParameters[index++].name!] =
              await expression(argument);
        }
      }
      for (final parameter in constructor.formalParameters) {
        if (!values.containsKey(parameter.name) && parameter.hasDefaultValue) {
          values[parameter.name!] = _jsonConstant(
            parameter.computeConstantValue()!,
          );
        }
      }
      return constructor.enclosingElement.name == 'IoPath'
          ? values['value']
          : values;
    }
    if (node is BinaryExpression) {
      final left = await expression(node.leftOperand),
          right = await expression(node.rightOperand);
      if (node.operator.lexeme == '+' && left is String && right is String) {
        return left + right;
      }
      if (left is num && right is num) {
        return switch (node.operator.lexeme) {
          '+' => left + right,
          '-' => left - right,
          '*' => left * right,
          '/' => left / right,
          '~/' => left ~/ right,
          '%' => left % right,
          _ => throw const FormatException('Unsupported default expression.'),
        };
      }
    }
    Element? element;
    if (node is SimpleIdentifier) element = node.element;
    if (node is PrefixedIdentifier) element = node.element;
    if (node is PropertyAccess) element = node.propertyName.element;
    if (element is PropertyAccessorElement) element = element.variable;
    if (element is VariableElement) {
      final value = element.computeConstantValue();
      if (value != null) return _jsonConstant(value);
    }
    throw FormatException(
      'Default must be statically evaluable: ${node.toSource()}',
    );
  }

  Future<(bool, Object?)> defaultFor(GetterElement getter) async {
    final field = getter.variable;
    final node = await resolver.astNodeFor(field.firstFragment);
    if (node is VariableDeclaration && node.initializer != null) {
      return (true, await expression(node.initializer!));
    }
    final getterNode = await resolver.astNodeFor(getter.firstFragment);
    if (getterNode is MethodDeclaration) {
      final body = getterNode.body;
      if (body is ExpressionFunctionBody) {
        return (true, await expression(body.expression));
      }
      if (body is BlockFunctionBody &&
          body.block.statements.length == 1 &&
          body.block.statements.single is ReturnStatement) {
        return (
          true,
          await expression(
            (body.block.statements.single as ReturnStatement).expression!,
          ),
        );
      }
      if (body is! EmptyFunctionBody) {
        throw const FormatException(
          'Config getters must have static defaults.',
        );
      }
    }
    final enclosing = field.enclosingElement;
    if (enclosing is ClassElement) {
      Object? found;
      var hasDefault = false;
      for (final constructor in enclosing.constructors.where(
        (c) => !c.isFactory,
      )) {
        for (final parameter in constructor.formalParameters) {
          if (parameter is FieldFormalParameterElement &&
              parameter.field == field &&
              parameter.hasDefaultValue) {
            final value = _jsonConstant(parameter.computeConstantValue()!);
            if (hasDefault && jsonEncode(found) != jsonEncode(value)) {
              throw const FormatException(
                'Constructors declare conflicting setting defaults.',
              );
            }
            found = value;
            hasDefault = true;
          }
        }
      }
      if (hasDefault) return (true, found);
    }
    return (false, null);
  }

  Future<List<_Property>> properties(InterfaceType model) async {
    final getters = <String, GetterElement>{};
    // Dart lookup applies inherited overrides and substitutes generic arguments.
    final names = <String>{
      for (final type in [model, ...model.allSupertypes])
        for (final getter in type.getters)
          if (!getter.isStatic &&
              getter.isPublic &&
              getter.name != 'hashCode' &&
              getter.name != 'runtimeType')
            getter.name!,
    };
    for (final name in names) {
      final getter = model.lookUpGetter(name, model.element.library);
      if (getter != null) getters[name] = getter;
    }
    final result = <_Property>[];
    for (final entry
        in getters.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      final getter = entry.value;
      try {
        if (getter.variable is FieldElement &&
            !(getter.variable as FieldElement).isFinal &&
            !getter.isOriginDeclaration) {
          _fail('Config properties must be immutable.', getter);
        }
        final metadata =
            _annotation(getter.variable, 'ConfigField') ??
            _annotation(getter, 'ConfigField');
        final (codec, schema) = await valueType(getter.returnType, metadata);
        final (hasDefault, defaultValue) = await defaultFor(getter);
        final nullable =
            getter.returnType.nullabilitySuffix == NullabilitySuffix.question;
        if (!hasDefault && !nullable) {
          _fail(
            'Setting ${entry.key} must be nullable or have a default.',
            getter,
          );
        }
        final doc =
            getter.documentationComment ??
            getter.variable.documentationComment ??
            '';
        final description = doc
            .split('\n')
            .map((line) => line.replaceFirst(RegExp(r'^\s*/// ?'), '').trim())
            .join('\n')
            .trim();
        final deprecated =
            getter.metadata.annotations.any(
              (a) =>
                  a.computeConstantValue()?.type?.getDisplayString() ==
                  'Deprecated',
            ) ||
            getter.variable.metadata.annotations.any(
              (a) =>
                  a.computeConstantValue()?.type?.getDisplayString() ==
                  'Deprecated',
            );
        final examples =
            metadata
                ?.getField('examples')
                ?.toListValue()
                ?.map(_jsonConstant)
                .toList() ??
            [];
        _validateValue(defaultValue, schema, entry.key);
        for (final example in examples) {
          _validateValue(example, schema, entry.key);
        }
        result.add(
          _Property(
            entry.key,
            typeName(getter.returnType),
            codec,
            {
              ...schema,
              'description': description,
              if (hasDefault || nullable) 'default': defaultValue,
              if (examples.isNotEmpty) 'examples': examples,
              if (deprecated) 'deprecated': true,
              'x-runtime-validation': ?metadata
                  ?.getField('runtimeValidationDescription')
                  ?.toStringValue(),
            },
            description,
            defaultValue,
            nullable,
          ),
        );
      } on FormatException catch (e) {
        _fail(e.message, getter);
      }
    }
    return result;
  }

  Future<(String, Map<String, Object?>)> valueType(
    DartType type,
    DartObject? metadata,
  ) async {
    if (type is! InterfaceType) {
      throw FormatException('Unsupported config type $type.');
    }
    final nullable = type.nullabilitySuffix == NullabilitySuffix.question;
    final name = type.element.name;
    String codec;
    Map<String, Object?> schema;
    final custom = metadata?.getField('valueType');
    if (custom != null && !custom.isNull) {
      final customSchema = metadata!.getField('schema');
      if (customSchema == null || customSchema.isNull) {
        throw const FormatException(
          'Custom valueType requires a static schema.',
        );
      }
      codec = '${function(custom)}()';
      schema = Map<String, Object?>.from(_jsonConstant(customSchema) as Map);
    } else if (type.element is EnumElement) {
      final values = (type.element as EnumElement).fields
          .where((f) => f.isEnumConstant)
          .map((f) => f.name)
          .toList();
      codec = 'CliValueType.enumeration(${symbol(type.element)}.values)';
      schema = {'type': 'string', 'enum': values};
    } else {
      switch (name) {
        case 'String':
          codec = 'CliValueType.string()';
          schema = {'type': 'string'};
        case 'bool':
          codec = 'CliValueType.boolean()';
          schema = {'type': 'boolean'};
        case 'int':
          codec = 'CliValueType.integer()';
          schema = {'type': 'integer'};
        case 'double':
          codec = 'CliValueType.decimal()';
          schema = {'type': 'number'};
        case 'Uri':
          codec = 'CliValueType.uri()';
          schema = {'type': 'string', 'format': 'uri-reference'};
        case 'IoPath':
          codec = 'CliValueType.ioPath()';
          schema = {'type': 'string', 'minLength': 1};
        case 'List':
          final (child, childSchema) = await valueType(
            type.typeArguments.single,
            null,
          );
          codec = 'CliValueType.list($child)';
          schema = {'type': 'array', 'items': childSchema};
        case 'Map':
          if (!type.typeArguments.first.isDartCoreString) {
            throw const FormatException('Config maps require String keys.');
          }
          final (child, childSchema) = await valueType(
            type.typeArguments.last,
            null,
          );
          codec = 'CliValueType.map($child)';
          schema = {'type': 'object', 'additionalProperties': childSchema};
        default:
          if (!visiting.add(type.element)) {
            throw const FormatException(
              'Recursive configuration objects require a custom codec.',
            );
          }
          final fields = await properties(type);
          visiting.remove(type.element);
          final constructor = type.element.constructors
              .where((c) => c.name == 'new')
              .firstOrNull;
          if (constructor == null ||
              constructor.formalParameters.any((p) => !p.isNamed) ||
              fields.any(
                (f) =>
                    !constructor.formalParameters.any((p) => p.name == f.name),
              )) {
            throw const FormatException(
              'Structured config objects need an unnamed constructor with named property parameters, or a custom codec.',
            );
          }
          codec =
              'CliValueType.object<${typeName(type).replaceFirst(RegExp(r'\?$'), '')}>(properties: {'
              '${fields.map((f) => '${_literal(f.name)}: ${f.codec}').join(', ')}}, '
              'fromJson: (json) => ${symbol(type.element)}('
              '${fields.map((f) => '${f.name}: ${f.codec}.decode(json.containsKey(${_literal(f.name)}) ? json[${_literal(f.name)}] : ${_literal(f.defaultValue)})').join(', ')}), '
              'toJson: (value) => {${fields.map((f) => '${_literal(f.name)}: ${f.codec}.encode(value.${f.name})').join(', ')}})';
          schema = {
            'type': 'object',
            'properties': {for (final f in fields) f.name: f.schema},
            'additionalProperties': false,
          };
          codec =
              '$codec.constrained(${_literal({'properties': schema['properties']})})';
      }
    }
    final extra = <String, Object?>{};
    for (final entry in {
      'min': 'minimum',
      'max': 'maximum',
      'pattern': 'pattern',
      'choices': 'enum',
    }.entries) {
      final value = metadata?.getField(entry.key);
      if (value != null && !value.isNull) {
        extra[entry.value] = _jsonConstant(value);
      }
    }
    for (final prefix in ['min', 'max']) {
      final value = metadata?.getField('${prefix}Length');
      if (value != null && !value.isNull) {
        extra['$prefix${schema['type'] == 'array'
            ? 'Items'
            : schema['type'] == 'object'
            ? 'Properties'
            : 'Length'}'] = _jsonConstant(
          value,
        );
      }
    }
    final minimum = extra['minimum'] as num?,
        maximum = extra['maximum'] as num?;
    if (minimum != null && maximum != null && minimum > maximum) {
      throw const FormatException('Minimum must not exceed maximum.');
    }
    final minLength = metadata?.getField('minLength')?.toIntValue();
    final maxLength = metadata?.getField('maxLength')?.toIntValue();
    if ((minLength != null && minLength < 0) ||
        (maxLength != null && maxLength < (minLength ?? 0))) {
      throw const FormatException('Invalid length bounds.');
    }
    if (extra['pattern'] case final String pattern) RegExp(pattern);
    final runtimeDescription = metadata
        ?.getField('runtimeValidationDescription')
        ?.toStringValue();
    final validator = metadata?.getField('validate');
    if (validator != null && !validator.isNull && runtimeDescription == null) {
      throw const FormatException(
        'Runtime validators require runtimeValidationDescription.',
      );
    }
    if (extra.isNotEmpty ||
        runtimeDescription != null ||
        (validator != null && !validator.isNull)) {
      codec =
          '$codec.constrained(${_literal(extra)}'
          '${validator != null && !validator.isNull ? ', validator: ${function(validator)}' : ''}'
          '${runtimeDescription != null ? ', runtimeDescription: ${_literal(runtimeDescription)}' : ''})';
    }
    schema = {...schema, ...extra};
    if (nullable) {
      codec = '$codec.nullable()';
      schema = {
        'anyOf': [
          schema,
          {'type': 'null'},
        ],
      };
    }
    return (codec, schema);
  }

  Future<ConfigArtifacts> generate() async {
    final global = await properties(models['global']!.thisType);
    final local = models['local'] == null
        ? <_Property>[]
        : await properties(models['local']!.thisType);
    final globalNames = global.map((f) => f.name).toSet();
    for (final field in local) {
      if (globalNames.contains(field.name)) {
        _fail(
          'Duplicate config property ${field.name} in global and local models.',
          models['local']!,
        );
      }
    }
    final fields = [...global, ...local]
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final field in fields) {
      if ([
        'settings',
        'defaults',
        'configSchema',
        'resolveConfig',
        r'$schema',
      ].contains(field.name)) {
        _fail(
          'Property ${field.name} is reserved by generated configuration.',
          models.values.first,
        );
      }
    }
    final modelTypes = models.values.map(symbol).join(', ');
    final out = StringBuffer('// GENERATED CODE - DO NOT MODIFY BY HAND.\n\n');
    out.writeln("import 'package:grumpy_cli/grumpy_cli.dart';");
    for (final entry in imports.entries) {
      out.writeln('import ${_literal(entry.key)} as ${entry.value};');
    }
    out.writeln('''
/// Immutable configuration resolved for the current application invocation.
final class AppConfig extends CliConfig<AppConfig> implements $modelTypes {
  AppConfig._({${fields.map((f) => 'required this.${f.name}').join(', ')}});

  /// Resolves the configuration registered by your root module.
  factory AppConfig() => RootModule.getConfig<AppConfig>();

  /// Creates a snapshot using the defaults declared by your config models.
  factory AppConfig.defaults() => AppConfig._(
    ${fields.map((f) => '${f.name}: settings.${f.name}.defaultValue as ${f.type}').join(',\n    ')}
  );

  /// Typed handles for explicit scope writes, provenance and shared value types.
  static final settings = AppConfigSettings();
''');
    for (final field in fields) {
      out.writeln(
        '  /// ${field.description.replaceAll('\n', '\n  /// ')}\n  @override\n  final ${field.type} ${field.name};',
      );
    }
    out.writeln('''
  @override
  ConfigSchema get configSchema => _schema;
  static final _schema = ConfigSchema(
    global: [${global.map((f) => 'settings.${f.name}').join(', ')}],
    local: [${local.map((f) => 'settings.${f.name}').join(', ')}],
    schemaUri: ${schemaUri == null ? 'null' : 'Uri.parse(${_literal(schemaUri)})'},
  );

  @override
  AppConfig resolveConfig(ConfigService service) => AppConfig._(
    ${fields.map((f) => '${f.name}: service.get(settings.${f.name}) as ${f.type}').join(',\n    ')}
  );
}

/// Generated typed setting declarations; use AppConfig.settings.
final class AppConfigSettings extends Model {
  /// Creates the generated settings collection.
  AppConfigSettings();
''');
    for (final field in fields) {
      out.writeln('''
  /// ${field.description.replaceAll('\n', '\n  /// ')}
  final ${field.name} = ConfigSetting<${field.type}>(
    ${_literal(field.name)}, type: ${field.codec},
    description: ${_literal(field.description)},
    defaultValue: ${field.codec}.decode(${_literal(field.defaultValue)}),
    examples: [${(field.schema['examples'] as List? ?? []).map((e) => '${field.codec}.decode(${_literal(e)})').join(', ')}],
    hasDefault: true,
    deprecated: ${field.schema['deprecated'] == true},
  );''');
    }
    out.writeln('}');
    Map<String, Object?> scope(List<_Property> values) => {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        r'$schema': {
          'type': 'string',
          'description': 'Editor schema reference.',
        },
        for (final f
            in values.toList()..sort((a, b) => a.name.compareTo(b.name)))
          f.name: f.schema,
      },
    };
    final schema = {
      r'$schema': 'https://json-schema.org/draft/2020-12/schema',
      if (schemaUri != null && Uri.parse(schemaUri!).isAbsolute)
        r'$id': schemaUri,
      'title': 'CLI configuration',
      r'$defs': {'global': scope(global), 'local': scope(fields)},
      'anyOf': [
        {r'$ref': r'#/$defs/global'},
        {r'$ref': r'#/$defs/local'},
      ],
    };
    final docs = StringBuffer(
      '# Configuration\n\nLocal values override global values. Declared defaults apply last.\n',
    );
    String cell(Object? value) =>
        '$value'.replaceAll('|', r'\|').replaceAll('\n', ' ');
    for (final entry in {'Global': global, 'Local': fields}.entries) {
      docs.writeln(
        '\n## ${entry.key}\n\n| Setting | Description | Default | Constraints |\n| --- | --- | --- | --- |',
      );
      for (final field in entry.value) {
        docs.writeln(
          '| `${field.name}` | ${cell(field.description)} | `${cell(jsonEncode(field.defaultValue))}` | `${cell(jsonEncode(field.schema))}` |',
        );
      }
    }
    return ConfigArtifacts(
      DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
      ).format(out.toString()),
      '${const JsonEncoder.withIndent('  ').convert(schema)}\n',
      docs.toString(),
    );
  }
}
