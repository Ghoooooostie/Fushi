import 'dart:convert';

import 'package:fushi_engine/translation/caiyun_web_translator.dart';
import 'package:fushi_engine/translation/translation_client.dart';
import 'package:fushi_engine/translation/translation_models.dart';
import 'package:fushi_engine/translation/translator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// 造一个彩云那种「置换字母表 base64」密文。
///
/// 与被测的解码方向相反：先标准 base64 编码，再逐字符换成混淆表同一位的字符。用它
/// 当 fixture，比写死一段密文更能说明「两边互为逆运算」——一旦生产端那两张表被改动，
/// 这条 util 跟着变，测试仍然是对的那半边。
String _scrambleTarget(String plain) {
  const String normalKey =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=.+-_/';
  const String cipherKey =
      'NOPQRSTUVWXYZABCDEFGHIJKLMnopqrstuvwxyzabcdefghijklm0123456789=.+-_/';
  final Map<int, int> forward = <int, int>{};
  for (int i = 0; i < normalKey.length; i++) {
    forward[normalKey.codeUnitAt(i)] = cipherKey.codeUnitAt(i);
  }
  final String b64 = base64Encode(utf8.encode(plain));
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < b64.length; i++) {
    final int unit = b64.codeUnitAt(i);
    out.writeCharCode(forward[unit] ?? unit);
  }
  return out.toString();
}

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

/// 假彩云服务端：记录每一次请求，可编排「下一次翻译该怎么失败」。
class _MockCaiyun {
  int jwtCalls = 0;
  int translateCalls = 0;

  /// 排队的翻译响应状态码；队列用完之后回到 200（用于「第一次 401，之后正常」）。
  final List<int> scriptedStatuses = <int>[];

  /// 排队的 `target` 明文（会经 [_scrambleTarget] 混淆后发出）。
  final List<String> scriptedTargets = <String>[];

  final List<http.Request> requests = <http.Request>[];
  bool omitTarget = false;

  /// 原样作为 `target` 返回，绕过 [_scrambleTarget]。用来喂「解不开」的病态输入——
  /// 注意不能拿 `@@@@not-base64@@@@` 这种串：它里面的字母全在合法 base64 表里，
  /// 实际会被成功解码成一个非空的乱码，测不出想要的不变量。
  String? forcedRawTarget;

  Future<http.Response> handle(http.Request req) async {
    requests.add(req);
    if (req.url.path.endsWith('/v1/user/jwt/generate')) {
      jwtCalls++;
      return _json(<String, Object?>{'jwt': 'jwt-$jwtCalls'});
    }
    translateCalls++;
    if (scriptedStatuses.isNotEmpty) {
      final int status = scriptedStatuses.removeAt(0);
      if (status != 200) return http.Response('nope', status);
    }
    if (omitTarget) return _json(<String, Object?>{});
    final String? raw = forcedRawTarget;
    if (raw != null) return _json(<String, Object?>{'target': raw});
    final String plain = scriptedTargets.isNotEmpty
        ? scriptedTargets.removeAt(0)
        : '默认译文';
    return _json(<String, Object?>{'target': _scrambleTarget(plain)});
  }

  http.Request get jwtRequest => requests.firstWhere(
    (http.Request r) => r.url.path.endsWith('/v1/user/jwt/generate'),
  );

  http.Request get translateRequest => requests.firstWhere(
    (http.Request r) => r.url.path.endsWith('/v1/translator'),
  );

  Map<String, Object?> get translateBody =>
      jsonDecode(translateRequest.body) as Map<String, Object?>;
}

CaiyunWebTranslator _translator(_MockCaiyun server) =>
    CaiyunWebTranslator(client: MockClient(server.handle));

TranslationClient _client(_MockCaiyun server) => TranslationClient(
  translators: <TranslationEngineId, Translator>{
    TranslationEngineId.caiyun: _translator(server),
  },
);

