import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plantgo/ml/riddle_repository.dart';
import 'package:plantgo/ml/species_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpeciesCatalog catalog;

  setUp(() async {
    SpeciesCatalog.resetForTest();
    catalog = await SpeciesCatalog.load();
  });

  group('RiddleRepository.compose (offline fallback)', () {
    test('always produces exactly 4 lines ending in a question', () {
      // Every species, several seeds: the game breaks if this ever fails.
      for (final species in catalog.all) {
        for (var seed = 0; seed < 8; seed++) {
          final lines = RiddleRepository.compose(species, Random(seed));
          expect(lines, hasLength(4),
              reason: '${species.scientificName} seed $seed');
          expect(lines.last.trimRight(), endsWith('?'),
              reason: '${species.scientificName} seed $seed');
          for (final l in lines) {
            expect(l.trim(), isNotEmpty,
                reason: '${species.scientificName} seed $seed');
          }
        }
      }
    });

    test('never leaks the plant name', () {
      for (final species in catalog.all) {
        final nameWords = [
          ...species.commonName.toLowerCase().split(RegExp(r'[\s()]+')),
          ...species.scientificName.toLowerCase().split(' '),
        ].where((w) => w.length > 3);

        for (var seed = 0; seed < 8; seed++) {
          final text =
              RiddleRepository.compose(species, Random(seed)).join(' ').toLowerCase();
          for (final word in nameWords) {
            expect(text.contains(word), isFalse,
                reason: '${species.scientificName} seed $seed leaked "$word"');
          }
        }
      }
    });

    test('uses the species own visual features', () {
      final peepal = catalog.byScientificName('Ficus religiosa')!;
      final text = RiddleRepository.compose(peepal, Random(1)).join(' ').toLowerCase();

      // At least one distinctive feature word should survive into the riddle.
      final hits = ['heart', 'tremble', 'bark', 'figs', 'leaf', 'leaves']
          .where(text.contains)
          .length;
      expect(hits, greaterThan(0), reason: 'riddle was: $text');
    });

    test('is varied across seeds', () {
      final species = catalog.byScientificName('Lantana camara')!;
      final variants = {
        for (var seed = 0; seed < 12; seed++)
          RiddleRepository.compose(species, Random(seed)).join('\n')
      };
      expect(variants.length, greaterThan(1),
          reason: 'a treasure hunt that always says the same thing is dull');
    });

    test('handles a species with exactly the minimum features', () {
      const sparse = Species(
        index: 0,
        scientificName: 'Testus plantus',
        commonName: 'Testy',
        category: 'flower',
        habitat: 'nowhere',
        safety: 'Not toxic.',
        note: 'n/a',
        hazard: Hazard.none,
        visualFeatures: ['Only one feature'],
      );

      final lines = RiddleRepository.compose(sparse, Random(3));
      expect(lines, hasLength(4));
      expect(lines.last, endsWith('?'));
    });
  });

  group('Riddle', () {
    test('isWellFormed matches the game rules', () {
      final species = catalog.byIndex(0);

      expect(
        Riddle(
          lines: const ['a', 'b', 'c', 'what am I?'],
          species: species,
          source: RiddleSource.model,
        ).isWellFormed,
        isTrue,
      );
      expect(
        Riddle(
          lines: const ['a', 'b', 'what am I?'],
          species: species,
          source: RiddleSource.model,
        ).isWellFormed,
        isFalse,
        reason: 'three lines is not a valid riddle',
      );
      expect(
        Riddle(
          lines: const ['a', 'b', 'c', 'no question mark'],
          species: species,
          source: RiddleSource.model,
        ).isWellFormed,
        isFalse,
      );
    });

    test('text joins lines with newlines', () {
      final r = Riddle(
        lines: const ['one', 'two', 'three', 'four?'],
        species: catalog.byIndex(0),
        source: RiddleSource.composed,
      );
      expect(r.text, 'one\ntwo\nthree\nfour?');
    });
  });
}
