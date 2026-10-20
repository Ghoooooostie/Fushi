/// 阅读器「整段对照翻译」在 WebView 侧的**唯一** JS 源。
///
/// ## 形态约束：必须零插值静态化
///
/// BUG-1140 第二阶段的核心纪律：会随导航 / 设置变化的值**不得**插值进脚本源码，
/// 否则每次跨章都是一份全新字符串，WebView 的 JS 引擎得从零解析编译（`evaluateJavascript`
/// 没有 V8 code cache，实测 `evalSetupScript` 中位数 24ms 的固定开销）。所以这里整份是
/// `const`，运行期参数一律经 `install(C)` / `updateLive(patch)` 下发。守卫见
/// `test/reader/reader_engine_static_source_guard_test.dart`。
///
/// ## 译文样式为什么用 CSS 变量而不是内联 style
///
/// 用户要能调**文字颜色**与**不透明度**，且改完要**立刻生效**。若把颜色写进每个译文节点
/// 的 `style` 属性，改一次设置就得遍历全部已插节点重写一遍（几百节点 × 每次滚动都要重来）。
/// 这里把两个值写成 `documentElement` 上的 `--fushi-translation-color` /
/// `--fushi-translation-opacity`，节点只用 `var()` 引用它们：改设置只需覆盖这两个变量，
/// 一次赋值、全篇生效，且**不碰已插入的 DOM**（已算好的排版不会跳动）。
///
/// ## 段落身份
///
/// 译文段落靠 `data-fushi-translation-id` 找回插入位置。这个 id 只在**一次文档生命周期**
/// 内稳定（重排 / 换章后 DOM 重建），所以它只用于回填定位；跨章节的去重与缓存按
/// **段落正文**做 key，放在 Dart 协调层（[ReaderTranslationCoordinator]）。
library;

import 'dart:convert';