void main() {
  group('彩云：wire 形状', () {
    test('先换 JWT 再译，两段请求都对得上网页端', () async {
      final _MockCaiyun server = _MockCaiyun();
      final CaiyunWebTranslator translator = _translator(server);

      final TranslationResult result = await translator.translate('原文');

      expect(server.requests, hasLength(2));
      expect(
        server.jwtRequest.url.toString(),
        'https://api.interpreter.caiyunai.com/v1/user/jwt/generate',
      );
      expect(server.jwtRequest.headers['x-authorization'], isNotNull);
      expect(
        jsonDecode(server.jwtRequest.body),
        containsPair('browser_id', isNotEmpty),
      );

      // 翻译请求必须带上刚换来的 JWT——这是网页版接口唯一的短期凭据。
      expect(server.translateRequest.headers['t-authorization'], 'jwt-1');

      final Map<String, Object?> body = server.translateBody;
      expect(body['source'], '原文');
      expect(body['trans_type'], 'auto2zh');
      expect(body['request_id'], 'web_fanyi');
      expect(body['media'], 'text');
      expect(body['os_type'], 'web');

      expect(result.translatedText, '默认译文');
      expect(result.engineId, TranslationEngineId.caiyun);
      expect(
        result.targetLanguage,
        TranslationTargetLanguage.simplifiedChinese,
      );
    });

    test('目标语言跟着变：English → auto2en', () async {
      final _MockCaiyun server = _MockCaiyun();
      final CaiyunWebTranslator translator = _translator(server);

      await translator.translate(
        '原文',
        target: TranslationTargetLanguage.english,
      );

      expect(server.translateBody['trans_type'], 'auto2en');
    });

    test('JWT 同会话内复用，不每段重取', () async {
      final _MockCaiyun server = _MockCaiyun();
      final CaiyunWebTranslator translator = _translator(server);

      await translator.translate('第一段');
      await translator.translate('第二段');

      expect(server.jwtCalls, 1);
      expect(server.translateCalls, 2);
    });
  });

  group('彩云：译文解码', () {
    test('还原的是原文，不是密文也不是乱码', () async {
      final _MockCaiyun server = _MockCaiyun()
        ..scriptedTargets.add('这是一段简体中文译文');
      final CaiyunWebTranslator translator = _translator(server);

      final TranslationResult result = await translator.translate('本文');

      expect(result.translatedText, '这是一段简体中文译文');
    });

    test('解不开就报 bad_response，绝不拿原文冒充译文', () async {
      final _MockCaiyun server = _MockCaiyun();
      // 长度既不是 4 的倍数、字符也不在表内：任何一路 base64 解码都必然失败。
      server.forcedRawTarget = 'a';
      final TranslationClient client = _client(server);

      await expectLater(
        client.translate(TranslationEngineId.caiyun, '本文'),
        throwsA(
          isA<TranslationFailure>().having(
            (TranslationFailure e) => e.message,
            'message',
            'bad_response',
          ),
        ),
      );
    });
  });

  group('彩云：失败与重试', () {
    test('401 之后清掉 JWT 重取并重试一次', () async {
      final _MockCaiyun server = _MockCaiyun();
      server.scriptedStatuses.add(401);
      server.scriptedTargets.add('重试后的译文');
      final TranslationClient client = _client(server);

      final TranslationResult result = await client.translate(
        TranslationEngineId.caiyun,
        '原文',
      );

      expect(result.translatedText, '重试后的译文');
      expect(server.jwtCalls, 2); // 过期 → 重取
      expect(server.translateCalls, 2); // 只重试一层
    });

    test('5xx 重试一层后仍失败，原样抛出 http_500', () async {
      final _MockCaiyun server = _MockCaiyun();
      server.scriptedStatuses.addAll(<int>[500, 500]);
      final TranslationClient client = _client(server);

      await expectLater(
        client.translate(TranslationEngineId.caiyun, '原文'),
        throwsA(
          isA<TranslationFailure>().having(
            (TranslationFailure e) => e.message,
            'message',
            'http_500',
          ),
        ),
      );
      expect(server.translateCalls, 2);
    });

    test('400 不重试：重发同样的坏请求只会得到同样的结果', () async {
      final _MockCaiyun server = _MockCaiyun();
      server.scriptedStatuses.add(400);
      final TranslationClient client = _client(server);

      await expectLater(
        client.translate(TranslationEngineId.caiyun, '原文'),
        throwsA(
          isA<TranslationFailure>().having(
            (TranslationFailure e) => e.message,
            'message',
            'http_400',
          ),
        ),
      );
      expect(server.translateCalls, 1); // 没有多余的一次
    });

    test('响应缺 target：bad_response', () async {
      final _MockCaiyun server = _MockCaiyun();
      server.omitTarget = true;
      final CaiyunWebTranslator translator = _translator(server);

      await expectLater(
        translator.translate('原文'),
        throwsA(
          isA<TranslationFailure>().having(
            (TranslationFailure e) => e.message,
            'message',
            'bad_response',
          ),
        ),
      );
    });

    test('空原文直接判失败，一个请求都不发', () async {
      final _MockCaiyun server = _MockCaiyun();
      final TranslationClient client = _client(server);

      await expectLater(
        client.translate(TranslationEngineId.caiyun, '   '),
        throwsA(
          isA<TranslationFailure>().having(
            (TranslationFailure e) => e.message,
            'message',
            'empty_response',
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('没装配的引擎：engine_not_configured', () async {
      final TranslationClient client = TranslationClient(
        translators: const <TranslationEngineId, Translator>{},
      );

      await expectLater(
        client.translate(TranslationEngineId.llm, '原文'),
        throwsA(
          isA<TranslationFailure>().having(
            (TranslationFailure e) => e.message,
            'message',
            'engine_not_configured',
          ),
        ),
      );
    });
  });

  group('模型：持久化键名不漂移', () {
    test('storageValue 认得回，认不出的回落到默认值', () {
      expect(TranslationEngineId.fromStorage('llm'), TranslationEngineId.llm);
      expect(
        TranslationEngineId.fromStorage('以后可能改名的坏值'),
        TranslationEngineId.caiyun,
      );
      expect(TranslationEngineId.fromStorage(null), TranslationEngineId.caiyun);

      expect(
        TranslationTargetLanguage.fromStorage('en'),
        TranslationTargetLanguage.english,
      );
      expect(
        TranslationTargetLanguage.fromStorage(null),
        TranslationTargetLanguage.simplifiedChinese,
      );
    });
  });
}
