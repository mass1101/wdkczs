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

[Project Knowledge Summary]
- Date: 2026-09-09
- Context: FFI 集成 PM3 native C 解卡库（native/，源自 Chameleon Ultra）做合成样本真值验证时发现
- Category: Testing Methods | Troubleshooting & Debugging
- Instructions:
  - C 库新入口的真值验证方法：用 app `crypto1.dart` 的 `Crypto1`（setLfsr/lfsrWord/prngSuccessor）合成已知密钥样本（enc = ntp ^ ks，ntp = prngSuccessor(nt, dist)），先跑 app 自身恢复路径确认含真 key（自洽），再喂 C 入口比对。验证脚本 `ffi_check.dart`（nested）/ `ffi_check2.dart`（static_nested），`dart run` 即可。
  - 禁止手写简易 Crypto1 合成器：PM3 crypto1 有特有位序（`setLfsr` 的 `^7`、`crypto1_word` 的 BEBIT 输入 + `24^i` 输出重排），手写必错（表现为 lfsr_recovery32 输出 20 多万假候选）。
  - FFI 对接前必须逐字段比对 C 结构体语义与 app 采集数据语义：CU 的 C `static_encrypted_nested` 是 lfsr_recovery32 数学，与 gen3 卡的 Doegox 2x1nt（小程序 generate_keys/`gen3GenerateKeys`）不同源，C 端无 2x1nt 实现，gen3 只能走 Dart。
  - C `nested()` 输入 = 两条采集的 (nt 明文, nt_enc, par) 同 dist；`static_nested()` = 两条连续 auth (nt, enc)，dist 由特征值决定（0x01200145→160；0x009080A2→keyA 160/keyB 161，后续 +160）；`nested_run` 输出按出现频次排序（真 key 多条恢复时频次最高排最前）。

[Project Knowledge Summary]
- Date: 2026-09-09
- Context: 审查云端 Hardnested 破解逻辑时实测发现（POST 格式 bug 已修复于 076d6b9）
- Category: Environment Configuration | Troubleshooting & Debugging
- Instructions:
  - 云端（uniCloud 云函数，默认端点见 cloud_service.dart）**只接受 application/json** body：form-urlencoded 返回 `FunctionBizError: Unexpected token ... in JSON at position 0`。GET（Analy/savesharedata）用 query 参数不受影响。
  - 云端各接口实测响应格式：`add_job` 返回 `{"id": "<objid>"}`（无 affectedDocs）；`query_job` 返回 `{"affectedDocs": N, "data": [{_id,user_id,card_id,sector,keytype,nonce,key,openid}]}`（key="" 计算中 / "error" 出错）；`del_job` 返回 `{"affectedDocs":1,"deleted":1}`。
  - add_job 的 nonce 格式（与小程序对齐）：每行 `十进制nt|par高4位\n` 与 `十进制ntEnc|par低4位\n`，集满 256 个去重高字节后上传；keytype 传 "A"/"B"；card_id 为 8 位小写 hex uid（上传查询自洽即可）。
  - 排查云端问题先用 curl 直接测端点（query_job 只读无副作用；add_job 测试数据记得 del_job 清理）。
