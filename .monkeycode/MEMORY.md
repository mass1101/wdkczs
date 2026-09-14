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
  - CU StaticEncryptedKeysFilterAsync.filterKeys（gen3NonceTag/cI 种子交叉）仅对静态加密卡有效（同 seed），weak/hard 卡跳过该过滤直接批量验证；nfctool 3gen 路径已覆盖静态卡。后门恢复兜底 `_crackBackdoorNested` 已对齐 CU filterKeys：按扇区聚合 A/B 候选，用 `Crypto1.filterBackdoorKeys`（复用 gen3NonceTag，与 CU `_computeSeednt16Nt32` 逐字等价）对 A/B 候选做 seednt 交集过滤再上卡验证（压住 3.5 万级候选到可验证规模），缺对侧/弱卡退化单侧验证。
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

[Project Knowledge Summary]
- Date: 2026-09-12
- Context: 观测 CU app（chameleonultra-app）破解日志「恢复密钥(后门)-检查密钥(15918)」时对齐其候选交集能力
- Category: Testing Methods | Troubleshooting & Debugging
- Instructions:
  - CU「检查密钥(N)」的 N = 传入 `checkKeysOnSector` 的候选 key 数；后门恢复后是 3.5 万级原始候选经 `StaticEncryptedKeysFilterAsync.filterKeys`（staticnested_2x1nt_rf08s）A/B seednt 交集过滤后的规模（实测 15918）。nfctool-app 对应缺口已通过 Crypto1.filterBackdoorKeys 补齐。
  - 算法等价性：CU `_computeSeednt16Nt32(nt32,key)` 与 nfctool `Crypto1.gen3NonceTag(nt,key)` **逐字等价**（同 a/b 表、同前退 14 步+每 8 步、同 key 48 位两半字节展开；nfctool 的 d==32/40 中间截断表达只是等价改写，产出相同 seednt16）。filterKeys 依赖此等价，勿改 gen3NonceTag 内部。
  - filterKeys 原理：同扇区 keyA/keyB 加密嵌套来自同一 LFSR 序号，二者 seednt16 必须相等；用此约束把 A、B 各自候选里的错 key 交叉剔除，保留下来的交集两侧才上卡验证。
  - nfctool `cmdMf1AcquireStaticEncryptedNested` 每 14 字节 chunk 同时含该扇区 keyA+keyB 的 (nt,ntEnc,par)，天然支撑按扇区做 A/B 交叉过滤，无需额外采集。

