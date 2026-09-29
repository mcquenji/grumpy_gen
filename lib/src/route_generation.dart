import 'dart:async';
import 'dart:collection';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

abstract interface class RouteAstResolver {
  Future<AstNode?> astNodeFor(Fragment fragment);
}

final class BuildStepRouteAstResolver implements RouteAstResolver {
  BuildStepRouteAstResolver(this._resolver);

  final Resolver _resolver;

  @override
  Future<AstNode?> astNodeFor(Fragment fragment) =>
      _resolver.astNodeFor(fragment, resolve: true);
}

enum RouteNodeKind { namespace, leaf, parameter, moduleBoundary }

final class RouteGenerationSpec {
  RouteGenerationSpec({
    required this.rootClass,
    required this.isFlutterRoot,
    required this.rootNode,
  });

  final ClassElement rootClass;
  final bool isFlutterRoot;
  final RoutePathNode rootNode;
}

final class RoutePathNode {
  RoutePathNode({
    required this.fullPathPattern,
    required this.memberName,
    required this.classNamePart,
    required this.kind,
    required this.segment,
    required this.pathLiteral,
  });

  final String fullPathPattern;
  final String memberName;
  final String classNamePart;
  final RouteNodeKind kind;
  final String segment;
  final String pathLiteral;

  bool isNavigable = false;
  bool isModuleBoundary = false;
  bool hasModuleRoot = false;
  bool isLeaf = false;
  bool isDeclaredParameter = false;

  final LinkedHashMap<String, RoutePathNode> children =
      LinkedHashMap<String, RoutePathNode>();

  bool get hasChildren => children.isNotEmpty;

  bool get requiresObjectNode =>
      hasChildren || isModuleBoundary || kind == RouteNodeKind.parameter;
}

sealed class ParsedRoute {
  const ParsedRoute(this.path);

  final String path;
}

final class ParsedShellRoute extends ParsedRoute {
  const ParsedShellRoute({required this.children}) : super('');

  final List<ParsedRoute> children;
}

final class ParsedLeafRoute extends ParsedRoute {
  const ParsedLeafRoute({
    required String path,
    required this.children,
    required this.routeTypeName,
  }) : super(path);

  final List<ParsedRoute> children;
  final String routeTypeName;
}

final class ParsedModuleRoute extends ParsedRoute {
  const ParsedModuleRoute({
    required String path,
    required this.moduleClass,
    required this.moduleRoutes,
    required this.explicitRoot,
  }) : super(path);

  final ClassElement moduleClass;
  final List<ParsedRoute> moduleRoutes;
  final ParsedLeafRoute? explicitRoot;
}

final class _ParsedModuleSpec {
  const _ParsedModuleSpec({required this.classElement, required this.routes});

  final ClassElement classElement;
  final List<ParsedRoute> routes;

  bool get hasDeclaredRoot =>
      routes.any((route) => route is ParsedLeafRoute && route.path == '/');
}

Future<RouteGenerationSpec?> analyzeRouteLibrary(
  LibraryReader library,
  RouteAstResolver resolver,
) async {
  if (library.classes.any(
    (element) => element.allSupertypes.any(
      (type) =>
          type.element.name == 'CliApp' &&
          type.element.library.uri.toString().startsWith('package:grumpy_cli/'),
    ),
  )) {
    return null;
  }
  final rootClasses = library.classes
      .where((element) => !element.isAbstract && _isRootModule(element))
      .toList(growable: false);

  if (rootClasses.isEmpty) {
    return null;
  }

  if (rootClasses.length > 1) {
    throw InvalidGenerationSource(
      'Expected exactly one concrete RootModule per library, found '
      '${rootClasses.length}.',
      element: rootClasses.first,
    );
  }

  if (library.classes.any((element) => element.name == 'GrumpyRoutes')) {
    throw InvalidGenerationSource(
      'Cannot generate GrumpyRoutes because the library already declares '
      'a type with that name.',
      element: rootClasses.first,
    );
  }

  final rootClass = rootClasses.single;
  final moduleResolver = _ModuleRouteResolver(astResolver: resolver);
  final rootSpec = await moduleResolver.parseModule(rootClass);
  final rootNode = _buildPathTree(rootSpec.routes);

  return RouteGenerationSpec(
    rootClass: rootClass,
    isFlutterRoot: _isAppModule(rootClass),
    rootNode: rootNode,
  );
}

