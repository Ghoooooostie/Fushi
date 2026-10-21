## BUG-3652 · TTS 朗读制卡句子音频：未合成句被当成已存在文件喂 ffmpeg，整张卡判死
- **报告**：2026-10-21（用户：真机制卡，OSD `导出卡片失败:sentence audio export failed: input audio file does not exist: /data/user/0/app.fushi.reader.dev/files/tts_cache/79b12967946765ee2a8d227c000c69ae2f8bba6570c703972e706487dd3eada5.audio (startMs=0, endMs=4700)`；「我用的tts，本地数据，在线tts」）
- **真实性**：✅ 真 bug。根因链（均在 develop / 3.0.0 线上，`file:line` 核实）：
  - `fushi/lib/src/media/audiobook/tts/tts_read_along.dart:283`（旧 `:352` `_filesFor`）：
    朗读会话交给有声书播放器的 `audioFiles` 是 `for (i) File(scheduler.audioPathOf(i))`
    ——**全书每一句都按缓存键拼一条「将来路径」**，`packages/fushi_engine/lib/tts/tts_audio_cache.dart:76`
    `audioPathFor(key) => <root>/$key.audio`。这些文件只有**按需合成后**才存在
    （`tts_synthesis_scheduler.dart:190` `_run` → `_cache.obtain`）。
  - 预取只覆盖当前位置之后约 `kBufferPlaybackSeconds=60` 秒播放量
    （`tts_read_along.dart:520` `_updateLookahead`），全书绝大多数句子在读到之前磁盘上
    **根本没有文件**。
  - `fushi/lib/src/pages/implementations/reader_fushi/mining.part.dart:126`（旧）：
    制卡直接 `final File inputFile = audioFiles[clip.audioFileIndex]` 并把
    `inputFile.path` 交给 `TtsChannel.extractAudioSegment`；
    `packages/fushi_engine/lib/utils/misc/desktop_audio_clipper.dart:1709` 的
    `!File(inputPath).existsSync()` 早退成 `input audio file does not exist`。
  - 该失败经 `mining.part.dart:207` 的 `requestedSentenceAudioClip && sentenceAudioPath == null`
    判定为致命 → `context: null` → **整张卡不导出**（句子音频本是可选件）。
  - 触发面：在「还没读到」的句子上划词制卡（朗读已停/滑到别处）、朗读曾失败
    （`_failure != null` 后调度不再合成）、换声音后新缓存键未合成、缓存被清或淘汰。
- **[x] ① 已修复** —
  - `tts_read_along.dart`：新增 `Future<String?> ensureSentenceAudio(int index, {timeout})`——
    已就绪/命中缓存立即返回真实路径，否则走调度器**按需合成**；会话已释放、调度已因
    失败停下（此时再等只会空等超时）、越界、超时一律返回 `null` 并落
    `ErrorLogService`（`TtsReadAlong.ensureSentenceAudio` 源）。超时常量
    `kSentenceAudioEnsureTimeout = 20s`。
  - `mining.part.dart`：新增 `_resolveSentenceAudioInputPath()`——录音有声书仍用原路径
    （真缺失保留原有失败语义），**TTS 朗读会话先经 `ensureSentenceAudio` 让这一句真正
    就绪**；拿不到就降级为「无句子音频出卡」+ `card_mined_without_sentence_audio` toast
    + `ReaderFushi.mineEntry.sentenceAudioUnavailable` 日志，**不再把整张卡判死**；
    抽段输入改用 `readyInputPath`（原 `inputFile.path`）。
  - 这是根因修复而非补丁：错的不是「缺一个文件」，而是**把「合成后才会存在的路径」
    当成了已存在的文件**——制卡这条链路少了一步「让音频真的就绪」。
  - 提交：`2b8d1b74cd`（文档补哈希见后一提交）（分支 `feature/reader-translation-on-develop`）
  - 修复只动 develop 线（`.worktrees/reader-translation`，分支
    `feature/reader-translation-on-develop`）；三个相关文件在修复前与
    `upstream/develop`（930a8be206）逐字节相同，**是上游 bug，不是合并引入**。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/audiobook/tts/tts_read_along_sentence_audio_test.dart`（新）：
    未读到的句子按需合成后返回真实路径且文件确实落盘（先断言「前提：文件不存在」复现报障现场）；
    调度已失败时立即返回 null（不空等超时）；挂在途的合成按超时返回 null。
  - `fushi/test/reader/reader_mining_audio_guard_test.dart`：源码守卫「制卡抽段前必须
    先确保句子音频存在」——含 `_resolveSentenceAudioInputPath(` /
    `ensureSentenceAudio(index)` / `inputPath: readyInputPath`，
    且 `isNot(contains('inputPath: inputFile.path'))`，并断言不可用时的日志锚点。
  - 两组共 10 个用例全绿（Flutter 3.47.7）；`flutter analyze` 对
    `reader_fushi_page.dart`（含全部 part）0 issue。
  - 同批修正：既有守卫「no-range 分支里的 toast」原按全串首个匹配取下标，降级分支
    新加的提示会抢先匹配 → 改成从 `} else if (cue == null) {` 之后开始找。
- **备注**：
  - 收藏批量制卡 `fushi/lib/src/media/favorites/favorite_batch_mining_runner.dart:221`
    走的是同一条 `audioFiles[i] → extractAudioSegment` 路径，同样会把 TTS 未合成句当
    已存在文件；本轮未一并改（用户报障场景是阅读器制卡），留作后续，入口与本条相同。
  - 制卡对话框的「高级制卡」里有「不要音频」开关（`overrides.omitAudio`），走那条路
    本来就跳过整块，不受影响。
  - 未改：句子音频裁切失败（ffmpeg 真失败）仍按原策略中止整张卡并给出
    `card_export_failed_detail` 详情——那是环境问题，不是「还没合成」。
  - 待真机复测：朗读中制卡（应带音频）、未读到的句子上制卡（应出无音频卡 + 提示，
    不再报导出失败）、在线 TTS 不可达时制卡（应出无音频卡，不卡死）。
