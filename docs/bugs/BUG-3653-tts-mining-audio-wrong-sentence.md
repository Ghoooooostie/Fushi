## BUG-3653 · TTS 朗读制卡：句子音频按坐标定位落到**另一句**（两套归一化不同源）
- **报告**：2026-10-21（用户：TTS 朗读 + 制卡，「制卡的原句和音频不一致……音频根本是另外一句」）
- **真实性**：✅ 真 bug。**真机 logcat 铁证**（取证日志 `[mine-audio]`，《無職転生》第 25 章）：
  ```
  [mine-audio] idx=10568 ms=[0,5456) section=25 span=[1269,28]
  card="こんな土地に閉じ込められれば、魔族だって戦争を起こすだろう。"
  unit[10568]="ルイジェルドは走りだしてから、五分もしないうちに帰ってくる。" match=[1269,1297) section=25
  ```
  卡片句的归一化区间 `span=[1269,28]` 与朗读单元的 `match=[1269,1297)` **完全重合**，
  可那个单元念的是**毫不相干的另一句** —— 不是匹配算法选错，是**尺子（坐标系）不对**。
  - 根因：定位一路走 `CollectionAudioMatcher.findPlaybackRange(cues, sectionIndex,
    normCharOffset, normCharLength)`（`fushi/lib/src/media/audiobook/mining_audio_clip.dart:365`），
    把「阅读器 WebView 的 matchable 坐标」拿去比对朗读分句 cue 的 `textFragmentId`
    （`tts_read_along.dart:255` 用 `TtsPlanSentence.matchStart/matchEnd` 编码）。
    而这两套归一化**不同源**：
    - 阅读器：`_cachedMatchableSentenceRange`（`audiobook.part.dart:1088`）来自 JS 的
      `sentenceMatchableOffset`；
    - 朗读分句：`tts_book_plan.dart:137` 由 `AudioTextNormalizer.normalizeConcat` 对
      `chapterPlainTextWithRuby(section)` 整章归一化得到。
    ruby（振り仮名）/ 图注 / 空白 / HTML 实体的处理不同 → **坐标随章内位置漂移**，
    到第 1269 字时已经落到完全无关的句子上。
  - 触发面：只对 **TTS 朗读会话**成立（录音有声书的 cue 来自 ASR 对齐、与阅读器同源，
    故不受影响）。
  - 排除的误判：`mergeShortTtsSentences` 合并短句（minLength=16）**不是**本次根因——
    日志里 card 与 unit 两句互不包含，不是「多念了几句」而是「换了句子」。
- **[x] ① 已修复** —
  - `tts_read_along.dart`：新增 `sentenceRangeByText({sentence, sectionIndex, normCharOffset})`
    ——**按正文文本定位**朗读单元（正文文本是两边唯一的同源锚点），坐标只用来给「同一句
    在书里出现多次」消歧（取离 normCharOffset 最近的那个）；精确命中优先，其次取「单元
    文本包含该句」（合并短句的情形）。另加 `unitCoversSentence(index, sentence)` 作信任校验。
  - `mining.part.dart`：新增 `_ttsSentenceAudioRange()`——TTS 会话里先用文本定位的结果
    覆盖坐标定位；文本也定位不到就用 `unitCoversSentence` 校验坐标结果，**不可信则拒绝
    这段音频**（`ReaderFushi.mineEntry.sentenceAudioMismatch` 日志 + 无音频 toast + 清掉
    `CardSourceLink` 的音频区间），绝不给一张「念别的句子」的卡。
  - 顺带修掉同源的第二个偏差：`ensureSentenceAudio` 现在连**真实时长**一起返回
    （`TtsSentenceAudio{path, durationMs}`）——cue 上的 `endMs` 在合成前是按字数估的
    （`estimateDurationMs`），真实值要等 `TtsSegmentReady` 事件异步写回 cue，而裁剪区间
    是 `ensure` 返回时就定下来的；现在用真实时长收口（估短了后半句没声、估长了多裁空白）。
  - 这是根因修复而非补丁：错的不是「某个坐标算错一位」，而是**用了一套与朗读分句不同
    源的坐标去定位**；修的是定位依据（改走正文文本），不是给坐标加偏移量。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/audiobook/tts/tts_read_along_sentence_audio_test.dart`：
    `sentenceRangeByText` 在「坐标故意指向念别的句子的单元」时仍按文本落到正确单元
    （用真机那两句复刻）+ `unitCoversSentence` 挡住错配 + 书里没有这句时返回 null；
    `ensureSentenceAudio` 三组用例改为断言「路径 + 真实时长」。
  - `fushi/test/reader/reader_mining_audio_guard_test.dart`：源码守卫钉住
    `readAlong.sentenceRangeByText(` / `readAlong.unitCoversSentence(` /
    `sentenceAudioUntrusted` / `ReaderFushi.mineEntry.sentenceAudioMismatch`。
  - 5 + 8 个用例全绿（Flutter 3.47.7）。
- **备注**：
  - **残留（未根治，需上游决策）**：彻底做法是让朗读分句与阅读器共用同一套归一化（或让
    `buildTtsBookPlan` 产出阅读器坐标）。本条是按「两套坐标不可信」的现实做的定位层修复；
    即便哪天两边统一，`sentenceRangeByText` 仍是最稳的定位依据（文本即锚点）。
  - **合并短句场景**（单元文本包含卡片句 → 会多念前后句）本条未处理：需要给
    `TtsPlanSentence` 记合并前的子句边界，再用 Edge 的**词边界**
    （`TtsCachedAudio.boundaries`，`TtsTimingGranularity.word`）把区间裁到子句。
    用户当前报的是「换了句子」，本条先解这个。
  - 取证日志 `_debugSentenceAudioTrace`（锚 `[mine-audio]`）随包装机用于复测，**验证完要删**。
  - 待真机复测：制卡后卡上音频必须念的就是卡片那句；日志里 `card="…"` 与 `unit[i]="…"`
    应一致（不必逐字相同，但应是同一句）。若弹「已制卡但没有句子音频」，说明文本定位也没
    命中，把 `[mine-audio]` 那行贴给我。