String emitGenericRoutes(RouteGenerationSpec spec) {
  final emitter = _GenericRoutesEmitter(spec);
  return emitter.emit();
}

String emitFlutterRoutes(RouteGenerationSpec spec) {
  if (!spec.isFlutterRoot) {
    return '';
  }

  final emitter = _FlutterRoutesEmitter(spec);
  return emitter.emit();
}

bool _isRootModule(ClassElement element) => _hasSupertypeNamed(
  element,
  typeName: 'RootModule',
  packagePrefix: 'package:grumpy/',
  testStubPathFragments: const [
    '/test/stubs/grumpy/lib/',
    '/test/stubs/grumpy_flutter/lib/',
  ],
);

bool _isAppModule(ClassElement element) => _hasSupertypeNamed(
  element,
  typeName: 'AppModule',
  packagePrefix: 'package:grumpy_flutter/',
  testStubPathFragments: const ['/test/stubs/grumpy_flutter/lib/'],
);

bool _hasSupertypeNamed(
  ClassElement element, {
  required String typeName,
  required String packagePrefix,
  required List<String> testStubPathFragments,
}) {
  return element.allSupertypes.any((type) {
    final source = type.element.library.firstFragment.source.uri.toString();
    return type.element.name == typeName &&
        (source.startsWith(packagePrefix) ||
            testStubPathFragments.any(source.contains));
  });
}

final class _ModuleRouteResolver {
  _ModuleRouteResolver({required RouteAstResolver astResolver})
    : _astResolver = astResolver;

  final RouteAstResolver _astResolver;
  final Map<ClassElement, Future<_ParsedModuleSpec>> _cache =
      <ClassElement, Future<_ParsedModuleSpec>>{};
  final Set<ClassElement> _active = <ClassElement>{};

  Future<_ParsedModuleSpec> parseModule(ClassElement classElement) {
    return _cache.putIfAbsent(
      classElement,
      () => _parseModuleInternal(classElement),
    );
  }

  Future<_ParsedModuleSpec> _parseModuleInternal(
    ClassElement classElement,
  ) async {
    if (!_active.add(classElement)) {
      throw InvalidGenerationSource(
        'Detected a recursive module routing cycle involving ${classElement.name}.',
        element: classElement,
      );
    }

    try {
      final classDeclaration =
          await _resolveClassDeclaration(classElement) ??
          (throw InvalidGenerationSource(
            'Could not resolve the AST for ${classElement.name}.',
            element: classElement,
          ));

      final routeElements = await _resolveRouteCollection(
        classElement: classElement,
        classDeclaration: classDeclaration,
      );
      final routes = <ParsedRoute>[];

      for (final element in routeElements) {
        routes.add(await _parseRouteElement(element, classElement));
      }

      return _ParsedModuleSpec(classElement: classElement, routes: routes);
    } finally {
      _active.remove(classElement);
    }
  }

  Future<ClassDeclaration?> _resolveClassDeclaration(
    ClassElement classElement,
  ) async {
    final node = await _astResolver.astNodeFor(classElement.firstFragment);
    return node?.thisOrAncestorOfType<ClassDeclaration>();
  }

