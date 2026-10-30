## BUG-3369 · 阅读器段落对照翻译中途停止：限流/网络失败后段落永久冷却且无 UI 反馈
- **报告**：2026-10-19（用户：真机阅读日文小说，非 AI 引擎 = 彩云网页版）
- **真实性**：✅ 真 bug。根因链（三处叠加，都在「失败之后」这一段路上）：
  - `packages/fushi_engine/lib/translation/translation_models.dart:103` `TranslationFailure.isRetryable`
    只认 `network_error` / `rate_limited` / `http_5*`，而彩云限流实际抛的是 `_decodeBody`
    拼出的 **`http_429`** → 限流一次即判失败，连「reset 后重来一次」的机会都没有。
  - `fushi/lib/src/reader/reader_translation_coordinator.dart` 旧 `_failureCount` + `_maxRetries = 4`：
    同一段落失败满 4 次就**本次会话永久冷却**，不再入队。端点抖一下 → 当前这一屏十几段
    各自攒满 4 次 → 整章后半段再也翻译不出来。
  - 重试的唯一入口是「用户滚动 → `_refreshProgressFromScroll` → `scheduleVisibleScan` →
    重新 collect」。用户读到一半往往就停在那儿看，于是那一屏的空白被钉死到会话结束；
    失败本身只 `debugPrint`，UI 上一句话都没有。
  - 症状：前面几段有淡色译文、后面（同屏可见）全部为空，且没有任何错误提示。
- **[x] ① 已修复** —
  - `translation_models.dart`：`http_429` / `http_408` / `http_425` 纳入 `isRetryable`
    （限流、超时类失败允许 reset 后重来一次）。
  - `reader_translation_coordinator.dart`：删掉「4 次永久冷却」，改为**冷却池 + 阶梯等待**
    （2s→5s→15s→30s→60s，429/rate_limited/timeout 翻倍），新增 `hasPendingRetry` /
    `nextRetryAt` / `flushRetries()`；新增**自适应节流** `requestInterval`（连续失败
    800ms→1.6s→3.2s→6.4s，8s 封顶，任何一次成功即归零）；`cancel()` 连失败池一起清
    （id 属于旧文档）。
  - `reader_translation_scheduler.dart`：失败回流时挂**自主重试轮询** `_scheduleRetryFlush()`
    （默认 2s，取「下一次到期时刻」与轮询间隔的较大值），不再等用户滚动；`stop()` /
    `cancelForNavigation()` 一并清掉；重新打开翻译时若仍有冷却中的段落会接着排。
  - **落点更正（重要）**：上述修复最初打在了 **2.9.1（main）** 上，但报障用户实际
    使用的是 **2.10.0（develop 线）** 的版本。两版的这三个文件在修复前逐字节相同
    （bug 在 2.10.0 上原样存在：`_maxRetries = 4` 与 `_failureCount` 仍在），
    现已把同一套修复**移植到 2.10.0**：worktree `.worktrees/reader-translation`
    （分支 `feature/reader-translation-on-develop`）。2.10.0 排查期加的段落收集诊断
    日志（`scan ... raw=...`）已合并进来，未丢失。
  - 提交：分支 `fix/reader-translation-continuity`（worktree `.worktrees/rt-continuity`，
    哈希见该分支 HEAD；同一改动已同步回原工作区未提交工作树）
  - 环境注记：2.10.0 线把 Flutter 约束提到了 `^3.47.0`（`fushi_platform` 与主包
    `pubspec.yaml` 的 `environment.flutter`），本机原有的 3.44.8 **无法解析 2.10.0 的
    依赖**，这也是修复一度只在 2.9.1 上验证过的直接原因。已在本机装
    Flutter 3.47.7（Dart 3.13.5）用于 2.10.0 的分析/测试/构建。
- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/reader_translation_coordinator_test.dart`：冷却期内不重打 / 冷却到期
    `flushRetries` 重排并回填 / 二次失败阶梯变长且不判死刑 / 429 冷却翻倍 / 连续失败拉长
    请求间隔且成功后恢复 / `cancel` 清失败池。
  - `fushi/test/reader/reader_translation_scheduler_test.dart`：失败后**不滚动**也会自动重试
    并在端点恢复后回填；换章后不再重排旧文档段落。
- **备注（2.10.0 设备复测已做）**：在 Android 模拟器（API 35，x86_64）上构建并运行
  `integration_test/reader_translation_continuity_itest.dart`（待译 epub
  `[住野よる] また、同じ夢を見ていた.epub`）。证据：
  - **修复机制生效**：失败后不再停死，调度器**在零输入的静默拍里也持续自动重试**
    （`retry requeued=1` 反复出现，间隔随阶梯冷却拉长），而修复前失败段落只能等用户
    滚动才重排。单测侧（30/30 全绿）已覆盖「端点恢复即回填」。
  - **链路可达**：短文本（书名/作者，`scan targets=2`）经彩云引擎翻译成功
    （`ok id=ft-1 chars=9`）；直连探针 `status=405` 证明 App 内 HTTPS 可达端点。
  - **模拟器环境限制（非产品 bug）**：正文长段落到彩云在该模拟器里全部毫秒级
    `network_error`（未等服务端响应即失败），宿主机对同一长文本的 POST 0.17s 正常
    返回（401 缺 token）。因此模拟器上**端点始终不可用**，「端点恢复后补上译文」这一步
    在模拟器里无法最终验证，需在真机/可稳定连通彩云的环境确认。推断与模拟器 NAT/TLS
    对长 body 请求的处理有关。
  - view mode：本轮在默认（paginated）下验证；continuous / vn 模式下 JS 收集与调度路径
    相同，但受同一模拟器网络限制，无法在当前环境单独复测。
  - 未做 UI 提示（失败段落仍留空白 + 日志一行），因为优先级是「连续翻译」而非提示；
    若后续要提示，入口是 `ReaderTranslationOutcome.failureCode` 回流。