/// 定义 `window.fushiTranslation`（幂等）：收集可见段落、回填译文、切换显隐、热更样式。
const String kTranslationJs = r"""
if (!window.fushiTranslation) {
  window.fushiTranslation = (function() {
    var ID_ATTR = 'data-fushi-translation-id';
    var DONE_ATTR = 'data-fushi-translation-done';
    var FOR_ATTR = 'data-fushi-translation-for';
    var BLOCK_CLASS = 'fushi-reader-translation';
    var HIDDEN_CLASS = 'fushi-translation-hidden';
    var STYLE_ID = 'fushi-translation-style';
    var seq = 0;

    // ── 内联样式表：自包含 ──────────────────────────────────────────
    // 单独注入一段 <style>，是为了不侵入阅读器主样式表的生成管线（它按 Markdown
    // key 组织、带 <!locale> 替换，且每次设置变更都整体重算）。翻译模块自带样式，
    // 增删功能都不会在那里留下 orphan 分支。
    function ensureStyle() {
      if (document.getElementById(STYLE_ID)) return;
      var el = document.createElement('style');
      el.id = STYLE_ID;
      el.textContent = [
        '.' + BLOCK_CLASS + ' {',
        '  color: var(--fushi-translation-color, #8A8F98);',
        '  opacity: var(--fushi-translation-opacity, 0.85);',
        '  margin: 0.35em 0 0.6em;',
        '  padding-left: 0.6em;',
        '  border-left: 2px solid currentColor;',
        '  font-size: 0.92em;',
        '  line-height: 1.45;',
        '  word-break: normal;',
        '  overflow-wrap: anywhere;',
        '}',
        // 竖排书写模式（日文小说常态）下左边框会变成一堵墙：换成右边框，
        // 与 vertical-rl 的阅读方向一致。
        '[dir="rtl"] .' + BLOCK_CLASS + ', .fushi-vertical .' + BLOCK_CLASS + ' {',
        '  border-left: none;',
        '  border-right: 2px solid currentColor;',
        '  padding-left: 0;',
        '  padding-right: 0.6em;',
        '}',
        'body.' + HIDDEN_CLASS + ' .' + BLOCK_CLASS + ' { display: none !important; }'
      ].join('\n');
      document.head.appendChild(el);
    }

    function setVar(name, value) {
      document.documentElement.style.setProperty(name, value);
    }

    // ── 候选段落的选择 ──────────────────────────────────────────────
    // epub 是第三方 HTML：别人的书里段落可能是 <p>、<div>、<li>，甚至一堆 <span>。
    // 不能假设存在某个特定结构。策略是「语义标签优先，没有就退化」：
    //   1. 先取语义容器（p / li / dd / dt / blockquote / td / h1~h6）；
    //   2. 一个都没有，退化为「容器直属的那些**自身含非空文本子节点**的元素」——
    //      这样不会把整章外框（它没有直达文本）当成一段。
    function candidates(root) {
      var scope = root || document.body;
      if (!scope) return [];
      var semantic = scope.querySelectorAll(
        'p, li, dd, dt, blockquote, td, h1, h2, h3, h4, h5, h6'
      );
      if (semantic.length) {
        return Array.prototype.slice.call(semantic);
      }
      // 退化分支必须**递归**，且只收最外层那一个。
      //
      // 只看 scope.children 一层是不够的：日式小说 epub 大量用 <div> 分段并套多层
      // 容器（<body><div class="wrap"><div>正文…</div></div>），一层 filter 拿到的
      // 是外层 wrap——它没有直达文本 → 过滤后为空 → 整章扫到 0 段，界面上表现为
      // 「翻译开关开着却什么都没出现」（真机实测：raw=[]）。
      //
      // 只收最外层是为了不给每个 <span>/<ruby> 单独插一段译文：祖先里已经有人带
      // 直达文本的，就交给那个祖先。
      var all = scope.getElementsByTagName('*');
      var out = [];
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (!hasOwnText(el)) continue;
        var p = el.parentElement;
        var nested = false;
        while (p && p !== scope) {
          if (hasOwnText(p)) {
            nested = true;
            break;
          }
          p = p.parentElement;
        }
        if (!nested) out.push(el);
      }
      return out;
    }

    function hasOwnText(el) {
      var nodes = el.childNodes;
      for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        if (n.nodeType === 3 && (n.textContent || '').trim()) return true;
      }
      return false;
    }

    function ensureId(el) {
      var existing = el.getAttribute(ID_ATTR);
      if (existing) return existing;
      seq++;
      var id = 'ft-' + seq;
      el.setAttribute(ID_ATTR, id);
      return id;
    }

    // [ahead] = 前瞻窗口（px）：除可见区域外，再多收往下这么多像素内的段落。
    // 分页模式下 translateY 位移同样反映在 getBoundingClientRect 上，所以这个判定
    // 在两个 shell 里都成立。
    function inWindow(el, ahead) {
      var r = el.getBoundingClientRect();
      if (!r.height && !r.width) return false;
      return r.top < window.innerHeight + ahead && r.bottom > -ahead;
    }

    return {
      // install(C)：per-nav 参数入口。C 取 __fushiReaderConfig（同 origin）。
      applyConfig: function(C) {
        ensureStyle();
        var cfg = C || {};
        var color = cfg.translationColor;
        var opacity = cfg.translationOpacity;
        if (typeof color === 'string' && color) {
          setVar('--fushi-translation-color', color);
        }
        if (opacity !== undefined && opacity !== null) {
          setVar('--fushi-translation-opacity', String(opacity));
        }
        // 显隐是 body 上的 class 而非逐节点改 style：切换是 O(1)，
        // 也天然对「译文还没回填完成」的段落生效（它们插入时就带着正确的显示态）。
        var visible = cfg.translationVisible !== false;
        if (document.body) {
          document.body.classList.toggle(HIDDEN_CLASS, !visible);
        }
        return true;
      },

      // 热更新：只放「运行期按值读取」的键，重install 不需要。
      applyStyle: function(patch) {
        var p = patch || {};
        if (p.translationColor !== undefined) {
          setVar('--fushi-translation-color', p.translationColor);
        }
        if (p.translationOpacity !== undefined) {
          setVar('--fushi-translation-opacity', String(p.translationOpacity));
        }
        if (p.translationVisible !== undefined && document.body) {
          document.body.classList.toggle(HIDDEN_CLASS, !p.translationVisible);
        }
        return true;
      },

      // 收集「窗口内且尚未翻译」的段落。返回 JSON 串：[{id, text}, ...]
      // [limit] 是一屏内的上限：一眼望去能读到的段落数有限，再多只是把队列撑长、
      // 让用户正在看的那几段排得更靠后。
      collectVisibleTargets: function(ahead, limit) {
        var list = candidates(document.body);
        var out = [];
        for (var i = 0; i < list.length; i++) {
          if (out.length >= limit) break;
          var el = list[i];
          if (el.getAttribute(DONE_ATTR)) continue;
          // 修复（见 docs/bugs/BUG-3370-reader-translation-span-wrap-stops.md）：
          // 阅读器会把句子包进 <SPAN class="fushi-senten"> 做逐句音频高亮，段落从
          // <P>文本</P> 变成 <P><SPAN>文本</SPAN></P>。原 hasOwnText 只认「直接文本
          // 子节点」，此时返回 false 把整段跳过，表现为「滚动/高亮后翻译停止」。
          // 语义块候选（p/li/…）应以整体 textContent 是否非空为判据。
          if (!(el.textContent || '').trim()) continue;
          if (!inWindow(el, ahead)) continue;
          var text = (el.textContent || '').trim();
          // 太短的片段（页码、分隔线、"…"）译出来也没有对照价值，纯浪费往返。
          if (text.length < 2) continue;
          out.push({ id: ensureId(el), text: text });
        }
        return JSON.stringify(out);
      },

      // 回填译文：插源段落的**下一个兄弟**。
      // 位置选「兄弟」而非「子节点」是有意的——塞进源节点内部会改变它的
      // textContent，进而污染分页 / 查词 / 学习单位计数那几条链路（它们都按 TextNode
      // 遍历同一份 DOM）。作为兄弟节点，源段落的 textContent 逐字不变。
      applyTranslation: function(id, text) {
        var el = document.querySelector('[' + ID_ATTR + '="' + id + '"]');
        if (!el || !el.parentNode) return false; // 段落已被重排 / 换章带走
        var blocks = el.parentNode.children;
        for (var i = 0; i < blocks.length; i++) {
          var b = blocks[i];
          if (b.getAttribute(FOR_ATTR) === id) {
            b.parentNode.removeChild(b);
            break;
          }
        }
        var block = document.createElement('div');
        block.className = BLOCK_CLASS;
        block.setAttribute(FOR_ATTR, id);
        block.textContent = text;
        if (el.nextSibling) {
          el.parentNode.insertBefore(block, el.nextSibling);
        } else {
          el.parentNode.appendChild(block);
        }
        el.setAttribute(DONE_ATTR, '1');
        return true;
      },

      setVisible: function(visible) {
        if (!document.body) return false;
        document.body.classList.toggle(HIDDEN_CLASS, !visible);
        return true;
      },

      // 清掉全部译文 DOM 与标记，让下一次收集能重新翻 constitution 全部段落。
      // [resetIds] = 连 id 一起抹掉，用于「换了目标语言」这类必须重译的场景。
      clear: function(resetIds) {
        var blocks = document.querySelectorAll('.' + BLOCK_CLASS);
        for (var i = 0; i < blocks.length; i++) {
          var b = blocks[i];
          if (b.parentNode) b.parentNode.removeChild(b);
        }
        var marked = document.querySelectorAll('[' + DONE_ATTR + ']');
        for (var j = 0; j < marked.length; j++) {
          marked[j].removeAttribute(DONE_ATTR);
          if (resetIds) marked[j].removeAttribute(ID_ATTR);
        }
        return true;
      }
    };
  })();
}
""";

