/// 设备命令码（对应逆向 bb 枚举）
enum Cmd {
  getAppVersion(1000),
  changeDeviceMode(1001),
  getDeviceMode(1002),
  setActiveSlot(1003),
  setSlotTagType(1004),
  setSlotDataDefault(1005),
  setSlotEnable(1006),
  setSlotTagNick(1007),
  getSlotTagNick(1008),
  slotDataConfigSave(1009),
  enterBootloader(1010),
  getDeviceChipId(1011),
  getDeviceAddress(1012),
  saveSettings(1013),
  resetSettings(1014),
  setAnimationMode(1015),
  getAnimationMode(1016),
  getGitVersion(1017),
  getActiveSlot(1018),
  getSlotInfo(1019),
  wipeFds(1020),
  deleteSlotTagNick(1021),
  getEnabledSlots(1023),
  deleteSlotSenseType(1024),
  getBatteryInfo(1025),
  getButtonPressConfig(1026),
  setButtonPressConfig(1027),
  getLongButtonPressConfig(1028),
  setLongButtonPressConfig(1029),
  setBlePairingKey(1030),
  getBlePairingKey(1031),
  deleteAllBleBonds(1032),
  getDeviceModel(1033),
  getDeviceSettings(1034),
  getDeviceCapabilities(1035),
  getBlePairingEnable(1036),
  setBlePairingEnable(1037),
  getAllSlotNicks(1038),
  hf14aScan(2000),
  mf1DetectSupport(2001),
  mf1DetectPrng(2002),
  mf1StaticNestedAcquire(2003),
  mf1DarksideAcquire(2004),
  mf1DetectNtDist(2005),
  mf1NestedAcquire(2006),
  mf1AuthOneKeyBlock(2007),
  mf1ReadOneBlock(2008),
  mf1WriteOneBlock(2009),
  hf14aRaw(2010),
  mf1ManipulateValueBlock(2011),
  mf1CheckKeysOfSectors(2012),
  mf1HardnestedAcquire(2013),
  mf1EncNestedAcquire(2014),
  mf1CheckKeysOnBlock(2015),
  hf14aGetConfig(2200),
  hf14aSetConfig(2201),
  em410xScan(3000),
  em410xWriteToT55xx(3001),
  hidproxScan(3002),
  hidproxWriteToT55xx(3003),
  vikingScan(3004),
  vikingWriteToT55xx(3005),
  em410xElectraWriteToT55xx(3006),
  adcGenericRead(3009),
  mf1WriteEmuBlockData(4000),
  hf14aSetAntiCollData(4001),
  mf1SetDetectionEnable(4004),
  mf1GetDetectionCount(4005),
  mf1GetDetectionLog(4006),
  mf1GetDetectionEnable(4007),
  mf1ReadEmuBlockData(4008),
  mf1GetEmulatorConfig(4009),
  mf1GetGen1aMode(4010),
  mf1SetGen1aMode(4011),
  mf1GetGen2Mode(4012),
  mf1SetGen2Mode(4013),
  mf1GetBlockAntiCollMode(4014),
  mf1SetBlockAntiCollMode(4015),
  mf1GetWriteMode(4016),
  mf1SetWriteMode(4017),
  hf14aGetAntiCollData(4018),
  mf0NtagGetUidMagicMode(4019),
  mf0NtagSetUidMagicMode(4020),
  mf0NtagReadEmuPageData(4021),
  mf0NtagWriteEmuPageData(4022),
  mf0NtagGetVersionData(4023),
  mf0NtagSetVersionData(4024),
  mf0NtagGetSignatureData(4025),
  mf0NtagSetSignatureData(4026),
  mf0NtagGetCounterData(4027),
  mf0NtagSetCounterData(4028),
  mf0NtagResetAuthCnt(4029),
  mf0NtagGetPageCount(4030),
  mf0NtagGetWriteMode(4031),
  mf0NtagSetWriteMode(4032),
  mf0NtagSetDetectionEnable(4033),
  mf0NtagGetDetectionCount(4034),
  mf0NtagGetDetectionLog(4035),
  mf0NtagGetDetectionEnable(4036),
  mf0NtagGetEmulatorConfig(4037),
  mf1SetFieldOffDoReset(4038),
  mf1GetFieldOffDoReset(4039),
  em410xSetEmuId(5000),
  em410xGetEmuId(5001),
  hidproxSetEmuId(5002),
  hidproxGetEmuId(5003),
  vikingSetEmuId(5004),
  vikingGetEmuId(5005);

  const Cmd(this.value);
  final int value;
}

