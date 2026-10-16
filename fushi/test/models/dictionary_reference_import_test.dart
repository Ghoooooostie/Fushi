// v117「引用导入（不复制）」的闭环守卫。
//
// 三层各钉一层，缺哪层都能被各自的测试抓到：
//   ① 判据层：什么目录配得上「原地引用」（引错 = 登记一个读不出来的路径）；
//   ② 导入层：引用式导入真的没往 app 私有目录里复制一份，且会把旧的复制式
//      副本收走（否则用户以为省了一份体积，其实反而占了两份）；
//   ③ UI 层：入口确实存在并接上了 referenceOriginal——上一轮正栽在这一层：
//      数据层早就好了，却没有按钮，用户看到的是「什么都没发生」。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/models/dictionary_directory.dart'
    show isReferenceableDictionaryDirectory;
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('fushi_dict_reference_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  group('① isReferenceableDictionaryDirectory（引用准入判据）', () {
    Directory unpacked(String name, {bool withIndex = true}) {
      final Directory dir = Directory(path.join(tempRoot.path, 'src', name));
      dir.createSync(recursive: true);
      if (withIndex) {
        File(
          path.join(dir.path, 'index.json'),
        ).writeAsStringSync('{"title":"$name","revision":"r1"}');
      }
      File(path.join(dir.path, 'term_bank_1.json')).writeAsStringSync('[]');
      return dir;
    }

    test('顶层有 index.json 的已解压目录 → 可引用', () {
      // 这是唯一能被「原地装载」的形态：磁盘布局已经是引擎要的结构。
      expect(
        isReferenceableDictionaryDirectory(unpacked('JMdict').path),
        isTrue,
      );
    });

    test('只有 MDX / DSL → 不可引用（必须先经 native 转换）', () {
      final Directory dir = unpacked('旺文社', withIndex: false);
      File(path.join(dir.path, 'dict.mdx')).writeAsStringSync('x');
      File(path.join(dir.path, 'dict.mdd')).writeAsStringSync('x');

      expect(
        isReferenceableDictionaryDirectory(dir.path),
        isFalse,
        reason: '引用一个没转换的 mdx 等于登记了读不出来的路径',
      );
    });

    test('index.json 藏在子目录里 → 不可引用（登记的是外层目录名）', () {
      final Directory dir = unpacked('wrapper', withIndex: false);
      final Directory inner = Directory(path.join(dir.path, 'JMdict'))
        ..createSync(recursive: true);
      File(path.join(inner.path, 'index.json')).writeAsStringSync('{}');

      expect(isReferenceableDictionaryDirectory(dir.path), isFalse);
    });

    test('空目录 / 不存在的目录 → 不可引用', () {
      final Directory empty = Directory(path.join(tempRoot.path, 'empty'))
        ..createSync(recursive: true);
      expect(isReferenceableDictionaryDirectory(empty.path), isFalse);
      expect(
        isReferenceableDictionaryDirectory(
          path.join(tempRoot.path, 'nope-gone'),
        ),
        isFalse,
      );
    });
  });

  group('② 引用式导入：真的不复制', () {
    late Directory resourceRoot;
    late DictionaryRepository repo;

    Directory sourceDir(String name) {
      final Directory dir = Directory(path.join(tempRoot.path, 'src', name));
      dir.createSync(recursive: true);
      File(path.join(dir.path, 'index.json')).writeAsStringSync(
        '{"title":"$name","revision":"r1","sourceLanguage":"ja",'
        '"targetLanguage":"zh"}',
      );
      File(path.join(dir.path, 'term_bank_1.json')).writeAsStringSync('[]');
      return dir;
    }

    DictionaryImportManager manager() => DictionaryImportManager(
      dictRepo: repo,
      resourceDirectory: resourceRoot,
      formats: <String, DictionaryFormat>{},
    );

    setUp(() {
      resourceRoot = Directory(path.join(tempRoot.path, 'resource'))
        ..createSync(recursive: true);
      repo = DictionaryRepository(
        FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory())),
      );
    });

    Future<void> importReferenced(Directory dir) {
      return manager().importFromDirectory(
        directory: dir,
        progressNotifier: ValueNotifier<String>(''),
        countNotifier: ValueNotifier<int?>(null),
        totalNotifier: ValueNotifier<int?>(null),
        onImportSuccess: () {},
        lowMemoryMode: false,
        referenceOriginal: true,
      );
    }

    test('引用导入只登记路径，私有目录里不留副本', () async {
      final Directory dir = sourceDir('JMdict');

      await importReferenced(dir);

      final Dictionary installed = repo.dictionaries.single;
      expect(installed.name, 'JMdict');
      expect(installed.resourcePath, dir.path);
      expect(installed.isReferenced, isTrue);
      expect(installed.revision, 'r1', reason: 'index.json 的来源字段照旧回填');

      // 「没复制」的硬证据：默认落点不存在同名目录。
      expect(
        Directory(path.join(resourceRoot.path, 'JMdict')).existsSync(),
        isFalse,
        reason: '引用式导入还在私有目录留副本 = 白占一倍体积',
      );
      expect(dir.existsSync(), isTrue, reason: '源目录必须原样在');
    });

    test('同一目录再次引用导入：不重复登记，继承 order / 改名 / 语言覆盖', () async {
      final Directory dir = sourceDir('JMdict');
      await importReferenced(dir);

      final Dictionary first = repo.dictionaries.single;
      final Dictionary renamed = Dictionary(
        name: first.name,
        formatKey: first.formatKey,
        order: first.order,
        type: first.type,
        metadata: first.metadata,
        resourcePath: first.resourcePath,
        displayName: '简明 JMdict',
        languageOverride: 'ja',
      );
      await repo.persistDictionary(renamed);

      await importReferenced(dir);

      expect(repo.dictionaries.length, 1, reason: '同名不应变成两本');
      final Dictionary after = repo.dictionaries.single;
      expect(after.displayName, '简明 JMdict');
      expect(after.languageOverride, 'ja');
      expect(after.resourcePath, dir.path);
      expect(after.order, first.order);
    });

    test('换用引用安装时收走旧的复制式副本', () async {
      const String name = 'JMdict';
      // 假装这本先前是复制式安装的：私有目录里躺着一份占位的旧副本。
      await repo.persistDictionary(
        Dictionary(name: name, formatKey: 'yomichan', order: 3),
      );
      final Directory staleCopy = Directory(path.join(resourceRoot.path, name))
        ..createSync(recursive: true);
      File(
        path.join(staleCopy.path, 'term_bank_1.json'),
      ).writeAsStringSync('[]');

      await importReferenced(sourceDir(name));

      expect(
        staleCopy.existsSync(),
        isFalse,
        reason: '引用之后那份复制式副本成了孤儿，不删就还是双倍体积',
      );
      final Dictionary installed = repo.dictionaries.single;
      expect(installed.isReferenced, isTrue);
      expect(installed.order, 3, reason: '重导继承原有排序');
    });

    test('判据不过、又无包可转（空 / 杂物目录）时抛错、不落库', () async {
      final Directory dir = sourceDir('broken');
      File(path.join(dir.path, 'index.json')).deleteSync();

      await expectLater(importReferenced(dir), throwsA(isA<Exception>()));
      expect(repo.dictionaries, isEmpty, reason: '无东西可登记的目录不该被登记');
    });
  });

  group('②b 引用模式·原始包原地转换（zip / mdx 落回包所在目录）', () {
    late Directory resourceRoot;
    late DictionaryRepository repo;

    /// 假转换器：真 FFI 起不了。按 native 的落盘习惯把产物写进
    /// `<outputDir>/<title>/`，返回成功结果。
    FushiDictsConverter fakeConverter({bool Function(String? title)? failFor}) {
      return ({
        required String zipPath,
        required String outputDir,
        String? breadcrumbDir,
      }) async {
        final String title = path.basenameWithoutExtension(zipPath);
        if (failFor != null && failFor(title)) {
          return const FushiImportResult(
            success: false,
            title: '',
            termCount: 0,
            metaCount: 0,
            freqCount: 0,
            pitchCount: 0,
            mediaCount: 0,
            kanjiCount: 0,
            detectedType: '',
            error: 'fake failure',
          );
        }
        final Directory dir = Directory(path.join(outputDir, title));
        dir.createSync(recursive: true);
        File(path.join(dir.path, 'index.json')).writeAsStringSync(
          '{"title":"$title","revision":"r1","sourceLanguage":"ja",'
          '"targetLanguage":"zh"}',
        );
        File(path.join(dir.path, 'term_bank_1.json')).writeAsStringSync('[]');
        return FushiImportResult(
          success: true,
          title: title,
          termCount: 5,
          metaCount: 0,
          freqCount: 0,
          pitchCount: 0,
          mediaCount: 0,
          kanjiCount: 0,
          detectedType: 'term',
          error: '',
        );
      };
    }

    DictionaryImportManager manager() => DictionaryImportManager(
      dictRepo: repo,
      resourceDirectory: resourceRoot,
      formats: <String, DictionaryFormat>{},
      converterForTest: fakeConverter(),
    );

    setUp(() {
      resourceRoot = Directory(path.join(tempRoot.path, 'resource'))
        ..createSync(recursive: true);
      repo = DictionaryRepository(
        FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory())),
      );
    });

    test('静态扫描：递归收集 zip/mdx/dsl，跳过点目录与已转换的子树', () {
      final Directory root = Directory(path.join(tempRoot.path, 'scan'))
        ..createSync(recursive: true);
      File(path.join(root.path, 'B.zip')).writeAsStringSync('');
      File(path.join(root.path, 'a.mdx')).writeAsStringSync('');
      File(path.join(root.path, 'readme.txt')).writeAsStringSync('');
      final Directory sub = Directory(path.join(root.path, '牛津'))..createSync();
      File(path.join(sub.path, 'c.dsl')).writeAsStringSync('');
      // 已转换产物（带 index.json）：整棵子树跳过，里面的包也不重复转
      final Directory converted = Directory(path.join(root.path, '牛津大辞典'))
        ..createSync();
      File(path.join(converted.path, 'index.json')).writeAsStringSync('{}');
      File(path.join(converted.path, 'nested.zip')).writeAsStringSync('');
      final Directory stage = Directory(path.join(root.path, '.fushi_stage'))
        ..createSync();
      File(path.join(stage.path, 'stale.zip')).writeAsStringSync('');

      expect(
        DictionaryImportManager.referenceImportPackagePaths(root.path),
        // sort() 是码点序：大写排在小写前
        <String>[
          File(path.join(root.path, 'B.zip')).path,
          File(path.join(root.path, 'a.mdx')).path,
          File(path.join(sub.path, 'c.dsl')).path,
        ],
      );
    });

    test('原始包转换后产物落回包所在目录，私有目录零占用', () async {
      final Directory root = Directory(path.join(tempRoot.path, 'src'))
        ..createSync(recursive: true);
      File(path.join(root.path, 'COBUILD2002.mdx')).writeAsStringSync('fake');

      await manager().importFromDirectory(
        directory: root,
        progressNotifier: ValueNotifier<String>(''),
        countNotifier: ValueNotifier<int?>(null),
        totalNotifier: ValueNotifier<int?>(null),
        onImportSuccess: () {},
        lowMemoryMode: false,
        referenceOriginal: true,
      );

      final Dictionary installed = repo.dictionaries.single;
      expect(installed.name, 'COBUILD2002');
      expect(installed.resourcePath, path.join(root.path, 'COBUILD2002'));
      expect(installed.isReferenced, isTrue);
      expect(
        Directory(path.join(resourceRoot.path, 'COBUILD2002')).existsSync(),
        isFalse,
        reason: '私有目录不该出现副本——产物在用户的 Documents 里',
      );
      // 暂存区用完即删
      expect(
        Directory(path.join(root.path, '.fushi_stage')).existsSync(),
        isFalse,
      );
      // 产物可用：index.json 被读出来进了 metadata
      expect(installed.revision, 'r1');
    });

    test('重复转换：覆盖自家旧产物、继承设置；私有副本被收走', () async {
      final Directory root = Directory(path.join(tempRoot.path, 'src'))
        ..createSync(recursive: true);
      File(path.join(root.path, 'COBUILD2002.mdx')).writeAsStringSync('fake');

      // 假装这本先前是**复制式**安装的：resourcePath 空（数据在私有目录），且用户
      // 改过显示名 / 语言覆盖；私有目录里躺着占位的旧副本。
      await repo.persistDictionary(
        Dictionary(name: 'COBUILD2002', formatKey: 'yomichan', order: 3),
      );
      final Dictionary current = repo.dictionaries.single;
      await repo.persistDictionary(
        Dictionary(
          name: current.name,
          formatKey: current.formatKey,
          order: current.order,
          type: current.type,
          metadata: current.metadata,
          displayName: '牛高双解',
          languageOverride: 'ja',
        ),
      );
      final Directory staleCopy = Directory(
        path.join(resourceRoot.path, 'COBUILD2002'),
      )..createSync(recursive: true);
      File(
        path.join(staleCopy.path, 'old.term_bank.json'),
      ).writeAsStringSync('[]');

      await manager().importFromDirectory(
        directory: root,
        progressNotifier: ValueNotifier<String>(''),
        countNotifier: ValueNotifier<int?>(null),
        totalNotifier: ValueNotifier<int?>(null),
        onImportSuccess: () {},
        lowMemoryMode: false,
        referenceOriginal: true,
      );

      expect(staleCopy.existsSync(), isFalse, reason: '换引用后私有副本是孤儿，必须收走');
      final Dictionary after = repo.dictionaries.single;
      expect(after.displayName, '牛高双解');
      expect(after.languageOverride, 'ja');
      expect(after.resourcePath, path.join(root.path, 'COBUILD2002'));
    });

    test('同名但非自家产物的目录绝不覆盖（用户文件夹让位、报失败）', () async {
      final Directory root = Directory(path.join(tempRoot.path, 'src'))
        ..createSync(recursive: true);
      File(path.join(root.path, 'COBUILD2002.mdx')).writeAsStringSync('fake');
      final Directory userDir = Directory(path.join(root.path, 'COBUILD2002'))
        ..createSync();
      final File userFile = File(path.join(userDir.path, 'notes.txt'))
        ..writeAsStringSync('重要笔记');

      await manager().importFromDirectory(
        directory: root,
        progressNotifier: ValueNotifier<String>(''),
        countNotifier: ValueNotifier<int?>(null),
        totalNotifier: ValueNotifier<int?>(null),
        onImportSuccess: () {},
        lowMemoryMode: false,
        referenceOriginal: true,
      );

      expect(userFile.existsSync(), isTrue, reason: '用户的同名文件夹一个字节都不能动');
      expect(repo.dictionaries, isEmpty, reason: '被拒的包不登记');
    });

    DictionaryImportManager managerWithFailingConverter(String title) =>
        DictionaryImportManager(
          dictRepo: repo,
          resourceDirectory: resourceRoot,
          formats: <String, DictionaryFormat>{},
          converterForTest: fakeConverter(failFor: (String? t) => t == title),
        );

    test('单包失败不拖垮批量，其余照常登记', () async {
      final Directory root = Directory(path.join(tempRoot.path, 'src'))
        ..createSync(recursive: true);
      File(path.join(root.path, 'bad.mdx')).writeAsStringSync('fake');
      File(path.join(root.path, 'good.mdx')).writeAsStringSync('fake');

      await managerWithFailingConverter('bad').importFromDirectory(
        directory: root,
        progressNotifier: ValueNotifier<String>(''),
        countNotifier: ValueNotifier<int?>(null),
        totalNotifier: ValueNotifier<int?>(null),
        onImportSuccess: () {},
        lowMemoryMode: false,
        referenceOriginal: true,
      );

      final List<Dictionary> names = repo.dictionaries;
      expect(names.length, 1);
      expect(names.single.name, 'good');
    });
  });

  group('③ UI 接线守卫（入口存在且真的走引用分支）', () {
    String read(String relative) => File(relative).readAsStringSync();

    test('词典页三处入口都挂着同一个处理函数', () {
      final String src = read(
        'lib/src/pages/implementations/dictionary_dialog_page.dart',
      );

      // 桌面图标栏 + Material action bar + 溢出菜单（移动端与窄屏共用），一处都不能
      // 少：上一轮正是数据层齐了却一个按钮都没有，用户看不到任何变化。
      final int entryPoints = RegExp(
        r'(?:onTap|action): _importReferencedDictionaryFolder,',
      ).allMatches(src).length;
      expect(
        entryPoints,
        3,
        reason:
            '桌面图标栏 / action bar / 溢出菜单三处入口必须都在，'
            '少了说明某个形态下用户还是找不到按钮',
      );
      expect(
        src.contains('t.dict_import_reference'),
        isTrue,
        reason: '按钮文案必须来自 i18n',
      );
      expect(
        src.contains('referenceOriginal: referenced'),
        isTrue,
        reason: '处理函数必须把 referenceOriginal 传下去，否则按钮点了照样复制',
      );
    });

    test('UI 不做准入预检：原始包也能走引用入口（分流交给导入器）', () {
      final String src = read(
        'lib/src/pages/implementations/dictionary_dialog_page.dart',
      );
      expect(
        src.contains('isReferenceableDictionaryDirectory'),
        isFalse,
        reason:
            'UI 预检会把「一堆原包」的目录挡在门外；'
            '能不能原地用、要不要转换是导入器的职责',
      );
      expect(
        src.contains('t.dict_import_reference_not_unpacked'),
        isFalse,
        reason: '引用模式已支持原地转换，这条报错文案退役了',
      );
    });

    test('详情页把「引用安装」与源路径显示出来', () {
      final String src = read(
        'lib/src/pages/implementations/dictionary_manager_panels.dart',
      );
      expect(
        src.contains('dictionary.isReferenced'),
        isTrue,
        reason: '引用安装的词典必须看得出自己部在哪里',
      );
      expect(
        src.contains('dictionary.resourcePath!.trim()'),
        isTrue,
        reason: '详情要显示源路径，否则用户不知道自己的词典落在哪',
      );
    });

    test('判据只有一个实现（引擎层），导入器不再自己拼 index.json', () {
      final String manager = read(
        'lib/src/models/dictionary_import_manager.dart',
      );
      expect(
        manager.contains('isReferenceableDictionaryDirectory(directory.path)'),
        isTrue,
      );
      expect(
        RegExp(
          r"path\.join\(directory\.path, 'index\.json'\)",
        ).hasMatch(manager),
        isFalse,
        reason: '判据散两份就会出现「UI 说能引用、导入器说不认识」',
      );
    });
  });
}
