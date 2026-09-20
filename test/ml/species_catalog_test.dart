import 'package:flutter_test/flutter_test.dart';
import 'package:plantgo/ml/species_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(SpeciesCatalog.resetForTest);

  group('SpeciesCatalog', () {
    test('loads the shipped labels.json', () async {
      final catalog = await SpeciesCatalog.load();

      expect(catalog.count, 40, reason: 'the Nepal-40 model has 40 classes');
      expect(catalog.inputSize, 224);
      expect(catalog.labelsVersion, isNotEmpty);
    });

    test('class position equals model output index', () async {
      final catalog = await SpeciesCatalog.load();

      // This is the invariant that stops the app mislabelling species: the
      // model emits a bare integer, and we index straight into this list.
      for (var i = 0; i < catalog.count; i++) {
        expect(catalog.all[i].index, i);
        expect(catalog.byIndex(i).index, i);
      }
    });

    test('is ordered by scientific name, matching the training folder sort',
        () async {
      final catalog = await SpeciesCatalog.load();
      final names = catalog.all.map((s) => s.scientificName).toList();

      expect(names, equals([...names]..sort()));
      expect(names.first, 'Ageratina adenophora');
      expect(names.last, 'Urtica dioica');
    });

    test('every species carries the content the UI needs', () async {
      final catalog = await SpeciesCatalog.load();

      for (final s in catalog.all) {
        expect(s.scientificName, isNotEmpty, reason: 'index ${s.index}');
        expect(s.commonName, isNotEmpty, reason: s.scientificName);
        expect(s.category, isNotEmpty, reason: s.scientificName);
        expect(s.safety, isNotEmpty, reason: s.scientificName);
        expect(s.habitat, isNotEmpty, reason: s.scientificName);
        expect(s.note, isNotEmpty, reason: s.scientificName);
        expect(s.visualFeatures.length, greaterThanOrEqualTo(4),
            reason: '${s.scientificName} needs >=4 features for riddles');
      }
    });

    test('lookup by scientific name works and is null-safe', () async {
      final catalog = await SpeciesCatalog.load();

      final peepal = catalog.byScientificName('Ficus religiosa');
      expect(peepal, isNotNull);
      expect(peepal!.commonName, 'Peepal');
      expect(peepal.category, 'sacred_tree');

      expect(catalog.byScientificName('Nothing realis'), isNull);
    });

    test('byIndex rejects out-of-range indices', () async {
      final catalog = await SpeciesCatalog.load();

      expect(() => catalog.byIndex(-1), throwsA(isA<RangeError>()));
      expect(() => catalog.byIndex(catalog.count), throwsA(isA<RangeError>()));
    });

    test('hazard flag catches the plants that can actually hurt someone',
        () async {
      final catalog = await SpeciesCatalog.load();

      for (final name in [
        'Datura stramonium', // highly toxic seeds
        'Ricinus communis', // ricin
        'Calotropis gigantea', // latex irritant
        'Lantana camara', // toxic berries
      ]) {
        final s = catalog.byScientificName(name);
        expect(s, isNotNull, reason: name);
        expect(s!.hazard, Hazard.toxic, reason: '$name must be flagged toxic');
      }

      for (final name in [
        'Urtica dioica', // stings
        'Parthenium hysterophorus', // dermatitis
        'Colocasia esculenta', // must be cooked
        'Cannabis sativa', // legally restricted
      ]) {
        final s = catalog.byScientificName(name);
        expect(s, isNotNull, reason: name);
        expect(s!.hazard, Hazard.caution, reason: '$name needs a caution');
      }
    });

    test('plants whose note says "Not toxic." are not flagged', () async {
      final catalog = await SpeciesCatalog.load();

      // Regression: the first implementation inferred hazard by searching the
      // safety text for "toxic", so "Not toxic." matched and every safe plant
      // showed a danger warning.
      for (final name in [
        'Ficus religiosa',
        'Tagetes erecta',
        'Antirrhinum majus',
        'Butea monosperma',
      ]) {
        final s = catalog.byScientificName(name);
        expect(s, isNotNull, reason: name);
        expect(s!.safety.toLowerCase(), contains('toxic'),
            reason: '$name should still literally contain the word');
        expect(s.hazard, Hazard.none, reason: '$name must NOT be flagged');
        expect(s.isHazardous, isFalse, reason: name);
      }
    });

    test('hazard levels are spread sensibly across the 40', () async {
      final catalog = await SpeciesCatalog.load();
      final toxic = catalog.all.where((s) => s.hazard == Hazard.toxic).length;
      final caution = catalog.all.where((s) => s.hazard == Hazard.caution).length;
      final safe = catalog.all.where((s) => s.hazard == Hazard.none).length;

      expect(toxic + caution + safe, catalog.count);
      expect(toxic, greaterThan(0));
      expect(safe, greaterThan(toxic), reason: 'most plants are safe to touch');
    });

    test('invasive species are grouped for the spot-the-invader mechanic',
        () async {
      final catalog = await SpeciesCatalog.load();
      final invasives = catalog.byCategory('invasive');

      expect(invasives.length, greaterThanOrEqualTo(5));
      expect(invasives.map((s) => s.scientificName), contains('Lantana camara'));
    });

    test('throws a clear error before load() is awaited', () {
      expect(() => SpeciesCatalog.instance, throwsA(isA<StateError>()));
    });

    test('load() is idempotent and returns the same instance', () async {
      final a = await SpeciesCatalog.load();
      final b = await SpeciesCatalog.load();
      expect(identical(a, b), isTrue);
    });
  });
}
