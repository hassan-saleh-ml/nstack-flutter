import 'dart:async';
import 'dart:convert';

import 'package:build/build.dart';
import 'package:nstack/models/language.dart';
import 'package:nstack/models/language_response.dart';
import 'package:nstack/models/localize_index.dart';
import 'package:nstack/models/nstack_config.dart';
import 'package:nstack/other/extensions.dart';
import 'package:nstack/other/reserved_keywords.dart';
import 'package:nstack/src/nstack_repository.dart';

/// A builder which outputs a 'nstack.dart' file. This file provides a NStack instance, type safe section key accessors and all bundled translations.
class NstackBuilder implements Builder {
  const NstackBuilder();

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    if (!buildStep.inputId.toString().contains('nstack.json')) {
      return;
    }
    /// Read the input source and parse it as JSON.
    final AssetId outputId = buildStep.inputId.changeExtension('.dart');
    final StringBuffer output = StringBuffer();

    // Read nstack.json file
    final Map<String, dynamic> input =
        json.decode(await buildStep.readAsString(buildStep.inputId));

    final String projectId = input['nstack_project_id'] ?? '';
    final String apiKey = input['nstack_api_key'] ?? '';

    throwIf(projectId.isNullOrBlank, () {
      return ArgumentError('"nstack_project_id" not set');
    });

    throwIf(apiKey.isNullOrBlank, () {
      return ArgumentError('"nstack_api_key" not set');
    });

    final config = NStackConfig(
      projectId: projectId,
      apiKey: apiKey,
    );

    final repository = NStackRepository(config);

    _writeHeader(output);

    try {
      final languages = await repository.fetchAvailableLanguages();

      // Find the default language
      LocalizeIndex defaultLanguage =
          languages.where((it) => it.language!.isDefault == true).first;
      print('Found the default Language: ${defaultLanguage.language}');

      // Fetch localization for default language
      print('Fetching default localization from: ${defaultLanguage.url}');
      final localizationResponse =
          await repository.fetchLocalizationForLanguage(defaultLanguage);
      final localizationData =
          LocalizationData.fromJson(jsonDecode(localizationResponse));

      print('Creating Localization class...');
      _writeLocalization(localizationData, output);

      print('Creating NStack section classes...');
      _writeSections(localizationData, output);

      print('Creating NStack...');
      _writeNStackConfig(projectId, apiKey, output);
      _writeLanguageList(languages, output);
      await _writeBundledTranslations(languages, repository, output);
      _writeNStack(output);

      print('Creating NStackWidget...');
      _writeNStackWidget(output);
    } catch (e, s) {
      print(e);
      print(s);
    }