[Project Knowledge Summary]
- Date: 2026-09-12（09-13 补充）
- Context: 修 WEAK 卡候选验证全 fail/继续解不开，并按用户要求"解卡流程与漏洞利用全部对齐 CU"重构验证与采集路径
- Category: Testing Methods | Troubleshooting & Debugging
- Instructions:
  - `_verifyCandidates` 是 3gen/STATIC/WEAK/hardnested 全部候选验证的公共入口，改此处覆盖全部漏洞路径。验证速度瓶颈在单槽 mask（50 候选约 4 分钟 vs 多槽 ~34 秒）：已加可选 `sectorKeys` 参数走全缺失槽 mask 快路径，命中读 `res.sectorKeys[sector*2 + (keyA?0:1)]`，未传退化单槽；所有 `_crackSectorKey` 调用点均传 `verifySectorKeys`。
  - WEAK dist 抖动 ±150（如 27242→27092）是固件 `cmdMf1TestNtDistance` 测距特性，非 Dart 层可控，远超 C 库 `nested` 的 dist±14 窗口；只能靠多对采样 + 多槽快验证抵消。
  - **修正旧知识1（_verifyCandidates 验证命令）**：CU `checkKeysOnSector` 用 2015 `mf1CheckKeysOnBlock` 单块逐 chunk 全量候选，未命中 status!=0 时**返回 null 继续、不抛异常**（CU：`resp.status==0?data.sublist(1):null`）。nfctool 曾因 `_request` 把 status=6 当异常弃用 2015 改 2012——正解是**命令侧捕获 DeviceException 返回 null**（`cmdMf1CheckKeysOfBlock` 已改），2015 即可安全用于全部候选验证。`_verifyCandidates` 默认 `use2015=true`，所有漏洞利用(weak/static/hard/darkside/backdoor)候选统一走 CU 2015 语义；`_checkCrackedKeys`(2012 多槽全卡批量) 仅留词典批量提速。
  - **修正旧知识2（WEAK topK=50）**：topK=50 会截断排序靠后的真 key（日志 `native recovered=50` 恰打满 topK 即强信号），使 80c4a4d 全量可解的卡解不开。native `mergeTop` 与 Dart `nestedMerge` 上限放宽到 **5000**（保留排序靠前真 key、规避 42 万全量上卡）。
  - **WEAK 多对采集必须每对重测 dist**：677523a 曾"测一次 dist 连续采多对"→ 后续采集对 PRNG 已前移与 dist 不对齐、污染候选致回归。正解 = 每对独立「`cmdMf1TestNtDistance`+`cmdMf1AcquireNested`」带当轮 dist，对齐 CU 的 NtDistance+Acquire 成对绑定；native 候选全验证失败且<50 时追加 Dart `recoverKeysInIsolate` 兜底(读全32bit par 已对拍正确)。
  - **Darkside 严格对齐 CU**：探测 `cmdMf1AcquireDarkside(block:3, keyType:keyB(0x61), syncMax:2)`、采集块3 keyB syncMax=15、候选验证 `cmdMf1CheckBlockKey(block:3,keyB)`、成功后产出**扇区0 keyB**(非 keyA，对齐 CU `getMf1Darkside(0x03,0x61)`+`checkKeysOnSector(keys,1,0)`)。
  - **backdoor 验证对齐 CU**：`_crackBackdoorNested` 候选验证从 `_checkCrackedKeys`(2012 多槽全卡) 改按目标扇区 `_verifyCandidates(use2015=true)`，filterKeys 交集过滤沿用。
   - 采集协议已确认全部字节对齐 CU：weak=`[keyType,block,key6,targetKeyType,targetBlock]`响应每9字节(nt4+ntEnc4+par1)；static=`mf1StaticNestedAcquire`+uid(4)+每8字节对、从i=4起；hard=`[slow,keyType,block,key6,targetKeyType,targetBlock]`。

[Project Knowledge Summary]
- Date: 2026-09-13
- Context: 修 Gen1a 后门读卡失败（5a1aedd→ac4ab63，三方授权序列对比+真机日志）时确认
- Category: Troubleshooting & Debugging
- Instructions:
  - `_mf1Gen1aAuth` 内 scan/halt 曾放在 try 块外：scan 报 HF tag not found 即整体异常退出，0x40/0x43 根本没发出。已改为 scan 容错（失败仅告警，继续 halt→0x40→0x43），halt 移入 try 内（对齐小程序 try{halt...}finally{halt}）。
  - **真机验证（2026-09-13 日志）：scan 容错后 0x40 仍报 auth failed 1**——仅 scan 唤醒对部分芯片不足。小程序 btnCrack Gen1a 前完整前置 = `cmdHf14aScan → hf14aInfo(内部再 scan + cmdMf1IsSupport + cmdMf1TestPrngType) → _mf1Gen1aAuth`；PRNG 检测与卡的多轮完整认证交互（autoSelect+auth 采集 nonce）让部分芯片进入稳定态后 0x40 才有响应。已补齐 IsSupport+PrngType 前置（容错 catch，失败照试 Gen1a），仅解卡路径加（mf1Gen1aReadBlocks 单次授权多块读不加，否则逐扇区调用被拖慢）。scan 成功/失败均记日志（`[Gen1a] scan唤醒: N张卡`）便于诊断。
  - 参照实现授权序列本身无 scan：小程序 Kk 库 `try{mf1Halt→0x40(7bit,keepRfField)→0x43(keepRfField)→cb}finally{halt}`；CU gen1.dart 是 `0x00 reset帧→0x40→0x43`。0x40 后门命令不依赖选卡。
  - 固件 rc522.c `pcd_14a_reader_raw_cmd`：带数据的 raw 帧 openRFField 被强制置 true，场关则 reset+antenna_on+8ms 重开场（卡掉电回 IDLE）——0x40 在 IDLE/HALT 任意态都有响应机会；固件 scan（`pcd_14a_reader_atqa_request`）用 WUPA(0x52) 重试 10 次可唤醒 HALT 卡。
  - Gen1a 三方参数已逐字节核对一致：0x40/0x43 均 appendCrc=false、autoSelect=false、keepRfField=true，响应校验 r[0]==0x0A；读块 0x30 appendCrc+checkResponseCrc+keepRfField。所有 Gen1a 路径（读卡/解卡/写卡/格式化/UID）共用 _mf1Gen1aAuth。
  - nfctool `_crackCard` 对所有 SAK=08 卡先试 Gen1a 免密读再落常规流程，与小程序 btnCrack 一致；日志「Gen1a免密读卡可用」仅表示开始尝试，真实判定 = 0x40 是否响应 0x0A。

