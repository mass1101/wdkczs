import 'enums.dart';

/// 数据模型：设备信息、卡槽、卡数据（对应逆向 sT/vT/jT/zT）

/// 默认密钥表
const List<String> kDefaultKeys = [
  'ffffffffffff',
  'a0a1a2a3a4a5',
  '000000000000',
];

/// 破解专用密钥表
const List<String> kCrackKeys = [
  'a396efa4e24f',
  'a31667a8cec1',
  '518b3354e760',
];

/// 卡槽数据（对应逆向 slots 单条）
class SlotData {
  int slot;
  int hfType; // TagType.value
  int lfType;
  String hfName;
  String lfName;
  String uid;
  String sak;
  String atqa;
  String ats;
  Mf1Settings mf1Settings;
  bool hfEnabled;
  bool lfEnabled;

  SlotData({
    this.slot = 0,
    this.hfType = 0,
    this.lfType = 4,
    this.hfName = '',
    this.lfName = '',
    this.uid = '',
    this.sak = '',
    this.atqa = '',
    this.ats = '',
    Mf1Settings? mf1Settings,
    this.hfEnabled = true,
    this.lfEnabled = false,
  }) : mf1Settings = mf1Settings ?? Mf1Settings();

  Map<String, dynamic> toJson() => {
        'slot': slot,
        'hfType': hfType,
        'lfType': lfType,
        'hfName': hfName,
        'lfName': lfName,
        'uid': uid,
        'sak': sak,
        'atqa': atqa,
        'ats': ats,
        'mf1Settings': mf1Settings.toJson(),
        'hfEnabled': hfEnabled,
        'lfEnabled': lfEnabled,
      };

  factory SlotData.fromJson(Map<String, dynamic> j) => SlotData(
        slot: j['slot'] ?? 0,
        hfType: j['hfType'] ?? 0,
        lfType: j['lfType'] ?? 4,
        hfName: j['hfName'] ?? '',
        lfName: j['lfName'] ?? '',
        uid: j['uid'] ?? '',
        sak: j['sak'] ?? '',
        atqa: j['atqa'] ?? '',
        ats: j['ats'] ?? '',
        mf1Settings: j['mf1Settings'] != null
            ? Mf1Settings.fromJson(j['mf1Settings'])
            : Mf1Settings(),
        hfEnabled: j['hfEnabled'] ?? true,
        lfEnabled: j['lfEnabled'] ?? false,
      );
}

/// MIFARE 1K 模拟配置
class Mf1Settings {
  bool detection;
  bool gen1a;
  bool gen2;
  bool write;
  bool antiColl;

  Mf1Settings({
    this.detection = false,
    this.gen1a = false,
    this.gen2 = false,
    this.write = false,
    this.antiColl = true,
  });

  Map<String, dynamic> toJson() => {
        'detection': detection,
        'gen1a': gen1a,
        'gen2': gen2,
        'write': write,
        'antiColl': antiColl,
      };

  factory Mf1Settings.fromJson(Map<String, dynamic> j) => Mf1Settings(
        detection: j['detection'] ?? false,
        gen1a: j['gen1a'] ?? false,
        gen2: j['gen2'] ?? false,
        write: j['write'] ?? false,
        antiColl: j['antiColl'] ?? true,
      );
}

/// 全局设置（对应逆向 deviceSetting）
class DeviceSettings {
  AnimationMode animation;
  bool blePairing;
  bool buttonModePairing; // 蓝牙配对方式（按钮/密码）
  String blePairingKey;
  ButtonAction pressBtnA;
  ButtonAction pressBtnB;
  ButtonAction longPressBtnA;
  ButtonAction longPressBtnB;

  DeviceSettings({
    this.animation = AnimationMode.full,
    this.blePairing = false,
    this.buttonModePairing = true,
    this.blePairingKey = '0000',
    this.pressBtnA = ButtonAction.disable,
    this.pressBtnB = ButtonAction.disable,
    this.longPressBtnA = ButtonAction.disable,
    this.longPressBtnB = ButtonAction.disable,
  });

