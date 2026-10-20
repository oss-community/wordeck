import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flashcard/app.dart';
import 'package:flashcard/data/progress_database.dart';
import 'package:flashcard/data/progress_repository.dart';
import 'package:flashcard/data/speech.dart';
import 'package:flashcard/data/vocabulary_repository.dart';
import 'package:flashcard/core/vocabulary_source.dart';
import 'package:flashcard/domain/pair.dart';
import 'package:flashcard/domain/profile.dart';
import 'package:flashcard/l10n/app_localizations.dart';
import 'package:flashcard/domain/srs.dart';
import 'package:flashcard/state/providers.dart';
import 'package:flashcard/ui/about_screen.dart';
import 'package:flashcard/ui/difficulty_menu.dart';
import 'package:flashcard/ui/links.dart';
import 'package:flashcard/ui/term_text.dart';
import 'package:flashcard/ui/word_forms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

// Needs assets/vocabulary.db: run `dart run tool/build_vocabulary_db.dart` first.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final vocabulary = Vocabulary.fromFile('assets/vocabulary.db');
  final now = DateTime.utc(2026, 10, 13, 9);

  test('vocabulary.db holds every card in every language', () {
    expect(vocabulary.cards.length, greaterThan(8900));
    expect(vocabulary.languages.map((l) => l.code), ['en', 'de', 'nl', 'fa']);
    final card = vocabulary.cards.firstWhere((c) => c.terms['de']!.word == 'die Frau');
    expect(card.terms['de']!.plural, 'Frauen');
    expect(card.terms['nl']!.word, startsWith('de '));
    expect(vocabulary.cards.map((c) => c.difficulty).toSet(), {'easy', 'medium', 'advanced'});
  });

  group('ProgressRepository', () {
    late ProgressRepository repo;
    setUp(() => repo = ProgressRepository(ProgressDatabase(NativeDatabase.memory())));

    test('keeps progress per profile', () async {
      final deFa = await repo.createProfile(native: 'fa', target: 'de');
      final nlEn = await repo.createProfile(name: 'Work', native: 'en', target: 'nl', level: 'B1');
      final schedule = Srs(fuzz: false).review(Schedule.fresh(now), Rating.good, now);
      await repo.saveReview(
        profile: deFa.id,
        reversed: false,
        cardId: 'a1-0001',
        schedule: schedule,
        rating: Rating.good,
        wasNew: true,
        at: now,
      );
      await repo.setDifficulty(deFa.id, 'a1-0001', 'easy');

      expect(await repo.profiles(), [deFa, nlEn]);
      expect((await repo.schedules(deFa.id, reversed: false)).keys, ['a1-0001']);
      expect(await repo.schedules(deFa.id, reversed: true), isEmpty);
      expect(await repo.schedules(nlEn.id, reversed: false), isEmpty);
      final today = await repo.today(deFa.id, now);
      expect(today.reviews, 1);
      expect(today.newCards, 1);
      expect(await repo.reviewDays(deFa.id), hasLength(1));
      expect(await repo.reviewDays(nlEn.id), isEmpty);
      expect(await repo.countsByDay(nlEn.id, now, 30), isEmpty);

      await repo.updateProfile(deFa.copyWith(name: () => 'Home', dailyGoal: 15, showForms: false));
      expect((await repo.profiles()).first.name, 'Home');
      expect((await repo.profiles()).first.showForms, isFalse);

      await repo.deleteProfile(deFa.id);
      expect(await repo.profiles(), [nlEn]);
      expect(await repo.schedules(deFa.id, reversed: false), isEmpty);
      expect(await repo.reviewDays(deFa.id), isEmpty);
      expect(await repo.difficultyOverrides(deFa.id), isEmpty);
    });

    test('moves the progress of a version 2 database into profiles', () async {
      final file = _oldDatabase(2, (db) {
        db.execute('''
          INSERT INTO settings VALUES ('uiLanguage', 'fa'), ('target', 'de'), ('native', 'fa'),
            ('level', 'A2'), ('dailyGoal', '10'), ('reversed', 'true'), ('themeMode', 'dark');
          INSERT INTO review_states (card_id, target, native, reversed, state, due) VALUES
            ('a1-0001', 'nl', 'en', 0, 2, 1760000000),
            ('a1-0001', 'de', 'fa', 0, 2, 1760000000),
            ('a1-0002', 'de', 'fa', 1, 1, 1760000000);
          INSERT INTO review_logs (card_id, target, native, reversed, rating, was_new, reviewed_at)
            VALUES ('a1-0001', 'nl', 'en', 0, 3, 1, 1760000000),
                   ('a1-0001', 'de', 'fa', 0, 3, 1, 1760000000),
                   ('a1-0002', 'de', 'fa', 1, 1, 1, 1760086400);
          INSERT INTO difficulty_overrides VALUES ('a1-0001', 'de', 'advanced'),
            ('a1-0003', 'en', 'easy');
        ''');
      });

      final db = ProgressDatabase(NativeDatabase(file));
      final upgraded = ProgressRepository(db);
      final profiles = await upgraded.profiles();
      expect(profiles, hasLength(2));
      final [deFa, nlEn] = profiles;
      expect(
        deFa,
        Profile(
          id: deFa.id,
          native: 'fa',
          target: 'de',
          level: 'A2',
          dailyGoal: 10,
          reversed: true,
        ),
      );
      expect(nlEn, Profile(id: nlEn.id, native: 'en', target: 'nl'));
      expect(await upgraded.readSettings(), {
        'uiLanguage': 'fa',
        'themeMode': 'dark',
        'activeProfile': '${deFa.id}',
      });
      expect((await upgraded.schedules(deFa.id, reversed: false)).keys, ['a1-0001']);
      expect((await upgraded.schedules(deFa.id, reversed: true)).keys, ['a1-0002']);
      expect((await upgraded.schedules(nlEn.id, reversed: false)).keys, ['a1-0001']);
      expect(await upgraded.reviewDays(deFa.id), hasLength(2));
      expect(await upgraded.reviewDays(nlEn.id), hasLength(1));
      expect(await upgraded.difficultyOverrides(deFa.id), {'a1-0001': 'advanced'});
      expect(await upgraded.difficultyOverrides(nlEn.id), isEmpty);
      await db.close();
    });

    test('upgrades a version 1 database', () async {
      final file = _oldDatabase(1, (db) {
        db.execute("INSERT INTO settings VALUES ('target', 'de'), ('native', 'fa')");
      });
      final db = ProgressDatabase(NativeDatabase(file));
      final upgraded = ProgressRepository(db);
      final [profile] = await upgraded.profiles();
      await upgraded.setDifficulty(profile.id, 'a1-0001', 'easy');
      expect(await upgraded.difficultyOverrides(profile.id), {'a1-0001': 'easy'});
      await db.close();
    });

    test('an empty version 2 database gets no profile', () async {
      final db = ProgressDatabase(NativeDatabase(_oldDatabase(2, (_) {})));
      expect(await ProgressRepository(db).profiles(), isEmpty);
      await db.close();
    });

    test('stores settings', () async {
      await repo.writeSetting('uiLanguage', 'fa');
      await repo.writeSetting('uiLanguage', 'de');
      expect(await repo.readSettings(), {'uiLanguage': 'de'});
    });
  });

  test('a mistake report names the card and both words', () {
    final card = cardsForPair(
      vocabulary.cards,
      const LanguagePair(target: 'de', native: 'fa'),
    ).firstWhere((c) => c.target.word == 'die Frau');
    final url = Uri.parse(
      mistakeReportUrl(card, vocabulary.language('de'), vocabulary.language('fa')),
    );
    expect(url.toString(), startsWith(dictionaryIssuesUrl));
    expect(url.queryParameters['title'], 'Mistake in ${card.id}: die Frau');
    final body = url.queryParameters['body']!;
    expect(body, contains('Card: `${card.id}`'));
    expect(body, contains('- German: die Frau (noun, plural: Frauen)'));
    expect(body, contains('- Persian: ${card.native.word}'));
  });

  test('key forms of verbs and adjectives', () {
    final l = lookupAppLocalizations(const Locale('en'));
    VocabCard byWord(String de) => vocabulary.cards.firstWhere((c) => c.terms['de']!.word == de);
    final gehen = byWord('gehen');
    expect(keyForms(l, 'de', gehen.terms['de']!), [('ging', 'Past'), ('ist gegangen', 'Perfect')]);
    expect(keyForms(l, 'nl', gehen.terms['nl']!), [('ging', 'Past'), ('is gegaan', 'Perfect')]);
    expect(keyForms(l, 'en', gehen.terms['en']!), [('went', 'Past'), ('gone', 'Past participle')]);
    expect(keyForms(l, 'fa', gehen.terms['fa']!), [('رفت', 'Past stem'), ('رو', 'Present stem')]);
    final gross = byWord('groß');
    expect(keyForms(l, 'de', gross.terms['de']!), [
      ('größer', 'Comparative'),
      ('am größten', 'Superlative'),
    ]);
    final reflexive = vocabulary.cards.firstWhere(
      (c) => c.terms['de']!.word == 'sich erinnern' || c.terms['de']!.word == 'sich waschen',
    );
    expect(perfect('de', reflexive.terms['de']!), startsWith('hat sich '));
    expect(vocabulary.hasConjugation(gehen.id, 'de'), isTrue);
    expect(vocabulary.conjugations(gehen.id, 'fa').map((c) => c.tense), contains('past_imperfect'));
    expect(vocabulary.conjugations(gross.id, 'de'), isEmpty);
  });

  testWidgets('a verb opens its conjugation in both languages', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
    final repo = ProgressRepository(ProgressDatabase(NativeDatabase.memory()));
    final profile = (await tester.runAsync(() => repo.createProfile(native: 'fa', target: 'de')))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vocabularyProvider.overrideWithValue(vocabulary),
          progressRepositoryProvider.overrideWithValue(repo),
          initialSettingsProvider.overrideWithValue(const {}),
          initialProfilesProvider.overrideWithValue([profile]),
          speechProvider.overrideWithValue(Speech.silent()),
        ],
        child: const FlashcardApp(),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.list_alt_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'gehen');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'gehen'));
    await tester.pumpAndSettle();

    expect(find.text('Present'), findsOneWidget);
    expect(find.text('Präsens · مضارع اخباری'), findsOneWidget);
    expect(find.text('gehe'), findsOneWidget);

    await tester.tap(find.text('Persian'));
    await tester.pumpAndSettle();
    expect(find.text('مضارع اخباری · Präsens'), findsOneWidget);
    expect(find.text('می‌روم'), findsOneWidget);
    expect(find.text('gehe'), findsWidgets, reason: 'the German form stands beside the Persian');
    await tester.scrollUntilVisible(find.text('Past habitual'), 300);
    expect(find.text('Past habitual'), findsOneWidget);
  });

  phoneTest(vocabulary, 'en');
  phoneTest(vocabulary, 'fa');

  testWidgets('choose a pair, study a card, and switch the menus to Persian', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    final repo = ProgressRepository(ProgressDatabase(NativeDatabase.memory()));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vocabularyProvider.overrideWithValue(vocabulary),
          progressRepositoryProvider.overrideWithValue(repo),
          initialSettingsProvider.overrideWithValue(const {}),
          initialProfilesProvider.overrideWithValue(const []),
          speechProvider.overrideWithValue(Speech.silent()),
          srsProvider.overrideWithValue(Srs(fuzz: false)),
        ],
        child: const FlashcardApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Menus start in English.
    expect(find.text('Welcome'), findsOneWidget);
    await tester.tap(find.byKey(const Key('target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('German').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('native')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Persian').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(find.text('German from Persian'), findsOneWidget);
    expect(find.text('Persian → German'), findsOneWidget);
    final [profile] = (await tester.runAsync(repo.profiles))!;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start studying'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.text('New words today: 0'), findsOneWidget);
    expect(find.text('Again'), findsNothing);
    final firstWord = tester.widget<TermText>(find.byType(TermText).first).text;

    // Mark the word as advanced; the choice is saved for German.
    await tester.tap(find.byType(DifficultyMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced').last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect((await repo.difficultyOverrides(profile.id)).values, ['advanced']);

    await tester.tap(find.text('Show answer'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Remembered'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('New words today: 1'), findsOneWidget);
    expect(
      tester.widget<TermText>(find.byType(TermText).first).text,
      isNot(firstWord),
      reason: 'the next new word is shown while the first one waits for its next step',
    );
    expect(await repo.schedules(profile.id, reversed: false), hasLength(1));

    // Switch the menu language in Settings.
    await tester.tap(find.text('End session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Persian').last);
    await tester.pumpAndSettle();
    expect(find.text('تنظیمات'), findsWidgets);
    expect(Directionality.of(tester.element(find.text('تنظیمات').first)), TextDirection.rtl);
  });

  testWidgets('switch, add, rename and delete profiles', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    final repo = ProgressRepository(ProgressDatabase(NativeDatabase.memory()));
    final first = (await tester.runAsync(() => repo.createProfile(native: 'fa', target: 'de')))!;
    final second = (await tester.runAsync(
      () => repo.createProfile(name: 'Work', native: 'en', target: 'nl'),
    ))!;
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vocabularyProvider.overrideWithValue(vocabulary),
          progressRepositoryProvider.overrideWithValue(repo),
          initialSettingsProvider.overrideWithValue({'activeProfile': '${second.id}'}),
          initialProfilesProvider.overrideWithValue([first, second]),
          speechProvider.overrideWithValue(Speech.silent()),
        ],
        child: const FlashcardApp(),
      ),
    );
    await settle();
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('Dutch from English'), findsOneWidget);

    // Switch from the study page.
    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Persian → German').last);
    await settle();
    expect(find.text('German from Persian'), findsOneWidget);
    expect((await tester.runAsync(repo.readSettings))!['activeProfile'], '${first.id}');

    // Add a profile; it becomes the one being studied.
    await tester.tap(find.byKey(const Key('profileSwitcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('native')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('German').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('profileName')), '  Reisen ');
    await tester.tap(find.text('Create profile'));
    await settle();
    expect(find.text('Reisen'), findsOneWidget);
    expect(find.text('English from German'), findsOneWidget);
    expect((await tester.runAsync(repo.profiles))!.last.name, 'Reisen');

    // Rename it in Settings; an empty name brings back the languages.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Save'));
    await settle();
    expect(find.text('German → English'), findsWidgets);

    // Delete the first profile after confirming.
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete “Persian → German”?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(repo.profiles))!, hasLength(3));
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle();
    expect((await tester.runAsync(repo.profiles))!.map((p) => p.name), ['Work', null]);
    expect(find.text('Persian → German'), findsNothing);
  });
}