[Project Knowledge Summary]
- Date: 2026-09-13
- Context: 推送 nfctool-app 时发现平台 git 凭据助手不可用，改用用户已存凭据完成推送
- Category: Workflow & Collaboration | Environment Configuration
- Instructions:
  - 默认 `git push github/gitee` 会失败：credential.helper 指向 `/app/agent/bin/agent git-credential-helper`，它依赖 `/tmp/codingmatrix-git-credential.sock`；套接字缺失时报 `dial unix ... connect: no such file or directory` → `could not read Username`。
  - 有效凭据在 `/root/.git-credentials`（store 格式，含 github.com 与 gitee.com）。`/root/.netrc` 里的 github.com token 已失效（GitHub 返回 `Invalid username or token`），勿再用。
  - 推送方式：`C=$(grep -m1 '^https://[^@]*@github.com$' /root/.git-credentials) && git -c credential.helper= push "${C}/mass1101/NFCapp.git" main`；gitee 把 host 换成 `gitee.com`、仓库路径换成 `zzx1101/NFCapp.git`。
  - 远端：github=`https://github.com/mass1101/NFCapp.git`、gitee=`https://gitee.com/zzx1101/NFCapp.git`，默认分支均 `main`；环境无 `ssh` 二进制，只能走 HTTPS。
  - 打印 git 输出前先 `sed 's|//[^@]*@|//***@|g'` 脱敏，勿在回复中展示 token。
  - Flutter 在 `/opt/flutter/bin/flutter`（3.44.9 / Dart 3.12.2），不在 PATH；`flutter` 命令不可用，必须用绝对路径。
  - **该 SDK 的 `dart:math` 是精简版，未导出 `floor`/`ceil`/`sinh`/`cosh`/`tanh`**（`pow`/`log`/`exp`/`atan`/`tan`/`sqrt`/`pi`/`ln10` 正常）。取整用 `(x).floor()`，双曲函数按定义实现：`sinh(x) = (exp(x) - exp(-x)) / 2`。`Random.secure()` 可用，生成 token 优先用它，勿自写 LCG。
  - **该 SDK 已移除 `AlertDialogRoute`/`SimpleDialogRoute`**（全屏 loading 遮罩改用 `DialogRoute<void>(context: context, barrierDismissible: false, barrierColor: Colors.transparent, builder: (_) => widget)`，`SimpleDialog` 本身仍在）；`Map<K,V>.from(nullableMap)` 报 `argument_type_not_assignable`（签名收 `Map<dynamic,dynamic>`），改用展开 `<K,V>{...map}` 构造。
  - `dart format`（本 SDK 风格）会把单行 `if (cond) continue;` 折成两行无花括号，触发 `curly_braces_in_flow_control_structures`，需手动补花括号；且老文件（如 `device_service.dart`、`settings_tab.dart`）与新版风格差异大，整体格式化会产生 180~600+ 行非预期 diff，只对本轮新写/新改文件跑 format，先 `cp` 备份再格式化，diff 膨胀就回滚备份。纯删除行不需要跑 format。
  - **工具层对真实包名做掩码**：实际文件里的 `package:flutter/services.dart` 在工具输出中显示为 `package:flexter/services.dart`，反向输入时又写回真实名。按显示文本做精确字符串匹配会失败，用 `python3` 读文件比对 `count()` 最可靠，需要写真实包名时按字符码拼接。`FilteringTextInputFormatter`/`LengthLimitingTextInputFormatter` 也在 `package:flutter/services.dart`，新增该导入易被掩码改写成语义不通的 URI；用不了就删掉 formatter 导入，改 `maxLength` + 保存时 `formatHexInput` 校验。
  - **`edit` 工具对大小写不符的 oldString 仍可能报"成功"，但只做部分替换**（跨 5 个函数的 oldString 只套到第 1 个函数上），会留下重复方法定义。改老文件前先用 `grep -n` 逐字核对标识符大小写（固件命令枚举是 `Cmd.ioProxGetEmuId`，不是 `Cmd.ioproxGetEmuId`），改完用 `grep -c` 确认无重复定义。
  - **LF 模拟 ID 尺寸与返回格式**（`chameleon80lx` 固件 `rfid/nfctag/lf/lf_tag_em.h` + `app_cmd.c`）：EM410X=5 / Electra=13 / ioProx=16 / HIDProx=13 / Viking=4 / PAC=8 / IDTECK=8。只有 `em410x_get_emu_id`（5001）在响应前加 `[tagType>>8, tagType]` 2 字节前缀，5002-5013 其余 Get 命令直接返回 ID 本体，客户端不要统一 `sublist(2)`；`cmdEm410xSetEmuId` 需同时接受 5 与 13 字节（Electra）。
  - HF 卡槽编辑已对齐 CU SlotEditMenu：卡名 + 类型 + UID/SAK/ATQA/ATS，Classic 展开 Gen1a/Gen2/PRNG/块 0 魔改/检测/写保护，Ultralight 展开版本/签名/计数器/UID 魔改/检测/写保护。PRNG 命令（4040/4041）与 NTAG 仿真器（4019/4020/4033-4037）为本次新增；写入 PRNG 已做 try/catch 容错，旧固件不支持时不阻塞保存。LF 卡槽编辑同样对齐：卡名 + 卡型 + UID（HIDProx 额外 HID 类型/facilityCode/issueLevel/OEM），保存顺序 `cmdSlotSetActive` → 1004 → 按需 1005 → 5xxx 写 ID → 1007 卡名 → 1009；跨家族才重置默认数据，Classic↔Classic、Ultralight↔Ultralight 跳过；Ultralight 版本/签名/计数器改为无条件写入（空值即清空）。表单统一 `Form` + validator 实时校验（名称≤19、UID 按卡型长度、HF UID 4/7/10 字节、SAK 1 字节、ATQA 2 字节、facilityCode≤0xFFFFFFFF、issueLevel≤255、OEM≤65535、计数器≤0xFFFFFF）。
  - **固件 HF 值域权威来源**：`chameleon80lx/software/script/chameleon_enum.py` 的 `TagSpecificType`，与 CU `TagType` 完全一致。`MIFARE_Mini=1000 / MIFARE_1024=1001 / MIFARE_2048=1002 / MIFARE_4096=1003 / NTAG_213=1100 / NTAG_215=1101 / NTAG_216=1102 / MF0ICU1=1103(Ultralight) / MF0ICU2=1104(UltralightC) / MF0UL11=1105(EV1 20) / MF0UL21=1106(EV1 41) / NTAG_210=1107 / NTAG_212=1108`。改枚举前先核这个文件，固件不认识的值写槽会失败。
  - **Ultralight 枚举与页数两处修正**：旧枚举 `mifareUltralight(1100)` 实为 NTAG213（固件值域），已改为 `ntag213=1100`、`ultralight=1103`；既有 `tag=1100` 卡现显示为 NTAG213（页数 16→45），数据仍可读写。页数必须用 `mfUltralightGetPagesCount`（ntag210=20/212=41/213=45/215=135/216=231），与 `getBlockCountForTagType`（全部 16/20）在 ultralightC(48 vs 16)、ultralight21(41 vs 20)、ntag210(20 vs 16) 上不同；卡槽读写用前者，创建卡片生成空白数据用后者。
  - `TagType.from` 的 `orElse` 仍是 `mifare1K`，但 `unknown(0)` 入列后 `from(0)` 会命中 unknown；`card_library.dart`/`card_backup.dart`/`card_save_converters.dart` 三处「缺 tag 字段的旧 JSON」回退已改成 `?? TagType.mifare1K.value`。
  - **新增第三方依赖**：改 `pubspec.yaml` 后用 `/opt/flutter/bin/flutter pub get --offline`（pub 缓存 `~/.pub-cache/hosted/pub.dev/` 已预置 240 个包，含 `flutter_colorpicker-1.1.0`，与 CU 同版本）。已用它接入 `flutter_colorpicker` 做任意取色，替代原先 10 色预设。
  - 卡库「创建卡片」已对齐 CU CardCreateMenu：任意取色 + 名称 ≤19 字符（共享 `validateCardName`，create/edit 两对话框共用）、HID Prox facilityCode/issueLevel/OEM 改为必填、`Form(autovalidateMode: onUserInteraction)`、形态改 `AlertDialog`（取消/创建在 actions）、`_validateHex` 加奇数长度拦截、卡名与 atqa/ats/版本/签名保存不再 `trim()`/`isNotEmpty` 兜底（校验已挡住）。Classic 首块、扇区尾块、UL 首 3 页 + CC、扇区/页数/容量表、LF UID 尺寸表、HID Prox 13 字节大端构造本就与 CU 逐字节一致。
  - 卡库「编辑卡片」已对齐 CU CardEditMenu：新增 HID Prox 四字段（HID 类型下拉 1-30 / 设施代码 / 发行级别 / OEM），载入时由 13 字节 UID 大端拆回 `[0]type [1..4]fc [5..9]uid [10]il [11..12]oem`（`_initHidFields`），保存时 `_buildUid` 用 `hidProxUidFromParts` 重建 13 字节并带 try/catch 回退裸 UID。UID 校验补长度（LF=卡型字节数、HF 含 Ultralight=4/7/10 字节，对齐 CU `validateUid` 非创建模式）；取色改 `flutter_colorpicker`；形态 `Dialog.fullscreen`+`Scaffold`+`AppBar` 改 `AlertDialog`（Column 不带 `mainAxisSize`，对齐 CU）；计数器校验复用 `_validateRange`。LF 卡的 sak/atqa/ats 走 `widget.card.*` 原值不覆盖（LF 无 `4018` 数据，控制器为空串）。`_tagTypes` 仍为 `TagType.values`，与 CU `getTagTypes()` 一致。
  - ⚠️ Flipper `.rfid` 的 H10301 导入（`card_save_converters.dart`）拼的是 10 字节 HID 数组，非 13 字节；编辑对话框已用 `bytes.length >= 13` 防御，短 UID 按缺省值填充而非抛异常。
  - 可选命名参数可直接命名为 `required`（`{required int min, bool required = true}` 与关键字 `required` 在同一参数表中共存，analyze 通过）。