  Future<List<CollectionElement>> _resolveRouteCollection({
    required ClassElement classElement,
    required ClassDeclaration classDeclaration,
  }) async {
    final rootExpression = _findGetterExpression(classDeclaration, 'root');
    if (rootExpression != null) {
      final elements = _extractRouteListFromRootExpression(
        rootExpression,
        classDeclaration,
      );
      if (elements != null) {
        return elements;
      }
    }

    final routesExpression = _findRoutesExpression(classDeclaration);
    if (routesExpression == null) {
      throw InvalidGenerationSource(
        'Expected ${classElement.name} to declare a statically analyzable '
        '`routes` getter/field or `root` getter.',
        element: classElement,
      );
    }

    final elements = _extractRouteListExpression(
      routesExpression,
      classDeclaration,
      '`routes` on ${classElement.name}',
    );

    return elements;
  }

  Future<ParsedRoute> _parseRouteElement(
    CollectionElement element,
    ClassElement owner,
  ) async {
    if (element case SpreadElement() || IfElement() || ForElement()) {
      throw InvalidGenerationSource(
        'Only direct route literals are supported. '
        'Spread/if/for elements are not supported in routes yet.',
        element: owner,
        node: element,
      );
    }

    if (element is! Expression) {
      throw InvalidGenerationSource(
        'Unsupported route collection element `${element.runtimeType}`.',
        element: owner,
        node: element,
      );
    }

    return _parseRouteExpression(element, owner);
  }

  Future<ParsedRoute> _parseRouteExpression(
    Expression expression,
    ClassElement owner,
  ) async {
    expression = _unwrapExpression(expression);

    if (expression is! InstanceCreationExpression) {
      throw InvalidGenerationSource(
        'Routes must be declared with direct constructor calls. '
        'Found `${expression.toSource()}` instead.',
        element: owner,
        node: expression,
      );
    }

    final typeName = _instanceTypeName(expression);
    switch (typeName) {
      case 'ShellScreenRoute':
        return ParsedShellRoute(
          children: await _parseChildrenArgument(expression, owner),
        );
      case 'LeafRoute':
      case 'ScreenRoute':
        return ParsedLeafRoute(
          path: _extractRoutePath(expression, owner),
          children: await _parseChildrenArgument(expression, owner),
          routeTypeName: typeName,
        );
      case 'ModuleRoute':
        final moduleExpression =
            _namedArgument(expression.argumentList, 'module') ??
            (throw InvalidGenerationSource(
              'ModuleRoute requires a `module:` argument.',
              element: owner,
              node: expression,
            ));
        final moduleClass =
            _extractConstructedClass(moduleExpression) ??
            (throw InvalidGenerationSource(
              'ModuleRoute.module must be a direct module constructor call.',
              element: owner,
              node: moduleExpression,
            ));
        final explicitRootExpression = _namedArgument(
          expression.argumentList,
          'root',
        );
        ParsedLeafRoute? explicitRoot;
        if (explicitRootExpression != null) {
          final parsed = await _parseRouteExpression(
            explicitRootExpression,
            owner,
          );
          if (parsed is! ParsedLeafRoute) {
            throw InvalidGenerationSource(
              'ModuleRoute.root must be a LeafRoute/ScreenRoute.',
              element: owner,
              node: explicitRootExpression,
            );
          }
          explicitRoot = parsed;
        }

        final moduleSpec = await parseModule(moduleClass);
        return ParsedModuleRoute(
          path: _extractRoutePath(expression, owner),
          moduleClass: moduleClass,
          moduleRoutes: moduleSpec.routes,
          explicitRoot: explicitRoot,
        );
      default:
        throw InvalidGenerationSource(
          'Unsupported route type `$typeName`. '
          'Only LeafRoute, ScreenRoute, ModuleRoute, ShellScreenRoute, and '
          'Route.root are supported.',
          element: owner,
          node: expression,
        );
    }
  }