void phoneTest(Vocabulary vocabulary, String uiLanguage) {
  testWidgets('every screen fits on a phone ($uiLanguage menus)', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * tester.view.devicePixelRatio;
    addTearDown(tester.view.reset);
    final repo = ProgressRepository(ProgressDatabase(NativeDatabase.memory()));
    final profile = (await tester.runAsync(() => repo.createProfile(native: 'fa', target: 'de')))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vocabularyProvider.overrideWithValue(vocabulary),
          progressRepositoryProvider.overrideWithValue(repo),
          initialSettingsProvider.overrideWithValue({'uiLanguage': uiLanguage}),
          initialProfilesProvider.overrideWithValue([profile.copyWith(dailyGoal: 20)]),
          speechProvider.overrideWithValue(Speech.silent()),
          srsProvider.overrideWithValue(Srs(fuzz: false)),
        ],
        child: const FlashcardApp(),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(OutlinedButton).last);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(await repo.schedules(profile.id, reversed: false), hasLength(1));

    for (final icon in [
      Icons.list_alt_outlined,
      Icons.bar_chart_outlined,
      Icons.settings_outlined,
    ]) {
      await tester.tap(find.byIcon(icon));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    // The About page opens from the bottom of Settings.
    PackageInfo.setMockInitialValues(
      appName: 'Wordeck',
      packageName: 'org.osscommunity.wordeck',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('about')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('about')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
    expect(find.textContaining('1.0.0'), findsOneWidget);
  });
}

