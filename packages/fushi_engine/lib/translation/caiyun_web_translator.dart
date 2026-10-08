/// 彩云小译**网页版**接口（免 key）：固定 web token + browser_id 换一次性 JWT，
/// 再拿 JWT 发起翻译；返回的 `target` 是混淆过的 base64，要还原才能读。
///
/// ## 形态说明（重要）
///
/// 这里走的是彩云网页版（`fanyi.caiyunapp.com`）在用的内部接口，不是它需要签约的
/// 开放 API。选它的唯一理由是**用户零配置**：不用注册、不用填 token，装上就能译。
/// 代价是它是非公开契约——服务端一改就可能失效，届时要原样报出 bad_response 让上层
/// `bad_response`，而不是把失败吞掉伪装成「网络不好」。
///
/// 参数取值逐条对齐来源实现（Hoshi `CaiyunWebTranslator.kt`，它自己也注明对齐
/// LunaTranslator `caiyun.py`），包括 `request_id` 这个看起来没用的字面量：网页端
/// 就是这么发的，少了会影响结果。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fushi_engine/translation/translation_models.dart';
import 'package:fushi_engine/translation/translator.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:http/http.dart' as http;

/// 单次 HTTP 往返的整体时限（JWT 除外，见 [_requestJwt]）。
///
/// 翻译是一来一回的短请求，不像 AI 推理那样会「思考很久」，给 20s 足够；留得再宽
/// 只会让队列里后续段落跟着一起卡住。连接建立那一段另外由 `kAppHttpConnectionTimeout`
/// 管（见 `app_http.dart`）。
const Duration kCaiyunRequestTimeout = Duration(seconds: 20);

/// 网页接口要求的用户代理：少了它，同样的参数会被当成非浏览器来源挡掉。
const String kCaiyunWebUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36';

/// [TranslationEngineId.caiyun] 的实现。
class CaiyunWebTranslator extends Translator {
  CaiyunWebTranslator({
    http.Client? client,
    this.requestTimeout = kCaiyunRequestTimeout,
  }) : _client = client ?? createAppHttpIoClient();

  static const String _apiBase = 'https://api.interpreter.caiyunai.com';

  /// 网页端写死的长期 token。它本身不能直接翻译，只用来**换 JWT**。
  ///
  /// 这不是任何用户的私钥：它随网页公开发布，任何人在浏览器里都能看到。真正的短期
  /// 凭据是 JWT，且不落盘（见 [_jwt]）。
  static const String _webToken = 'token:qgemv4jr1y38jyq6vhvi';

  /// 网页端本地生成的设备标识，同样随请求一起发。
  static const String _browserId = 'beba19f9d7f10c74c98334c9e8afcd34';

  final http.Client _client;

  /// 单次往返的整体时限。
  final Duration requestTimeout;

  /// 换成的一次性 JWT。**只在内存里**，不进偏好、不进日志。缓存它是为了减少一次
  /// 往返；失效时由调用方通过 [reset] 清掉重取。
  String? _jwt;

  @override
  TranslationEngineId get id => TranslationEngineId.caiyun;

  @override
  void reset() => _jwt = null;

  @override
  Future<void> close() async => _client.close();

  @override
  Future<TranslationResult> translate(
    String text, {
    TranslationTargetLanguage target =
        TranslationTargetLanguage.simplifiedChinese,
  }) async {
    final String jwt = await _requestJwt();
    final http.Response response = await _post(
      '$_apiBase/v1/translator',
      headers: <String, String>{..._baseHeaders, 't-authorization': jwt},
      body: jsonEncode(<String, Object?>{
        'source': text,
        // auto = 让服务端检测源语言（见 TranslationTargetLanguage 文档）。
        'trans_type': 'auto2${target.storageValue}',
        'request_id': 'web_fanyi',
        'media': 'text',
        'os_type': 'web',
        'dict': true,
        'cached': true,
        'replaced': true,
        'detect': true,
        'browser_id': _browserId,
      }),
    );

    final Map<String, Object?> payload = _decodeBody(response);
    final Object? rawTarget = payload['target'];
    if (rawTarget is! String || rawTarget.isEmpty) {
      throw const TranslationFailure('bad_response');
    }

    final String translated = _decodeTarget(rawTarget);
    if (translated.trim().isEmpty) {
      // 空串往下走只会变成 UI 上的一块空白，浪费了一次已经成功的往返。
      throw const TranslationFailure('empty_response');
    }

    return TranslationResult(
      sourceText: text,
      translatedText: translated,
      engineId: id,
      targetLanguage: target,
    );
  }