  Future<List<ParsedRoute>> _parseChildrenArgument(
    InstanceCreationExpression expression,
    ClassElement owner,
  ) async {
    final childrenExpression = _namedArgument(
      expression.argumentList,
      'children',
    );
    if (childrenExpression == null) {
      return const <ParsedRoute>[];
    }

    final elements = _extractRouteListExpression(
      childrenExpression,
      null,
      '`children` on ${owner.name}',
    );
    final children = <ParsedRoute>[];
    for (final element in elements) {
      children.add(await _parseRouteElement(element, owner));
    }
    return children;
  }
}

RoutePathNode _buildPathTree(List<ParsedRoute> routes) {
  final root = RoutePathNode(
    fullPathPattern: '/',
    memberName: '',
    classNamePart: 'Root',
    kind: RouteNodeKind.namespace,
    segment: '',
    pathLiteral: '/',
  );

  for (final route in routes) {
    _mergeParsedRoute(root, route);
  }

  return root;
}

void _mergeParsedRoute(RoutePathNode parent, ParsedRoute route) {
  switch (route) {
    case ParsedShellRoute():
      for (final child in route.children) {
        _mergeParsedRoute(parent, child);
      }
    case ParsedLeafRoute():
      final node = _descendPath(parent, route.path);
      node.isNavigable = true;
      node.isLeaf = true;
      for (final child in route.children) {
        _mergeParsedRoute(node, child);
      }
    case ParsedModuleRoute():
      final node = _descendPath(parent, route.path);
      node.isModuleBoundary = true;
      if (route.explicitRoot case final explicitRoot?) {
        _mergeParsedRoute(node, explicitRoot);
      }
      for (final child in route.moduleRoutes) {
        _mergeParsedRoute(node, child);
      }
      if (node.isNavigable) {
        node.hasModuleRoot = true;
      }
  }
}

RoutePathNode _descendPath(RoutePathNode parent, String path) {
  final segments = _splitRoutePath(path);
  if (segments.isEmpty) {
    return parent;
  }

  var current = parent;
  for (final segment in segments) {
    final isParameter = segment.startsWith(':');
    final memberName = _memberNameForSegment(segment, isParameter: isParameter);
    final key = '${isParameter ? 'param' : 'static'}:$memberName';
    final nextPath = _joinPaths(current.fullPathPattern, segment);
    final nextLiteral = isParameter
        ? current.pathLiteral
        : _joinPaths(current.pathLiteral, segment);
    final child = current.children.putIfAbsent(
      key,
      () => RoutePathNode(
        fullPathPattern: nextPath,
        memberName: memberName,
        classNamePart: _classNamePartForSegment(
          segment,
          isParameter: isParameter,
        ),
        kind: isParameter ? RouteNodeKind.parameter : RouteNodeKind.namespace,
        segment: segment,
        pathLiteral: nextLiteral,
      ),
    );

    if (child.segment != segment) {
      throw InvalidGenerationSource(
        'Route member collision for `${child.fullPathPattern}` and '
        '`$nextPath`. Adjust one of the conflicting segment names.',
      );
    }

    child.isDeclaredParameter = isParameter;
    current = child;
  }

  return current;
}

List<String> _splitRoutePath(String path) {
  if (path.isEmpty || path == '/') {
    return const <String>[];
  }

  return path.split('/').where((segment) => segment.isNotEmpty).toList();
}

String _joinPaths(String base, String next) {
  final normalizedBase = base == '/' ? '' : base;
  final normalizedNext = next.startsWith('/') ? next.substring(1) : next;
  final joined = '$normalizedBase/$normalizedNext'.replaceAll('//', '/');
  return joined.isEmpty ? '/' : joined;
}

Expression? _findRoutesExpression(ClassDeclaration classDeclaration) {
  final getter = _findGetterExpression(classDeclaration, 'routes');
  if (getter != null) {
    return getter;
  }

  for (final member in _classMembers(classDeclaration)) {
    if (member is! FieldDeclaration) {
      continue;
    }

    for (final field in member.fields.variables) {
      if (field.name.lexeme == 'routes') {
        return field.initializer;
      }
    }
  }

  return null;
}