/// A progress database file as version [version] of the app left it.
File _oldDatabase(int version, void Function(sqlite.Database) fill) {
  final dir = Directory.systemTemp.createTempSync('progress');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/progress.sqlite');
  final db = sqlite.sqlite3.open(file.path);
  db.execute('''
    CREATE TABLE review_states (card_id TEXT NOT NULL, target TEXT NOT NULL,
      native TEXT NOT NULL, reversed INTEGER NOT NULL CHECK (reversed IN (0, 1)),
      state INTEGER NOT NULL, step INTEGER NULL, stability REAL NULL, difficulty REAL NULL,
      due INTEGER NOT NULL, last_review INTEGER NULL, reps INTEGER NOT NULL DEFAULT 0,
      lapses INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (card_id, target, native, reversed));
    CREATE TABLE review_logs (id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
      card_id TEXT NOT NULL, target TEXT NOT NULL, native TEXT NOT NULL,
      reversed INTEGER NOT NULL CHECK (reversed IN (0, 1)), rating INTEGER NOT NULL,
      was_new INTEGER NOT NULL CHECK (was_new IN (0, 1)), reviewed_at INTEGER NOT NULL);
    CREATE TABLE settings (key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (key));
    CREATE INDEX review_states_due ON review_states (target, native, reversed, due);
    CREATE INDEX review_logs_time ON review_logs (reviewed_at);
  ''');
  if (version >= 2) {
    db.execute(
      'CREATE TABLE difficulty_overrides (card_id TEXT NOT NULL, target TEXT NOT NULL, '
      'difficulty TEXT NOT NULL, PRIMARY KEY (card_id, target))',
    );
  }
  fill(db);
  db.execute('PRAGMA user_version = $version');
  db.close();
  return file;
}
