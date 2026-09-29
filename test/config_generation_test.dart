import 'dart:convert';
import 'dart:io';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:grumpy_gen/grumpy_gen.dart';
import 'package:source_gen/source_gen.dart';
import 'package:test/test.dart';

class FixtureResolver implements RouteAstResolver {
  FixtureResolver(this.session);
  final AnalysisSession session;
  @override
  Future<AstNode?> astNodeFor(Fragment fragment) async {
    final library =
        await session.getResolvedLibrary(
              fragment.element.library!.firstFragment.source.fullName,
            )
            as ResolvedLibraryResult;
    final unit = library.unitWithPath(
      fragment.libraryFragment!.source.fullName,
    )!;
    final node = NodeLocator2(fragment.offset).searchWithin(unit.unit);
    if (node is SimpleIdentifier) return node.parent;
    return node;
  }
}

void main() {
  late AnalysisContextCollection collection;
  setUpAll(() {
    collection = AnalysisContextCollection(
      includedPaths: [Directory.current.path],
    );
  });
  Future<ConfigArtifacts?> generate(String name) async {
    final path = '${Directory.current.path}/test/config_fixtures/$name.dart';
    final session = collection.contextFor(path).currentSession;
    final library =
        await session.getResolvedLibrary(path) as ResolvedLibraryResult;
    return generateConfigArtifacts([library.element], FixtureResolver(session));
  }

  test(
    'typed aggregate preserves interfaces, mixin defaults and metadata',
    () async {
      final result = (await generate('valid'))!;
      final schema = jsonDecode(result.schema) as Map;
      final global = schema[r'$defs']['global']['properties'] as Map;
      final local = schema[r'$defs']['local']['properties'] as Map;
      expect(global['port']['default'], 8080);
      expect(global['enabled']['default'], false);
      expect(global['environment']['enum'], ['development', 'production']);
      expect(global['environment']['default'], 'development');
      expect(global['tags']['default'], []);
      expect(global.containsKey('name'), false);
      expect(local.keys, containsAll(global.keys));
      expect(local['name']['description'], 'Workspace name.');
      expect(local['name']['anyOf'][0]['minLength'], 1);
      expect(
        result.model,
        contains('implements _c0.GlobalSettings, _c0.LocalSettings'),
      );
      expect(
        result.model,
        contains('factory AppConfig() => RootModule.getConfig<AppConfig>()'),
      );
      expect(result.documentation, contains('Workspace name.'));
      expect((await generate('valid'))!.schema, result.schema);
    },
  );
  test(
    'structured objects and typed maps generate codecs and schemas',
    () async {
      final result = (await generate('structured'))!;
      final schema = jsonDecode(result.schema) as Map;
      final fields = schema[r'$defs']['global']['properties'];
      expect(fields['retry']['default'], {'attempts': 3});
      expect(fields['retry']['properties']['attempts']['type'], 'integer');
      expect(fields['weights']['additionalProperties']['type'], 'number');
      expect(result.model, contains('CliValueType.object'));
    },
  );
  test(
    'runtime-only validation is described once at the property level',
    () async {
      final result = (await generate('runtime_validation'))!;
      final schema = jsonDecode(result.schema) as Map;
      final token = schema[r'$defs']['global']['properties']['token'] as Map;
      expect(token['x-runtime-validation'], 'Token must be valid.');
      expect(
        (token['anyOf'][0] as Map).containsKey('x-runtime-validation'),
        false,
      );
      expect(result.model, contains('validator: _c0.validateToken'));
    },
  );
  test('no annotations produce no artifacts', () async {
    expect(await generate('none'), isNull);
  });
  for (final entry in {
    'duplicate': 'Duplicate config property port',
    'invalid_default': 'outside its range',
    'required': 'must be nullable or have a default',
    'dynamic_default': 'statically evaluable',
    'only_local': 'Declare one global model',
    'two_globals': 'Only one global config model',
  }.entries) {
    test('rejects ${entry.key}', () async {
      await expectLater(
        generate(entry.key),
        throwsA(
          isA<InvalidGenerationSource>().having(
            (e) => e.message,
            'message',
            contains(entry.value),
          ),
        ),
      );
    });
  }
}