Expression? _findGetterExpression(
  ClassDeclaration classDeclaration,
  String name,
) {
  for (final member in _classMembers(classDeclaration)) {
    if (member is MethodDeclaration &&
        member.isGetter &&
        member.name.lexeme == name) {
      return _extractReturnedExpression(member.body);
    }
  }

  return null;
}

Iterable<ClassMember> _classMembers(ClassDeclaration classDeclaration) {
  final members = (classDeclaration.body as dynamic).members;
  if (members is Iterable<ClassMember>) {
    return members;
  }
  return const <ClassMember>[];
}

Expression? _extractReturnedExpression(FunctionBody body) {
  if (body is ExpressionFunctionBody) {
    return body.expression;
  }

  if (body is BlockFunctionBody) {
    final statements = body.block.statements;
    if (statements.length == 1 && statements.single is ReturnStatement) {
      return (statements.single as ReturnStatement).expression;
    }
  }

  return null;
}

List<CollectionElement>? _extractRouteListFromRootExpression(
  Expression expression,
  ClassDeclaration owner,
) {
  expression = _unwrapExpression(expression);
  if (expression is! InstanceCreationExpression) {
    return null;
  }

  final typeName = _instanceTypeName(expression);
  final constructorName = expression.constructorName.name?.name;
  if (typeName != 'Route' || constructorName != 'root') {
    return null;
  }

  final positional = expression.argumentList.arguments
      .whereType<Expression>()
      .toList();
  if (positional.length != 1) {
    throw InvalidGenerationSource(
      'Route.root must contain exactly one list argument.',
      node: expression,
    );
  }

  return _extractRouteListExpression(positional.single, owner, '`root` getter');
}

List<CollectionElement> _extractRouteListExpression(
  Expression expression,
  ClassDeclaration? owner,
  String context,
) {
  expression = _unwrapExpression(expression);

  if (expression is ListLiteral) {
    return expression.elements.toList(growable: false);
  }

  if (expression is SimpleIdentifier && owner != null) {
    final nested = _findRoutesExpression(owner);
    if (nested != null && nested != expression) {
      return _extractRouteListExpression(nested, owner, context);
    }
  }

  throw InvalidGenerationSource(
    'Expected a list literal for $context, but found `${expression.toSource()}`.',
    node: expression,
  );
}

Expression _unwrapExpression(Expression expression) {
  while (expression is ParenthesizedExpression) {
    expression = expression.expression;
  }
  return expression;
}

String _extractRoutePath(
  InstanceCreationExpression expression,
  ClassElement owner,
) {
  final constructorName = expression.constructorName.name?.name;
  if (constructorName == 'root') {
    return '/';
  }

  final pathExpression =
      _namedArgument(expression.argumentList, 'path') ??
      (throw InvalidGenerationSource(
        '${_instanceTypeName(expression)} requires a `path:` argument.',
        element: owner,
        node: expression,
      ));

  final path = _stringValue(pathExpression);
  if (path == null) {
    throw InvalidGenerationSource(
      'Route paths must be string literals. '
      'Found `${pathExpression.toSource()}` instead.',
      element: owner,
      node: pathExpression,
    );
  }

  return path;
}

Expression? _namedArgument(ArgumentList arguments, String name) {
  for (final argument in arguments.arguments) {
    if (argument is NamedExpression && argument.name.label.name == name) {
      return argument.expression;
    }
  }
  return null;
}

String? _stringValue(Expression expression) {
  expression = _unwrapExpression(expression);
  if (expression is SimpleStringLiteral) {
    return expression.value;
  }
  return null;
}

ClassElement? _extractConstructedClass(Expression expression) {
  expression = _unwrapExpression(expression);
  if (expression is! InstanceCreationExpression) {
    return null;
  }

  final type = expression.staticType;
  return type is InterfaceType ? type.element as ClassElement : null;
}

