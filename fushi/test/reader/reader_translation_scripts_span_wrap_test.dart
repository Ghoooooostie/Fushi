import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_translation_scripts.dart';

/// BUG-3370：阅读器把句子包进 <SPAN class="fushi-senten"> 做逐句音频高亮后，
/// 段落从 <P>文本</P> 变成 <P><SPAN>文本</SPAN></P>。原收集循环用 `hasOwnText(el)`
/// 作闸门，只认「直接文本子节点」，于是 `hasOwnText(P)` 返回 false 把整段跳过，
/// 表现为「滚动/高亮后翻译停止」。本测试钉死修复：循环必须以整体 textContent 非空
/// 为闸门，且函数体内不得再以 `hasOwnText(el)` 跳过候选。
void main() {
  test('collectVisibleTargets 不再因段落文本被 SPAN 包裹而跳过', () {
    const js = kTranslationJs;

    final fnStart = js.indexOf('collectVisibleTargets: function');
    expect(fnStart, isNot(equals(-1)), reason: '源码应存在 collectVisibleTargets');

    // 1) 修复后的闸门必须存在：以整体 textContent 非空为判据。
    const String newGate = "if (!(el.textContent || '').trim()) continue;";
    expect(js, contains(newGate),
        reason: '收集循环必须以整体 textContent 非空为闸门，而非 hasOwnText');

    // 2) 该闸门位于 collectVisibleTargets 函数体内。
    final gateIdx = js.indexOf(newGate);
    expect(gateIdx, greaterThan(fnStart),
        reason: 'textContent 闸门应位于 collectVisibleTargets 内');

    // 3) collectVisibleTargets 函数体内不得再用 `hasOwnText(el)` 作跳过闸门
    //    （hasOwnText 仍保留给 candidates() 退化分支，仅循环里必须去掉）。
    final fnBody = js.substring(fnStart, gateIdx);
    expect(fnBody, isNot(contains('hasOwnText(el)')),
        reason: 'collectVisibleTargets 内不应以 hasOwnText(el) 跳过候选');
  });
}
