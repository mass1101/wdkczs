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

[Project Knowledge Summary]
- Date: 2026-09-09
- Context: 借鉴 Chameleon Ultra 落地本地 Hardnested（native mfnestedhard）时发现
- Category: Build Methods | Testing Methods | Troubleshooting & Debugging
- Instructions:
  - C `hardnested()` 输入 = PM3 nonce 缓冲：6 字节头（uid 大端 4B + 2 占位）+ 每条 9 字节（4B nt + 4B ntEnc + 1B par），与 CU `getHardNested` 逐字节对齐；C 端 `read_nonces` 对每条产出 2 个 add_nonce（par 高半给 nt、低半给 ntEnc），sum8 非白名单直接失败返回。
  - C hardnested 只消费 par 的 bit3（sum8，最高字节）与 bit2（sum16/bitflip，第 2 字节），每半字节内 bit3↔最高字节（大端位序），与 valid_nonce 的 par_int（bit0↔最高字节）**相反**，两套位序并存勿混淆。
  - 合成 hard 卡样本无法从外部复刻：固件返回的两个 4B 的明文/加密视角与 par 各位语义依赖固件实现（PM3 valid_nonce 的 BIT(ks1,16-8m) 只覆盖 3 字节，第 4 字节 ks 位来自后续 keystream 流），合成数据 sum8 无法稳定落入白名单。C 算法正确性依据 = CU 产品背书 + 数据流与云端上传同源（小程序线上验证）+ 真机实测兜底。
  - Dart 侧 ByteData 陷阱：`ByteData(n)` 创建**独立**缓冲，与 `Uint8List(n)` 底层内存不共享；必须用 `u8list.buffer.asByteData()`。已实际踩坑（C 端读到全 0 还收敛出假 key）。
  - mfnestedhard 为分钟级阻塞计算，FFI 调用必须 Isolate.run（非 async static 包装，遵循既有 isolate 规范）；停止按钮只放弃结果（isolate 计算继续），与 CU 行为一致。

[Project Knowledge Summary]
- Date: 2026-09-10
- Context: 落地 Gen2/CUID 后门卡恢复（dd45818，对齐 CU NTLevel.backdoor 分支）时发现
- Category: Testing Methods | Troubleshooting & Debugging
- Instructions:
  - C 库真值验证优先用 CU 官方测试样本对拍（chameleonultra-app/test/recovery_test.dart 有真机采集的 (uid, nt, ntEnc, ntParEnc)→候选断言，数量精确匹配如 34675/35256），优于自合成样本——合成 parity 语义（密文域/明文域、位序、千位编码）极易踩错，官方样本一次通过。验证脚本 `ffi_check4.dart`。
  - C `static_encrypted_nested`（lfsr_recovery32）单条输入候选约 3.5 万（KEY_SPACE_SIZE=1<<18），上卡验证必须分块（当前 500/块）防蓝牙包过大。
  - 后门卡多路径设计（9307b2a 起对齐 CU 0x64 能力，用户确认 nfctool 与 CU 固件相同）：后门 key（A396EFA4E24F 等 3 个）普通认证命中 → 作为已知密钥走常规 nested/hardnested（精准）；认证未命中 + WEAK → 0x64 后门认证采集嵌套走 nested（authKeyType=KeyType.backdoor 透传，对齐 CU recovery.dart:314）；仍未恢复 → 后门采集 + C static_encrypted_nested 恢复 + 批量验证兜底。0x64 探测 = cmdHf14aRaw 发 [0x64,0x00]+CRC 原始帧（对齐 mfClassicHasBackdoor），后门卡响应 4 字节，普通卡无响应，作前置快筛。
  - 后门采集 nt 仅含高 16 位，明文 NT = reconstructFullNt = (nt16<<16) | prngSuccessor(nt16,16)；parity 千位编码（CU parityToInt）：bit3→千位，C 端 bin_to_uint8_arr 按十进制逐位拆回，bit3↔最高字节。
  - CU StaticEncryptedKeysFilterAsync.filterKeys（gen3NonceTag/cI 种子交叉）仅对静态加密卡有效（同 seed），weak/hard 卡跳过该过滤直接批量验证；nfctool 3gen 路径已覆盖静态卡，backdoor 兜底路径不做交叉。
  - 密钥体系按 UID 隔离（204ed5a 终版，用户明确要求）：验证集合由 _collectVerifyKeys(uidHex) 临时构造=编辑框+本卡 KeyFor_UID.txt（解卡额外加扩展字典），编辑框是用户自管内容严禁扩库污染；KeyFor 文件仅存解卡命中密钥（_autoSaveKeyFileForUid 显式传参）；default_keys.txt=跨卡累积库——解卡 finally 自动累积命中密钥（用户要求保留），但按 UID 隔离的验证集合不读它，仅供手动导出/查阅。历史废弃方案：_loadKeys 灌全库进编辑框（用户质疑）、验证集合含全部密钥文件（用户要求隔离）。

[Project Knowledge Summary]
- Date: 2026-09-11
- Context: 排查 CUID 卡 app Gen1a/Darkside 全失败而小程序可解（0408ec5 对齐修复）时逆向确认
- Category: Troubleshooting & Debugging | Environment Configuration
- Instructions:
  - 小程序（2.8.3 APK）的解卡引擎是纯 JS 层 CU 库类（app-service.js 内 `ZT=new Kk`，Kk 即 ChameleonUltra JS SDK），原生层 `cn.dxl.common.util.*`（MyUniUtils/Paths/FileUtils）只做文件存储与语音，BLE 与卡操作全在 JS——排查差异直接搜 app-service.js 的 Kk 类即可，无需反编译 dex。
  - CU 库标准 Gen1a 授权仅两步：halt → 0x40(7bit) → 0x43，**无 e100e1ee**——e100e1ee 只出现在 lockUFUID 锁卡专用序列；曾错误给 _mf1Gen1aAuth 补 e100e1ee（19197b2），已在 0408ec5 回退。库内也无 scan（小程序 UI 层 btnCrack 才 scan）。
  - 小程序 btnCrack Gen1a 读卡模式：单次授权内连续发 16 条 `0x30(4s+3)` 只读各扇区 b3（keepRfField 维持会话），读到即标记扇区恢复并把 keyA/keyB 收入字典，全成功直接结束（不验证）；app 对齐实现为 mf1Gen1aReadAllTrailerKeys + 读到即标 sectorKeys。
  - 卡「认证失败锁死」假说已被对照实验证伪（e4e6f1e）：同张 CUID 卡小程序无任何复位走完 WEAK 全流程（Darkside 破首把 + nested 逐扇区），app 加 TAG→reader 强制复位反而 HF tag not found——**复位是干扰源，勿再给 Gen1a/Darkside 加射频复位**；_mf1Gen1aAuth 严格对齐 Kk 库（halt→0x40→0x43），cmdMf1AcquireDarkside 直接 assureDeviceMode(reader) 后采集。小程序识别为「普通加密卡」说明该卡 0x40 后门无响应（Gen1a 探测失败是卡的稳定特性）。
  - Darkside 采集 cb 语义（f3af8fe 对齐）：固件 status 枚举 OK=0/CANT_FIX_NT=1/LUCKY_AUTH_OK=2/NO_NAK_SENT=3/TAG_CHANGED=4，非 OK 单轮即 throw「该卡片为无漏洞全加密卡」，LUCKY_AUTH_OK 单独抛；catch 透传原始错误到进度框。
  - 小程序 checkCrackedKey chunkSize=20，app 用 32（cmdMf1CheckKeysOfSectors 支持动态收窄），语义等价。