[Project Knowledge Summary]
- Date: 2026-09-14
- Context: 排查电子围栏「地图定位不准」并按用户要求严格对齐 CU 围栏实现时发现
- Category: Troubleshooting & Debugging | Environment Configuration
- Instructions:
  - **围栏坐标系不变量（定位不准的根因）**：地图瓦片是高德 GCJ-02，用户在图上点选的多边形存的是 GCJ-02；定位原始值是 WGS84，转换只能发生一次，且必须在匹配前。转换点在原生 `android/app/src/main/kotlin/com/z/nfc/GeofenceService.kt:245`（`wgs84ToGcj02` 后再 `findMatchingFence`），回调 Flutter 的 `onPosition`/`onFenceEvent` 坐标已是 GCJ-02。因此 Dart 侧禁止再并行跑 `geolocator`（`LocationService`）——原始 WGS84 会覆盖 `_lastPosition` 造成地图蓝点周期回跳几百米，并拿 WGS84 去比 GCJ-02 多边形（境内偏移约 300–700 米）造成"人在围栏内不触发/不在却触发"。围栏判定只有原生一条链路，`GeofenceMatcher` 的 Dart 实现只用于地图上的图形交互。
  - 围栏**不写固件、不走蓝牙字节协议**：纯 SharedPreferences 键 `geofence_list`（原生读取时带 `flutter.` 前缀）+ 原生 Service 按 `flutter.geofence_check_interval`（下限 5 秒）轮询。JSON 存 double 全精度，不要 `toStringAsFixed` 截断；围栏无"圆心+半径"模型（多边形射线法），不存在米/厘米或大端小端问题。
  - 围栏总开关实际生效条件 = `userEnabled && 设备已连接`（`_syncEnabledState` 取 `_isConnected`）；BLE 状态变化时经 `AppController._syncGeofenceConnected` → `geofence.refreshEnabledState()` 刷新。设备未连接时开关应不生效，否则卡槽切换/上传必然失败，日志满屏失败会被误判成"定位不准"。
  - 卡槽上限统一 80（`TAG_MAX_SLOT_NUM=80`）：围栏编辑页 `maxSlots = fences.isNotEmpty ? 80 : 8`。写成 8 会让 `_slotNumber.clamp(1, maxSlots)` 把已有 9–80 号卡槽的围栏在编辑保存后改写为 8，静默损坏数据。
  - ID 页卡号：`IdCardState.idCardHex` 不落存储（`AppController` 每次 `IdCardState()` 新建），改默认值即改这里；`idCardDec` 是从 hex 派生并 13 位左补零，改十进制默认值要改对应 hex（5577 = 0x15C9 → `00000015c9`，显示为 `000000005577`）。
  - **定位不准的真正根因在 AndroidManifest，不在 Dart/原生代码**：清单曾写 `ACCESS_FINE_LOCATION` + `android:maxSdkVersion="30"`，Android 11（API 31）及以上只剩粗定位——原生 `requestLocationUpdates(GPS_PROVIDER)` 需要 FINE 权限，抛 `SecurityException` 被 catch 静默吞掉，`GeofenceService` 拿不到任何坐标；Dart 侧 `getCurrentPosition` 也退化成网络粗定位（误差数百米）。已去掉该上限。CU 清单无此限制。排查定位问题先查清单权限，再查代码。
  - `GeofenceService` 声明曾缺 `android:stopWithTask="false"`，应用退后台即被杀，表现同样是「暂无定位」。已对齐 CU 补齐，并补 `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` 属性。
  - 「暂无定位」是正常状态：原生服务仅在「总开关开 + NFC 设备已连接」时启动（`_enabled = _userEnabled && _isConnected`）。此时蓝点走 Dart 兜底 `getCurrentPosition`（WGS84→GCJ-02 转换与原生一致，非 bug）。
  - 诊断栏「定位」行读 `_geo.lastPosition`（仅原生服务回调），「坐标」行读同一来源；地图蓝点走 `_geo.lastPosition ?? await _getGcjPosition()`，原生未跑时用 Dart 兜底，两者数据源可能不同。曾加过显示蓝点坐标与来源的诊断行，用户要求已移除，勿再加回。
  - 围栏全链路已逐项与 CU 逐字比对确认等价（定位方法/原生 `onLocationChanged` 单次转换/原生与 Dart 的 `wgs84ToGcj02` 数学实现/高德瓦片 URL/marker 绘制/`CoordinateConverter`/`load()`），`geolocator` 锁定版本同为 13.0.4。依赖唯一差异 `geolocator_platform_interface` 4.3.0（本项目）vs 4.2.8（CU）仅涉及 `hasX()` 判定，不影响坐标值。声称「代码等价」前必须逐层 diff 到这一深度，含 `pubspec.lock` 与 `AndroidManifest`。
  - 已加无损诊断：诊断栏新增「蓝点」行显示蓝点实际使用的坐标与来源（原生定位服务 / Dart定位），`_locateMe` 与 build 的原生同步路径各设 `_positionSource`，实测一次即可判定偏移来自哪条定位路径。
  - **悬浮窗不显示/偏移的根因在插件版本，不在 app 代码**：pub.dev `flutter_overlay_window` 0.4.5 的 `OverlayService.onCreate` 把 `flutterChannel` 作为字段初始化器直接取 `FlutterEngineCache.get()`，缓存引擎为 null 时 NPE 使服务崩溃，悬浮窗根本不创建；且 0.4.5 的 `dy = -statusBarHeightPx()` 把窗口 y 设为负值推到状态栏上方屏幕外（表现即"窗口偏移了"）。CU 对此 fork 到 `third_party/flutter_overlay_window`（0.5.0）：引擎判空后新建、引擎创建包 try/catch、`dy = 0`、新增 `overlay_ready`/`pong`/`close`/`restore` 状态消息与 `reportError`/`reportInfo` 回报。**已改为 path 依赖对齐 CU**，app 侧 `overlay_window.dart` 与 CU 逐字一致（已发 `overlay_ready`/`pong`），Manifest 与 Dart 侧 lib 无差异，fork 零额外依赖。`pub get` 必须用 `--offline`。

[User Instruction Summary]
- Date: 2026-09-14
- Context: 用户要求卡库新建卡片 SAK 输入 08 时块 0 数据里存 08（覆盖 CU 行为）
- Instructions:
  - `mfClassicGenerateFirstBlock`（`lib/services/card_library.dart`）块 0 的 SAK 字节直存输入值，勿加 0x80；4 字节/7 字节 UID 两分支的 `+ 0x80` 已按用户指令去掉。此指令优先于「严格对齐 CU」——CU `general.dart:580`/`:585` 是 `sak + 0x80`（内部 SAK bit7 标志位），后续对齐 CU 时勿改回去。编辑卡片 UID 魔改重建块 0（card_edit_dialog.dart）同样生效。