  Map<String, dynamic> toJson() => {
        'animation': animation.value,
        'blePairing': blePairing,
        'buttonModePairing': buttonModePairing,
        'blePairingKey': blePairingKey,
        'pressBtnA': pressBtnA.value,
        'pressBtnB': pressBtnB.value,
        'longPressBtnA': longPressBtnA.value,
        'longPressBtnB': longPressBtnB.value,
      };

  factory DeviceSettings.fromJson(Map<String, dynamic> j) => DeviceSettings(
        animation: AnimationMode.from(j['animation'] ?? 0),
        blePairing: j['blePairing'] ?? false,
        buttonModePairing: j['buttonModePairing'] ?? true,
        blePairingKey: j['blePairingKey'] ?? '0000',
        pressBtnA: ButtonAction.from(j['pressBtnA'] ?? 0),
        pressBtnB: ButtonAction.from(j['pressBtnB'] ?? 0),
        longPressBtnA: ButtonAction.from(j['longPressBtnA'] ?? 0),
        longPressBtnB: ButtonAction.from(j['longPressBtnB'] ?? 0),
      );
}

/// 设备信息（设置页顶部）
class DeviceInfo {
  String version; // 固件版本
  String gitVersion; // git 版本
  String chipId; // 芯片编号
  String bleAddress; // 蓝牙地址
  String model; // 设备型号
  String batteryVoltage; // 电压
  int batteryLevel; // 电量百分比（-1 表示未知）

  DeviceInfo({
    this.version = '',
    this.gitVersion = '',
    this.chipId = '',
    this.bleAddress = '',
    this.model = '',
    this.batteryVoltage = '',
    this.batteryLevel = -1,
  });
}

/// 单块数据（对应逆向 body 中一行 hex，16 字节）
class BlockData {
  String data; // 32 hex chars
  bool marked; // 高亮标记

  BlockData({this.data = '00000000000000000000000000000000', this.marked = false});
}

/// 扇区数据（4 块）
class SectorData {
  List<BlockData> blocks;
  bool selected; // 勾选

  SectorData({List<BlockData>? blocks, this.selected = false})
      : blocks = blocks ??
            List.generate(
                4, (_) => BlockData());

  static SectorData empty() => SectorData();

  String toDumpLines() => blocks.map((b) => b.data).join('\n');
}

/// 当前编辑的 IC 卡数据（对应逆向 vT）
class CardState {
  int slot; // 当前槽位
  String uid;
  String atqa;
  String sak;
  String ats;
  String keys; // 密钥表，每行 12 hex
  List<SectorData> sectors; // 16 个扇区
  List<bool> toggle; // 扇区勾选
  String name; // 卡片名称
  bool antiColl;

  CardState({
    this.slot = 0,
    this.uid = 'deadbeef',
    this.atqa = '0004',
    this.sak = '08',
    this.ats = '',
    String? keys,
    List<SectorData>? sectors,
    List<bool>? toggle,
    this.name = '',
    this.antiColl = true,
  })  : keys = keys ?? kDefaultKeys.join('\n'),
        sectors = sectors ?? List.generate(16, (_) => SectorData()),
        toggle = toggle ?? List.generate(16, (_) => true);

  /// 根据 64 行文本构建扇区数据
  static CardState fromDumpText(List<String> lines) {
    final uid = lines[0].substring(0, 8).toLowerCase();
    final sak = lines[0].substring(10, 12).toLowerCase();
    final atqaRaw = lines[0].substring(12, 16);
    final atqa = atqaRaw == '' ? '0004' : '${atqaRaw[2]}${atqaRaw[3]}${atqaRaw[0]}${atqaRaw[1]}'.toLowerCase();
    final state = CardState(uid: uid, sak: sak, atqa: atqa);
    for (var s = 0; s < 16; s++) {
      final blocks = List<BlockData>.generate(4, (i) {
        final line = lines[s * 4 + i];
        return BlockData(data: line.replaceAll('-', '0'));
      });
      state.sectors[s] = SectorData(blocks: blocks);
    }
    return state;
  }