String _instanceTypeName(InstanceCreationExpression expression) {
  final raw = expression.constructorName.type.toSource();
  final withoutTypeArgs = raw.split('<').first;
  return withoutTypeArgs.split('.').last;
}

String _memberNameForSegment(String segment, {required bool isParameter}) {
  final source = isParameter ? segment.substring(1) : segment;
  final words = source
      .split(RegExp(r'[^a-zA-Z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) {
    return isParameter ? 'value' : 'route';
  }

  final buffer = StringBuffer(words.first.toLowerCase());
  for (final word in words.skip(1)) {
    buffer.write(_capitalize(word));
  }
  final candidate = buffer.toString();
  if (_reservedWords.contains(candidate)) {
    return '${candidate}Route';
  }
  if (RegExp(r'^[0-9]').hasMatch(candidate)) {
    return 'r$candidate';
  }
  return candidate;
}

String _classNamePartForSegment(String segment, {required bool isParameter}) {
  final source = isParameter ? segment.substring(1) : segment;
  final words = source
      .split(RegExp(r'[^a-zA-Z0-9]+'))
      .where((word) => word.isNotEmpty)
      .map(_capitalize)
      .toList(growable: false);

  if (words.isEmpty) {
    return isParameter ? 'Value' : 'Route';
  }

  final candidate = words.join();
  if (RegExp(r'^[0-9]').hasMatch(candidate)) {
    return 'R$candidate';
  }
  return candidate;
}

String _capitalize(String value) {
  if (value.isEmpty) {
    return value;
  }
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

const Set<String> _reservedWords = <String>{
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

final class _GenericRoutesEmitter {
  _GenericRoutesEmitter(this._spec);

  final RouteGenerationSpec _spec;
  final StringBuffer _buffer = StringBuffer();
  final Set<String> _writtenClasses = <String>{};

  String emit() {
    _buffer.writeln('abstract final class GrumpyRoutes {');
    for (final child in _spec.rootNode.children.values) {
      _emitRootMember(child);
    }
    _buffer.writeln('}');

    for (final child in _spec.rootNode.children.values) {
      _emitHelperClasses(child);
    }

    _buffer.writeln();
    _buffer.writeln('String _grumpyJoinPath(String base, String next) {');
    _buffer.writeln("  if (base == '/') {");
    _buffer.writeln("    return '/\$next';");
    _buffer.writeln('  }');
    _buffer.writeln("  return '\$base/\$next';");
    _buffer.writeln('}');

    return _buffer.toString().trimRight();
  }

  void _emitRootMember(RoutePathNode node) {
    final doc = _memberDoc(node, generic: true);
    if (doc.isNotEmpty) {
      _buffer.write(doc);
    }

    if (node.requiresObjectNode) {
      _buffer.writeln(
        '  static ${_genericHelperClassName(node)} get ${node.memberName} => '
        'const ${_genericHelperClassName(node)}(${_singleQuoted(node.pathLiteral)});',
      );
      return;
    }

    _buffer.writeln(
      '  static String get ${node.memberName} => '
      '${_singleQuoted(node.pathLiteral)};',
    );
  }

  void _emitHelperClasses(RoutePathNode node) {
    if (!node.requiresObjectNode) {
      return;
    }

    final className = _genericHelperClassName(node);
    if (!_writtenClasses.add(className)) {
      return;
    }

    _buffer.writeln();
    _buffer.writeln('final class $className {');
    _buffer.writeln('  const $className(this._path);');
    _buffer.writeln();
    _buffer.writeln('  final String _path;');
    _buffer.writeln();

    final doc = _memberDoc(node, generic: true, forPathGetter: true);
    if (doc.isNotEmpty) {
      _buffer.write(doc);
    }
    _buffer.writeln('  String get path => _path;');

    for (final child in node.children.values) {
      _buffer.writeln();
      final childDoc = _memberDoc(child, generic: true);
      if (childDoc.isNotEmpty) {
        _buffer.write(childDoc);
      }
      _emitGenericChildMember(child);
    }

    _buffer.writeln('}');

    for (final child in node.children.values) {
      _emitHelperClasses(child);
    }
  }

  void _emitGenericChildMember(RoutePathNode node) {
    if (node.kind == RouteNodeKind.parameter) {
      final returnType = _genericHelperClassName(node);
      _buffer.writeln(
        '  $returnType ${node.memberName}(String ${node.memberName}) => '
        '$returnType(_grumpyJoinPath(_path, Uri.encodeComponent(${node.memberName})));',
      );
      return;
    }

    if (node.requiresObjectNode) {
      _buffer.writeln(
        '  ${_genericHelperClassName(node)} get ${node.memberName} => '
        '${_genericHelperClassName(node)}(_grumpyJoinPath(_path, '
        '${_singleQuoted(node.segment)}));',
      );
      return;
    }

    _buffer.writeln(
      '  String get ${node.memberName} => '
      '_grumpyJoinPath(_path, ${_singleQuoted(node.segment)});',
    );
  }
}

final class _FlutterRoutesEmitter {
  _FlutterRoutesEmitter(this._spec);

  final RouteGenerationSpec _spec;
  final StringBuffer _buffer = StringBuffer();
  final Set<String> _writtenClasses = <String>{};

  String emit() {
    final rootClassName = _spec.rootClass.name;
    _buffer.writeln(
      'extension ${rootClassName}RoutesBuildContextX on BuildContext {',
    );
    _buffer.writeln(
      '  ${_flutterRootClassName()} get to => ${_flutterRootClassName()}(this);',
    );
    _buffer.writeln('}');
    _buffer.writeln();

    _buffer.writeln('final class ${_flutterRootClassName()} {');
    _buffer.writeln('  const ${_flutterRootClassName()}(this._context);');
    _buffer.writeln();
    _buffer.writeln('  final BuildContext _context;');
    _buffer.writeln();
    _buffer.writeln(
      '  void _go(String path) => _routeInformationProvider(_context).go(path);',
    );

    for (final child in _spec.rootNode.children.values) {
      _buffer.writeln();
      final doc = _memberDoc(child, generic: false);
      if (doc.isNotEmpty) {
        _buffer.write(doc);
      }
      _emitFlutterRootMember(child);
    }
    _buffer.writeln('}');

    for (final child in _spec.rootNode.children.values) {
      _emitFlutterHelperClasses(child);
    }

    _buffer.writeln();
    _buffer.writeln(
      'dynamic _routeInformationProvider(BuildContext context) {',
    );
    _buffer.writeln('  final router = Router.of<Object?>(context);');
    _buffer.writeln('  final provider = router.routeInformationProvider;');
    _buffer.writeln('  if (provider == null) {');
    _buffer.writeln(
      "    throw StateError('No RouteInformationProvider found for generated grumpy routes.');",
    );
    _buffer.writeln('  }');
    _buffer.writeln('  return provider;');
    _buffer.writeln('}');

    return _buffer.toString().trimRight();
  }

  void _emitFlutterRootMember(RoutePathNode node) {
    if (node.requiresObjectNode) {
      _buffer.writeln(
        '  ${_flutterHelperClassName(node)} get ${node.memberName} => '
        '${_flutterHelperClassName(node)}(_context, '
        '${_singleQuoted(node.pathLiteral)});',
      );
      return;
    }

    _buffer.writeln(
      '  void ${node.memberName}() => _go(${_singleQuoted(node.pathLiteral)});',
    );
  }

  void _emitFlutterHelperClasses(RoutePathNode node) {
    if (!node.requiresObjectNode) {
      return;
    }

    final className = _flutterHelperClassName(node);
    if (!_writtenClasses.add(className)) {
      return;
    }

    _buffer.writeln();
    _buffer.writeln('final class $className {');
    _buffer.writeln('  const $className(this._context, this._path);');
    _buffer.writeln();
    _buffer.writeln('  final BuildContext _context;');
    _buffer.writeln('  final String _path;');
    _buffer.writeln();

    final doc = _memberDoc(node, generic: false, forPathGetter: true);
    if (doc.isNotEmpty) {
      _buffer.write(doc);
    }
    _buffer.writeln('  String get path => _path;');

    if (node.isNavigable) {
      _buffer.writeln();
      _buffer.writeln(
        '  void call() => _routeInformationProvider(_context).go(_path);',
      );
    }

    for (final child in node.children.values) {
      _buffer.writeln();
      final childDoc = _memberDoc(child, generic: false);
      if (childDoc.isNotEmpty) {
        _buffer.write(childDoc);
      }
      _emitFlutterChildMember(child);
    }

    _buffer.writeln('}');

    for (final child in node.children.values) {
      _emitFlutterHelperClasses(child);
    }
  }

  void _emitFlutterChildMember(RoutePathNode node) {
    if (node.kind == RouteNodeKind.parameter) {
      _buffer.writeln(
        '  ${_flutterHelperClassName(node)} ${node.memberName}(String ${node.memberName}) => '
        '${_flutterHelperClassName(node)}(_context, '
        "_grumpyJoinPath(_path, Uri.encodeComponent(${node.memberName})));",
      );
      return;
    }

    if (node.requiresObjectNode) {
      _buffer.writeln(
        '  ${_flutterHelperClassName(node)} get ${node.memberName} => '
        '${_flutterHelperClassName(node)}(_context, '
        '_grumpyJoinPath(_path, ${_singleQuoted(node.segment)}));',
      );
      return;
    }

    _buffer.writeln(
      '  void ${node.memberName}() => '
      '_routeInformationProvider(_context).go('
      '_grumpyJoinPath(_path, ${_singleQuoted(node.segment)}));',
    );
  }

  String _flutterRootClassName() => '_${_spec.rootClass.name}ContextRoutes';
}

String _singleQuoted(String value) {
  return "'${value.replaceAll(r"'", r"\'")}'";
}

String _memberDoc(
  RoutePathNode node, {
  required bool generic,
  bool forPathGetter = false,
}) {
  final lines = <String>[
    '  /// Full path${node.kind == RouteNodeKind.parameter ? " pattern" : ""}: '
        '`${node.fullPathPattern}`.',
  ];

  if (node.kind == RouteNodeKind.parameter) {
    lines.add('  /// Parameter segment helper.');
  } else if (node.isModuleBoundary && !node.isNavigable) {
    lines.add(
      '  /// Warning: this module has no root leaf, so '
      '${generic ? "this node is a namespace/path holder only." : "`.call()` is intentionally not generated."}',
    );
  } else if (node.isModuleBoundary) {
    lines.add('  /// Module boundary with a navigable root leaf.');
  } else if (node.isLeaf && !node.hasChildren) {
    lines.add('  /// Leaf route.');
  }

  if (forPathGetter && node.isNavigable) {
    lines.add('  /// This is the concrete path for the current node.');
  }

  return '${lines.join('\n')}\n';
}

String _genericHelperClassName(RoutePathNode node) =>
    '_${_helperClassStem(node)}Routes';

String _flutterHelperClassName(RoutePathNode node) =>
    '_${_helperClassStem(node)}ContextRoutes';

String _helperClassStem(RoutePathNode node) {
  final segments = _splitRoutePath(node.fullPathPattern);
  if (segments.isEmpty) {
    return 'Root';
  }

  return segments
      .map(
        (segment) => _classNamePartForSegment(
          segment,
          isParameter: segment.startsWith(':'),
        ),
      )
      .join();
}
