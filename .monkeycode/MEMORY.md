# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### User Instruction Entry
User instruction entries should follow this format:

[User Instruction Summary]
- Date: [YYYY-MM-DD]
- Context: [Mentioned scenario or time]
- Instructions:
  - [Content of user teaching or instruction, described line by line]

### Project Knowledge Entry
Entries discovered by the Agent during task execution should follow this format:

[Project Knowledge Summary]
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Operations & Deployment|Build Methods|Testing Methods|Troubleshooting & Debugging|Workflow & Collaboration|Environment Configuration]
- Instructions:
  - [Specific knowledge points, described line by line]

## Entries

[Project Knowledge Summary]
- Date: 2026-09-09
- Context: 排查 WEAK 卡扇区 2 嵌套攻击破解 RangeError/递归爆炸问题时发现
- Category: Testing Methods | Troubleshooting & Debugging
- Instructions:
  - 加密算法对拍验证方法：从 `/workspace/nfctool_extracted/assets/apps/__UNI__E03F7F1/www/app-service.js` 提取原始 JS 类（搜 `hS=(et=class{`，提取至 `...,et);` 逗号表达式闭合），配最小 shim（`$l`/`xw`/`eS`/`tS`/`rS`/`__publicField`）在 Node 中运行，与 Dart 脚本双向插桩（入口记录 rem/oks/eks/input/表大小/前 4 元素），diff 找第一个分歧点。提取件与对拍环境保留在 `/tmp/opencode/jstest/`（bundle_trace.js 可复现）。
  - JS→Dart 移植三大语义坑（本项目 crypto1.dart 已修复，改动时勿回退）：(1) `subarray()` 是共享父缓冲区的视图，等价物是 `_ListRef(d, off, s)` 偏移视图，`sublist()` 副本会导致递归子级越界；(2) `t<4 && 0!=e.rem--` post-decrement 在条件失败时也执行减 1，rem 会到 -1；(3) `TypedArray[-1]` 返回 undefined，参与位运算结果为 0。
  - `$l.sortedIndex` 是 lowerBound（`s<t`），`sortedLastIndex` 才是 upperBound（`s<=t`）；Dart `_sortedIndex` 用 lowerBound 正确。
  - 验证脚本：`/workspace/nfctool-app/nested_check.dart`（`dart run nested_check.dart` 跑完整 nested 约 100 秒；`dart run -Dsingle_pair=true nested_check.dart` 只跑第一个采集对约 15 秒）。已知正确输出：states=82056，完整流程 recovered=50 candidates 且首候选即注入密钥。
  - 算法性能参考：单 pair lfsrRecovery32 JS(Node) 约 1.6 秒、Dart(dart run) 约 15 秒；app 内 WEAK 破解预计数十秒到几分钟，UI 需有等待提示。

[Project Knowledge Summary]
- Date: 2026-09-09
- Context: 排查解卡每扇区报 `object is unsendable - _AsyncCompleter` 时发现
- Category: Environment Configuration | Troubleshooting & Debugging
- Instructions:
  - Dart async 函数内创建的闭包会捕获整个 async 上下文（含 `_AsyncCompleter`），作为 `Isolate.run`/`SendPort.send` 消息发送时抛 `object is unsendable`，顶层/非 async 上下文的闭包无此问题。
  - 规范：app 内所有 `Isolate.run` 调用必须通过 crypto1.dart 的非 async static 包装（`recoverKeysInIsolate`/`staticNestedInIsolate`），禁止在 async 函数体内直接写 `Isolate.run(() => ...)`。
  - 症状特征：日志里 collected 后几十毫秒内报 isolate unsendable 错误、无 recovered 行，即恢复计算完全没跑。