  /// 导出完整 dump 文本（64 行 + 块编号）
  String toDumpText() {
    final buf = StringBuffer();
    for (var s = 0; s < 16; s++) {
      for (var b = 0; b < 4; b++) {
        buf.writeln(sectors[s].blocks[b].data);
      }
    }
    return buf.toString();
  }

  /// 导出带区块标记的对比文本（对应逆向导出的 .txt 格式）
  String toDumpFileText() {
    final buf = StringBuffer();
    for (var s = 0; s < 16; s++) {
      buf.writeln('+Sector: $s');
      for (var b = 0; b < 4; b++) {
        buf.writeln(sectors[s].blocks[b].data);
      }
    }
    return buf.toString();
  }
}

/// ID 卡数据（对应逆向 vT 的 id_card 部分）
class IdCardState {
  String idCard; // 10 位十进制卡号
  String idCardHex; // 十六进制
  List<IdCardItem> idCards; // 已保存卡列表
  String idCardKeys; // 4 个密钥，每行 8 hex

  IdCardState({
    this.idCard = '1122334455',
    List<IdCardItem>? idCards,
    String? idCardKeys,
  })  : idCardHex = int.parse(idCard.isEmpty ? '0' : idCard)
            .toRadixString(16)
            .toUpperCase()
            .padLeft(8, '0'),
        idCards = idCards ?? [IdCardItem(id: '1122334455', name: '未命名')],
        idCardKeys = idCardKeys ?? '19920427\n1dd00a11\n20206666\n51243648';

  void setCard(String card) {
    idCard = card;
    idCardHex = int.parse(card.isEmpty ? '0' : card)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(8, '0');
  }
}

class IdCardItem {
  String id;
  String name;

  IdCardItem({this.id = '', this.name = '未命名'});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory IdCardItem.fromJson(Map<String, dynamic> j) =>
      IdCardItem(id: j['id'] ?? '', name: j['name'] ?? '未命名');
}

/// 云端破解任务（对应逆向云功能任务模型）
class CrackTask {
  String id;
  String cardId; // UID
  int sector;
  KeyType keyType;
  String key; // 破解结果（空=进行中，error=失败）
  bool saved;

  CrackTask({
    required this.id,
    required this.cardId,
    required this.sector,
    required this.keyType,
    this.key = '',
    this.saved = false,
  });

  String get name => '${cardId}_${sector}_${keyType.label}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'cardId': cardId,
        'sector': sector,
        'keyType': keyType.value == 0x60 ? 'A' : 'B',
        'key': key,
        'saved': saved,
      };

  factory CrackTask.fromJson(Map<String, dynamic> j) => CrackTask(
        id: j['id'] ?? '',
        cardId: j['cardId'] ?? '',
        sector: j['sector'] ?? 0,
        keyType: j['keyType'] == 'B' ? KeyType.keyB : KeyType.keyA,
        key: j['key'] ?? '',
        saved: j['saved'] ?? false,
      );
}

/// 检测日志条目（Darkside 采集）
class DetectLog {
  int uid; // 4 字节 uid 前 4
  int nt;
  int nr;
  int ar;

  DetectLog({required this.uid, required this.nt, required this.nr, required this.ar});

  Map<String, dynamic> toJson() =>
      {'uid': uid, 'nt': nt, 'nr': nr, 'ar': ar};

  factory DetectLog.fromJson(Map<String, dynamic> j) => DetectLog(
        uid: j['uid'] ?? 0,
        nt: j['nt'] ?? 0,
        nr: j['nr'] ?? 0,
        ar: j['ar'] ?? 0,
      );
}