  /// 用长期 token 换一个短期 JWT。
  ///
  /// 取到之后缓存在 [_jwt]：阅读器是「翻一次页面译十几段」的用法，每段都换一次等于
  /// 把请求量翻倍。JWT 过期表现为 `401`，由调用方 [reset] 后重取。
  Future<String> _requestJwt() async {
    final String? cached = _jwt;
    if (cached != null && cached.isNotEmpty) return cached;

    final http.Response response = await _post(
      '$_apiBase/v1/user/jwt/generate',
      headers: _baseHeaders,
      body: jsonEncode(<String, Object?>{'browser_id': _browserId}),
    );
    final Map<String, Object?> payload = _decodeBody(response);
    final Object? jwt = payload['jwt'];
    if (jwt is! String || jwt.isEmpty) {
      throw const TranslationFailure('bad_response');
    }
    _jwt = jwt;
    return jwt;
  }

  /// 每个请求都带的基础头：网页端用来表明自己是网页端。
  Map<String, String> get _baseHeaders => <String, String>{
    'accept': 'application/json, text/plain, */*',
    'app-name': 'xy',
    'content-type': 'application/json; charset=UTF-8',
    'origin': 'https://fanyi.caiyunapp.com',
    'os-type': 'web',
    'referer': 'https://fanyi.caiyunapp.com/',
    'user-agent': kCaiyunWebUserAgent,
    'x-authorization': _webToken,
  };

  Future<http.Response> _post(
    String url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    try {
      return await _client
          .post(Uri.parse(url), headers: headers, body: body)
          .timeout(requestTimeout);
    } on TimeoutException {
      throw const TranslationFailure('network_error');
    } on TranslationFailure {
      rethrow;
    } catch (_) {
      // 网络类异常一律收敛成同一个码：上层按码决定是否重试，不需要知道底层是
      // SocketException 还是 TLS handshake failed。也不回显原始异常——它可能含完整
      // URL / 请求体，而 header 里带着 token。
      throw const TranslationFailure('network_error');
    }
  }
}

Map<String, Object?> _decodeBody(http.Response response) {
  if (response.statusCode < 200 || response.statusCode > 299) {
    // 401/403 由上层识别并 reset 重试（见 Translator.reset）；429 与 5xx 走
    // TranslationFailure.isRetryable。
    throw TranslationFailure('http_${response.statusCode}');
  }
  try {
    final Object? decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?>) {
      throw const TranslationFailure('bad_response');
    }
    return decoded;
  } on TranslationFailure {
    rethrow;
  } catch (_) {
    throw const TranslationFailure('bad_response');
  }
}

/// 还原彩云 `target` 字段：它是拿一张**置换过的字母表**做的一次 base64，不是加密。
///
/// 两张表字母集合完全相同，只是后半段整体前移了 13 位（ROT13 那一套），所以只需要
/// 逐字符查表映射回标准 base64 字母表，再正常解码。
String _decodeTarget(String cipherText) {
  const String normalKey =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=.+-_/';
  const String cipherKey =
      'NOPQRSTUVWXYZABCDEFGHIJKLMnopqrstuvwxyzabcdefghijklm0123456789=.+-_/';

  final Map<int, int> mapping = <int, int>{};
  for (int i = 0; i < cipherKey.length; i++) {
    mapping[cipherKey.codeUnitAt(i)] = normalKey.codeUnitAt(i);
  }

  final StringBuffer restored = StringBuffer();
  for (int i = 0; i < cipherText.length; i++) {
    final int unit = cipherText.codeUnitAt(i);
    restored.writeCharCode(mapping[unit] ?? unit);
  }

  try {
    // normalize 补齐尾部 padding：网页端不一定带上 `=`，而 base64.decode 要求长度
    // 是 4 的倍数，少一个就是 FormatException。
    return utf8.decode(base64.decode(base64.normalize(restored.toString())));
  } catch (_) {
    // 解不出来说明服务端换了编码方式——这正是不公开契约要付的代价。这里明确报出
    // bad_response，绝不退化成「返回原文」：那样用户会以为翻译成功了，只是「没变化」，
    // 症状比一次干净的失败难查得多。
    throw const TranslationFailure('bad_response');
  }
}
