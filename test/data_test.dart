import 'dart:convert';
import 'dart:io';

import 'package:flashcard/core/language.dart';
import 'package:flashcard/core/vocabulary_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final languages = Language.listFromJson(File('data/languages.json').readAsStringSync());

  group('parseCsv', () {
    test('handles quotes, commas and CRLF', () {
      expect(parseCsv('a,"b, c","say ""hi"""\r\n1,2,3\r\n'), [
        ['a', 'b, c', 'say "hi"'],
        ['1', '2', '3'],
      ]);
    });
  });

  group('vocabulary.csv', () {
    late List<VocabCard> cards;
    setUpAll(() {
      cards = readVocabulary(File('data/vocabulary.csv').readAsStringSync(), languages);
    });

    test('is valid and complete', () {
      expect(cards.length, greaterThan(8900));
      for (final level in levels) {
        expect(cards.where((c) => c.level == level), isNotEmpty, reason: level);
      }
    });

    test('every card has every language', () {
      for (final card in cards) {
        expect(card.terms.keys.toSet(), languages.map((l) => l.code).toSet(), reason: card.id);
      }
    });

    test('rejects bad rows', () {
      final header = File('data/vocabulary.csv').readAsLinesSync().first;
      final bad = '$header\nx-1,Z9,hi,blah,Hallo,,interj,hallo,,interj,سلام,interj\n';
      expect(() => readVocabulary(bad, languages), throwsA(isA<VocabularyFormatException>()));
    });
  });

  group('conjugations.csv', () {
    late List<VocabCard> cards;
    late Map<(String, String), List<Conjugation>> conjugations;
    setUpAll(() {
      cards = readVocabulary(File('data/vocabulary.csv').readAsStringSync(), languages);
      conjugations = readConjugations(File('data/conjugations.csv').readAsStringSync(), languages, {
        for (final card in cards) card.id,
      });
    });

    test('has a table for most verbs, with six persons per tense', () {
      expect(conjugations.length, greaterThan(7000));
      for (final tenses in conjugations.values) {
        for (final tense in tenses) {
          expect(tense.forms, hasLength(6));
        }
      }
      final gehen = conjugations[('a1-0507', 'de')]!;
      expect(gehen.map((c) => c.tense), [
        'present',
        'simple_past',
        'present_perfect',
        'past_perfect',
        'future',
      ]);
      expect(gehen.first.forms, ['gehe', 'gehst', 'geht', 'gehen', 'geht', 'gehen']);
      expect(conjugations[('a1-0507', 'fa')]!.first.forms.first, 'می‌روم');
    });

    test('word forms come from the other columns', () {
      final gehen = cards.firstWhere((c) => c.id == 'a1-0507');
      expect(gehen.terms['de']!.forms, {
        'past': 'ging',
        'participle': 'gegangen',
        'auxiliary': 'sein',
      });
      expect(gehen.terms['fa']!.forms['present_stem'], 'رو');
      expect(gehen.terms['en']!.forms, {'past': 'went', 'past_participle': 'gone'});
    });

    test('rejects unknown cards and languages', () {
      const header = 'id,language,verb,tense,1s,2s,3s,1p,2p,3p';
      expect(
        () => readConjugations('$header\nx-1,german,a,present,a,b,c,d,e,f\n', languages, {'a'}),
        throwsA(isA<VocabularyFormatException>()),
      );
      expect(
        () => readConjugations('$header\na,klingon,a,present,a,b,c,d,e,f\n', languages, {'a'}),
        throwsA(isA<VocabularyFormatException>()),
      );
    });
  });

  group('languages', () {
    test('every language is named in every menu language', () {
      final codes = languages.map((l) => l.code).toSet();
      for (final lang in languages) {
        expect(lang.names.keys.toSet(), codes, reason: lang.code);
      }
    });

    test('every language has a complete menu translation file', () {
      Set<String> keys(String code) {
        final file = File('lib/l10n/app_$code.arb');
        expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');
        final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        return json.keys.where((k) => !k.startsWith('@')).toSet();
      }

      final english = keys('en');
      for (final lang in languages) {
        expect(keys(lang.code), english, reason: lang.code);
      }
    });
  });
}
