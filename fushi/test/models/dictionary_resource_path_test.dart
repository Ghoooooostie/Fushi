import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

void main() {
  group('Dictionary.resourcePath（v117 引用外部目录安装）', () {
    test('默认 null = 复制式安装，isReferenced 为 false', () {
      final Dictionary d = Dictionary(
        name: 'LDOCE5',
        formatKey: 'yomichan',
        order: 1,
      );
      expect(d.resourcePath, isNull);
      expect(d.isReferenced, isFalse);
    });

    test('空串 / 纯空白不算引用', () {
      // 入库前会被归一成 null，所以读回来也不该被判成引用——否则删除链路会拿一个
      // 空路径去「删源目录」。
      final Dictionary d = Dictionary(
        name: 'x',
        formatKey: 'yomichan',
        order: 1,
        resourcePath: '   ',
      );
      expect(d.isReferenced, isFalse);
    });

    test('copyWith 必须带上 resourcePath', () {
      // 这是本列最容易踩的静默故障：_dictionaryToCompanion 对每一列都写 Value(...)，
      // 所以「只想改 type / order 却漏带 resourcePath」= 往 DB 里显式写 NULL，
      // 词典静默退化到默认落点，而那个落点下并没有数据。
      final Dictionary d = Dictionary(
        name: 'OALDPEX',
        formatKey: 'yomichan',
        order: 2,
        resourcePath: '/sdcard/Documents/Dict/OALDPEX',
      );
      final Dictionary copied = d.copyWith(type: DictionaryType.kanji);

      expect(copied.type, DictionaryType.kanji);
      expect(
        copied.resourcePath,
        '/sdcard/Documents/Dict/OALDPEX',
        reason: 'copyWith 漏带 resourcePath 会让引用路径被写成 NULL',
      );
      expect(copied.isReferenced, isTrue);
    });

    test('copyWith 与用户设置互不覆盖', () {
      // 引用路径是「安装事实」，改名 / 内容语言覆盖是「用户设置」，两者不能互相抹。
      final Dictionary d = Dictionary(
        name: 'n',
        formatKey: 'yomichan',
        order: 1,
        displayName: '朗文',
        languageOverride: 'ja',
        resourcePath: '/sdcard/Dict/n',
      );
      final Dictionary copied = d.copyWith(order: 9);

      expect(copied.order, 9);
      expect(copied.displayName, '朗文');
      expect(copied.languageOverride, 'ja');
      expect(copied.resourcePath, '/sdcard/Dict/n');
    });
  });
}
