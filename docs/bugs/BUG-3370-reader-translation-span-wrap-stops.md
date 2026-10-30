## BUG-3370 · 阅读器对照翻译：句子被 SPAN 包裹后收集停止（滚动/高亮后不翻译）
- **报告**：2026-10-20（用户：「换章节的时候我总是要重新打开小说才能重新翻译」「现在没换章，也不翻译了……后面也都没有翻译了」；设备 魅族20 `381QYGEM226CZ`，dev 包 `app.fushi.reader.dev`，build 2.10.0）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/reader/reader_translation_scripts.dart`：`collectVisibleTargets` 循环闸门 `if (!hasOwnText(el)) continue;`——`hasOwnText` 只认**直接文本子节点**）
- **[x] ① 已修复** — 收集循环闸门由 `!hasOwnText(el)` 改为 `!(el.textContent||'').trim()`（分支 `reader-translation`，2.10.0/develop）
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_translation_scripts_span_wrap_test.dart`（断言循环以整体 `textContent` 非空为闸门、函数体内不再用 `hasOwnText(el)` 跳过候选）
- **编号**：与 [BUG-3369](BUG-3369-reader-translation-stops-halfway.md)（翻译失败不重试）是同一现场分出的两个独立根因；本号在 `new` 时因基线只见到 3368 而被误赋 3369，发现与已提交的 BUG-3369 撞号后顺延至 3370。
- **备注**：`[sentence-audio-hl] highlightCue` 日志证实阅读器确实在把句子包进 `<SPAN class="fushi-senten">` 做逐句音频高亮，是触发面。

### 根因

`collectVisibleTargets(ahead, limit)` 扫描候选段落（p/li/…）时，对每一个元素先过一道闸门：

```js
if (!hasOwnText(el)) continue;
```

而 `hasOwnText` 的定义是「元素自身含**直接文本子节点**」：

```js
function hasOwnText(el) {
  var nodes = el.childNodes;
  for (var i = 0; i < nodes.length; i++) {
    if (n.nodeType === 3 && (n.textContent || '').trim()) return true;
  }
  return false;
}
```

开章时段落是纯 `<P>文本</P>`，`hasOwnText(P)` 为 true → 前 ~17–18 段正常翻译。
但阅读器会调用逐句音频高亮（`sentence-audio-hl`），把句子包进
`<SPAN class="fushi-senten">`，段落变成 `<P><SPAN>文本</SPAN></P>`。此时 P 的**直接子节点是 SPAN、没有直达文本节点**，`hasOwnText(P)` 返回 false → 整段被 `continue` 掉。

而且这道闸门**没有计数**（旧诊断里 `d/w/s` 都看不出它），所以它把元素悄悄吞掉，
在日志里伪装成「`inWindow` 失效、`w` 恒为 0」，与坐标系错乱高度相似——这是定位耗时
的主因。真机探针最终确认：可见的 `<P>` 仍在候选集里（探针 `pidx=94`）、坐标也完全在
视口内，却因为无直达文本被跳过。

诊断证据（修复前，魅族20）：
```
{"c":407,"d":18,"w":0,...}                       // 窗口内待译恒为 0
探针 pidx=94 命中可见 SPAN「声は出なかったが」的父 <P>，t=500 在视口内
 → 候选集与用户看到的是同一棵 DOM，问题在收集闸门，而非坐标系/iframe/shadow
```

### 修复

语义块候选（p/li/…）应当以其**整体 textContent** 是否有可译内容来判据，而非是否含
直达文本节点。把闸门从「要求直达文本节点」放宽为「整体文本非空」：

```js
// 修复前
if (!hasOwnText(el)) continue;
// 修复后
if (!(el.textContent || '').trim()) continue;
```

`hasOwnText` 这个 helper 本身保留——它仍在 `candidates()` 的退化分支里正确地区分
「最外层含文本的元素」，只在**收集循环**里被替换。空段 / 纯图（textContent 为空或全
空白）依旧跳过，不会把整章外框当一段误译。

### 待验证（真机，已通过）

- 魅族20 装修复版（2.10.0 debug APK），打开《无职转生》开着翻译，往下翻到之前不翻译的位置。
- 修复后探针：`{"c":407,"d":46,"w":10,...}` 且 `[fushi-translation] scan targets=10`
  带真实日文段落（ft-47…ft-56）发往翻译引擎；`nt:132` 印证旧闸门确实在吞掉被 SPAN
  包裹的段落。
- 对照修复前 `w` 恒为 0、整页无新译文。结论：翻译在滚动/高亮后恢复正常。