    await buildStep.writeAsString(outputId, output.toString());
  }

  void _writeHeader(StringBuffer output) {
    output.writeln('''
/// Generated by NStack, do not modify this file.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:nstack/models/language.dart';
import 'package:nstack/models/localize_index.dart';
import 'package:nstack/models/nstack_config.dart';
import 'package:nstack/nstack.dart';
import 'package:nstack/partial/section_key_delegate.dart';

// Update this file by running:
// - `flutter pub run build_runner build`, if your package depends on Flutter
// - `pub run build_runner build` otherwise
      ''');
  }

  void _writeLocalization(LocalizationData localization, StringBuffer output) {
    final languageJson = localization.data!;

    // Localization class
    output.writeln('class Localization {');

    // Create section fields
    languageJson.forEach((sectionKey, keys) {
      String className = _getClassNameFromSectionKey(sectionKey);
      final variableName =
          '${className[0].toLowerCase()}${className.substring(1)}';
      output.writeln('\tfinal $variableName = const _$className();');
    });
    output.writeln('');
    output.writeln('\tconst Localization();');
    output.writeln('''
}
''');
  }

  void _writeSections(LocalizationData localization, StringBuffer output) {
    final languageJson = localization.data!;
    languageJson.forEach((sectionKey, translations) {
      String className = _getClassNameFromSectionKey(sectionKey);

      output.writeln('class _$className extends SectionKeyDelegate {');
      output.writeln('\tconst _$className(): super(\'$sectionKey\');');
      output.writeln('');

      (translations as Map)
          .cast<String, String>()
          .forEach((stringKey, stringValue) {
        stringValue = _escapeSpecialCharacters(stringValue);
        output.writeln(
            '\tString get $stringKey => get(\'$stringKey\', \"$stringValue\");');
      });
      output.writeln('''
}
''');
    });
  }

  /// Escapes single quote, double quote and dollar sign with \', \", \$
  String _escapeSpecialCharacters(String stringValue) {
    return stringValue
        .replaceAll("'", "\\'")
        .replaceAll('"', '\\"')
        .replaceAll('\$', '\\\$')
        .replaceAll('\n', '\\n');
  }

  /// Returns a CamelCase class name from the Localization section key
  String _getClassNameFromSectionKey(String sectionKey) {
    // Check if the section key is using a reserved keyword
    final adjustedSectionKey = DartKeywords.isReserved(sectionKey)
        // Append 'Section' to the name of the original sectionKey
        ? '${sectionKey}Section'
        // Use the original sectionKey
        : sectionKey;
    // Format the name to CamelCase
    return adjustedSectionKey.replaceRange(
        0, 1, sectionKey.substring(0, 1).toUpperCase());
  }

  void _writeNStackConfig(
    String? projectId,
    String? apiKey,
    StringBuffer output,
  ) {
    output.writeln('''
const _config = NStackConfig(projectId: '$projectId', apiKey: '$apiKey');
    ''');
  }

  void _writeLanguageList(List<LocalizeIndex> languages, StringBuffer output) {
    output.writeln('final _languages = [');

    languages.forEach((localizeIndex) {
      output.write("LocalizeIndex(id: ${localizeIndex.id}, url: null, lastUpdatedAt: null, shouldUpdate: false,  language: ");
      Language language = localizeIndex.language!;
      output.write(
        '\tLanguage(id: ${language.id}, name: \'${language.name}\', locale: \'${language.locale}\', direction: \'${language.direction}\', isDefault: ${language.isDefault}, isBestFit: ${language.isBestFit})',
      );
      output.writeln('),');
    });

    output.writeln('''
];
''');
  }

  Future _writeBundledTranslations(
    List<LocalizeIndex> languages,
    NStackRepository repository,
    StringBuffer output,
  ) async {
    output.writeln('''
const _bundledTranslations = {''');

    await Future.forEach<LocalizeIndex>(languages, (localizeIndex) async {
      final locale = localizeIndex.language!.locale;
      var content =
          (await repository.fetchLocalizationForLanguage(localizeIndex));
      output.writeln('\t\'$locale\': r\'\'\'$content\'\'\',');
    });

    output.writeln('''
};
''');
  }

  void _writeNStack(StringBuffer output) async {
    output.writeln('''
final _nstack = NStack<Localization>(
  config: _config,
  localization: const Localization(),
  availableLanguages: _languages,
  bundledTranslations: _bundledTranslations,
  pickedLanguageLocale: '',
  debug: kDebugMode
);
''');
  }

  void _writeNStackWidget(StringBuffer output) async {
    output.writeln('''
class NStackScope extends InheritedWidget {
  final NStack<Localization> nstack;
  final NStackState state;
  final String checksum;

  NStackScope({Key? key, required Widget child, required this.state, required this.nstack, required this.checksum})
    : super(key: key, child: child);

  static NStackState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NStackScope>()!.state;

  @override
  bool updateShouldNotify(NStackScope oldWidget) =>
      checksum != oldWidget.checksum;
}

class NStackWidget extends StatefulWidget {
  final Widget child;

  const NStackWidget({Key? key, required Widget child})
      : child = child,
        super(key: key);

  @override
  NStackState createState() => NStackState();
}

class NStackState extends State<NStackWidget> {
	final NStack<Localization> nstack = _nstack;

	changeLanguage(Locale locale) async {
		print("Starting language switch...");
		await _nstack.changeLocalization(locale);
		print("Language switch done!");
		setState(() {});
	}

	_attemptAppOpen() {
		try {
			nstack.appOpen(Localizations.localeOf(context));
		} catch(s,e) {
			print("NStack could not call appOpen() as the NStackWidget is too far up the widget tree.");
			print("Consider calling NStackScope.of(context).nstack.appOpen(Localizations.localeOf(context)) in a splashscreen or later.");
			//throw e;
		}
	}

	@override
  void initState() {
    super.initState();
    _attemptAppOpen();
  }

  @override
  Widget build(BuildContext context) {
		return NStackScope(child: widget.child, state: this, nstack: this.nstack, checksum: nstack.checksum,);
  }
}

/// Allows to access the Nstack Localization using the BuildContext
extension NStackWidgetExtension on BuildContext {
	Localization get localization => NStackScope.of(this).nstack.localization;
}

/// Allows to access the Nstack Localization from StatefulWidget's State
extension NStackStateExtension<T extends StatefulWidget> on State<T> {
	Localization get localization => context.localization;
}
''');
  }

  @override
  Map<String, List<String>> get buildExtensions => const {
        '.json': ['.dart']
      };
}