/// 设备模式（对应逆向 Sb）
enum DeviceMode {
  tag(0, '标签模式'),
  reader(1, '读卡器模式');

  const DeviceMode(this.value, this.label);
  final int value;
  final String label;

  static DeviceMode from(int v) =>
      values.firstWhere((e) => e.value == v, orElse: () => tag);
}

/// 卡片类型（对应逆向 setSlotTagType 值域）
enum TagType {
  mifareClassic1k(0, 'Mifare Classic 1K'),
  mifareClassic4k(1, 'Mifare Classic 4K'),
  mifareUltralight(2, 'Mifare Ultralight'),
  ntag215(3, 'NTAG215'),
  em4100(4, 'EM4100'),
  hidProx(5, 'HID Prox'),
  viking(6, 'Viking'),
  electra(7, 'Electra');

  const TagType(this.value, this.label);
  final int value;
  final String label;

  static TagType from(int v) =>
      values.firstWhere((e) => e.value == v, orElse: () => mifareClassic1k);
}

/// 密钥类型 A/B（对应逆向 Ob）
enum KeyType {
  keyA(0x60, 'A'),
  keyB(0x61, 'B');

  const KeyType(this.value, this.label);
  final int value;
  final String label;
}

/// 破解类型（对应逆向 Rb）
enum CrackType {
  static_(0, '静态嵌套'),
  weak(1, '弱随机数'),
  hard(2, 'HardNested');

  const CrackType(this.value, this.label);
  final int value;
  final String label;
}

/// 动画模式（对应逆向 gb）
enum AnimationMode {
  full(0, '完整动画'),
  short(1, '简单动画'),
  none(2, '关闭动画'),
  symmetric(3, '对称动画');

  const AnimationMode(this.value, this.label);
  final int value;
  final String label;

  static AnimationMode from(int v) =>
      values.firstWhere((e) => e.value == v, orElse: () => full);
}

/// 短按/长按按钮动作（对应逆向 vb）
enum ButtonAction {
  disable(0, '无动作'),
  cycleSlotInc(1, '激活下一个槽位'),
  cycleSlotDec(2, '激活上一个槽位'),
  cloneIcUid(3, '模拟IC-ID卡号'),
  battery(4, '显示设备电量');

  const ButtonAction(this.value, this.label);
  final int value;
  final String label;

  static ButtonAction from(int v) =>
      values.firstWhere((e) => e.value == v, orElse: () => disable);
}

/// 卡槽位（对应逆向 Vb）
enum SlotIndex {
  slot1(0, '卡槽1'),
  slot2(1, '卡槽2'),
  slot3(2, '卡槽3'),
  slot4(3, '卡槽4'),
  slot5(4, '卡槽5'),
  slot6(5, '卡槽6'),
  slot7(6, '卡槽7'),
  slot8(7, '卡槽8'),
  slot9(8, '卡槽9'),
  slot10(9, '卡槽10'),
  slot11(10, '卡槽11'),
  slot12(11, '卡槽12'),
  slot13(12, '卡槽13'),
  slot14(13, '卡槽14'),
  slot15(14, '卡槽15'),
  slot16(15, '卡槽16');

  const SlotIndex(this.value, this.label);
  final int value;
  final String label;
}

/// 设备错误状态码（对应逆向 dk）
class DeviceStatus {
  static const Map<int, String> messages = {
    0: 'HF tag operation succeeded',
    1: 'HF tag not found',
    2: 'HF tag status error',
    3: 'HF tag data crc error',
    4: 'HF tag collision',
    5: 'HF tag uid bcc error',
    6: 'HF tag auth failed',
    7: 'HF tag data parity error',
    8: 'HF tag was supposed to send ATS but didn\'t',
    64: 'LF tag operation succeeded',
    65: 'EM410x tag not found',
    66: 'LF tag not found',
    67: 'HIDProx tag not found',
    96: 'invalid param',
    102: 'wrong device mode',
    103: 'invalid cmd',
    104: 'Device operation succeeded',
    105: 'Not implemented',
    112: 'Flash write failed',
    113: 'Flash read failed',
    114: 'Invalid slot tagType',
  };

  static String message(int code) => messages[code] ?? 'Unknown status $code';

  static bool isOk(int code) => code == 0 || code == 104;

  static bool isHfError(int code) => code >= 1 && code <= 8;
}

/// 值块操作（对应逆向 Mb）
enum ValueBlockOp {
  decrement(0xC0, '扣款'),
  increment(0xC1, '充值'),
  restore(0xC2, '恢复');

  const ValueBlockOp(this.value, this.label);
  final int value;
  final String label;
}
