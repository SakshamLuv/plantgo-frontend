import 'dart:convert';

import 'package:flutter/services.dart';

/// How much care a plant needs, as recorded in the species data.
///
/// This is read from an explicit field rather than inferred from the safety
/// prose. Sniffing the text for "toxic" flagged every plant whose note said
/// "Not toxic." — i.e. exactly the safe ones.
enum Hazard {
  /// Safe to handle.
  none,

  /// Stings, irritates, must be cooked, or is legally restricted.
  caution,

  /// Dangerous to eat or touch.
  toxic;

  static Hazard parse(String? value) => switch (value) {
        'toxic' => Hazard.toxic,
        'caution' => Hazard.caution,
        _ => Hazard.none,
      };
}

/// One of the species the model can recognise, plus the content the app shows
/// about it. Loaded from `assets/models/labels.json`, which is emitted by
/// training — the [index] here is the model's output index.
class Species {
  const Species({
    required this.index,
    required this.scientificName,
    required this.commonName,
    required this.category,
    required this.habitat,
    required this.safety,
    required this.note,
    required this.hazard,
    required this.visualFeatures,
  });

  final int index;
  final String scientificName;
  final String commonName;
  final String category;
  final String habitat;
  final String safety;
  final String note;
  final Hazard hazard;
  final List<String> visualFeatures;

  /// Whether to show a warning at all. The level decides the colour.
  bool get isHazardous => hazard != Hazard.none;

  bool get isInvasive => category == 'invasive';

  factory Species.fromJson(Map<String, dynamic> json) => Species(
        index: json['index'] as int,
        scientificName: json['scientific_name'] as String,
        commonName: json['common_name'] as String? ?? '',
        category: json['category'] as String? ?? '',
        habitat: json['habitat'] as String? ?? '',
        safety: json['safety'] as String? ?? '',
        note: json['note'] as String? ?? '',
        hazard: Hazard.parse(json['hazard'] as String?),
        visualFeatures:
            (json['visual_features'] as List?)?.cast<String>() ?? const [],
      );
}

/// The species list, loaded once and shared.
///
/// The ordering of [all] is the model's output ordering, so it must never be
/// re-sorted. [labelsVersion] and [inputSize] come from the same file the model
/// was exported with, which is what lets [PlantClassifier] fail loudly if an
/// asset and a model ever get out of step.
class SpeciesCatalog {
  SpeciesCatalog._(this.all, this.labelsVersion, this.inputSize)
      : _byScientific = {for (final s in all) s.scientificName: s};

  final List<Species> all;
  final String labelsVersion;
  final int inputSize;
  final Map<String, Species> _byScientific;

  static const String assetPath = 'assets/models/labels.json';
  static SpeciesCatalog? _instance;

  static SpeciesCatalog get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('SpeciesCatalog.load() must be awaited before use');
    }
    return i;
  }

  static bool get isLoaded => _instance != null;

  static Future<SpeciesCatalog> load() async {
    final existing = _instance;
    if (existing != null) return existing;

    final raw = await rootBundle.loadString(assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final classes = (json['classes'] as List)
        .map((e) => Species.fromJson(e as Map<String, dynamic>))
        .toList();

    // Guard the invariant everything else relies on: position == model index.
    for (var i = 0; i < classes.length; i++) {
      if (classes[i].index != i) {
        throw StateError(
          'labels.json is out of order at position $i '
          '(found index ${classes[i].index}); the app would mislabel species',
        );
      }
    }

    return _instance = SpeciesCatalog._(
      classes,
      json['version'] as String? ?? 'unknown',
      json['input_size'] as int? ?? 224,
    );
  }

  int get count => all.length;

  Species byIndex(int index) {
    if (index < 0 || index >= all.length) {
      throw RangeError('species index $index outside 0..${all.length - 1}');
    }
    return all[index];
  }

  Species? byScientificName(String name) => _byScientific[name];

  List<Species> byCategory(String category) =>
      all.where((s) => s.category == category).toList();

  /// Visible for tests only.
  static void resetForTest() => _instance = null;
}