/// [kTranslationJs] 的 Dart 侧调用集合。
///
/// 与 `ReaderPaginationScripts` 同范式：每个 [Invocation] 返回一段**可在
/// `evaluateJavascript` 里直接跑**的 JS；存在性守卫（`typeof ... === 'function'`）
/// 照抄 BUG-1743 的教训——未实现该方法的 shell 上裸调会抛 TypeError，而 JS 异常在
/// 移动端一般不回传成 Dart 异常，症状只是「点了没反应」。
class ReaderTranslationScripts {
  const ReaderTranslationScripts._();

  static String installInvocation() =>
      '(window.fushiTranslation && window.fushiTranslation.applyConfig) '
      '? window.fushiTranslation.applyConfig(window.__fushiReaderConfig || {}) : false';

  /// 收集窗口内待译段落，返回 JSON 文本（`[{id, text}]`）。
  static String collectVisibleTargetsInvocation({
    int aheadPx = 600,
    int limit = 12,
  }) =>
      '(window.fushiTranslation && '
      'typeof window.fushiTranslation.collectVisibleTargets === "function") '
      '? window.fushiTranslation.collectVisibleTargets($aheadPx, $limit) : "[]"';

  /// 把译文插到目标段落下面。
  static String applyTranslationInvocation(String targetId, String text) =>
      '(window.fushiTranslation && '
      'typeof window.fushiTranslation.applyTranslation === "function") '
      '? window.fushiTranslation.applyTranslation(${_literal(targetId)}, '
      '${_literal(text)}) : false';

  /// 译文显隐（不改 DOM，只切 body 上的 class）。
  static String setVisibleInvocation(bool visible) =>
      '(window.fushiTranslation && '
      'typeof window.fushiTranslation.setVisible === "function") '
      '? window.fushiTranslation.setVisible($visible) : false';

  /// 清空译文。[resetIds] = 连段落 id 一起抹掉（换了目标语言时必须重译）。
  static String clearInvocation({bool resetIds = false}) =>
      '(window.fushiTranslation && '
      'typeof window.fushiTranslation.clear === "function") '
      '? window.fushiTranslation.clear($resetIds) : false';

  /// 样式热更新：改了颜色 / 不透明度之后直接下发，**不需要翻章**。
  static String liveUpdateInvocation({
    required String color,
    required double opacity,
    required bool visible,
  }) {
    final String patch =
        '{"translationColor":${_literal(color)},'
        '"translationOpacity":$opacity,'
        '"translationVisible":$visible}';
    return '(window.fushiTranslation && window.fushiTranslation.applyStyle) '
        '? window.fushiTranslation.applyStyle($patch) : false';
  }

  static String _literal(String value) => jsonEncode(value);
}
