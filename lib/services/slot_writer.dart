import 'dart:typed_data';

import '../models/enums.dart';
import 'card_library.dart';
import 'device_service.dart';
import 'storage_service.dart';

/// 卡库卡片写入实体卡槽（对齐 CU slot_card_io.uploadCardToSlot）
/// [slot] 从 0 起，对应设备 API。
Future<void> uploadCardToSlot(
  DeviceService device,
  SaveCard card,
  int slot, {
  void Function(int progress)? onProgress,
}) async {
  const freqHf = 2;
  const freqLf = 1;

  if (isMifareClassic(card.tag)) {
    onProgress?.call(0);
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqHf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdHf14aSetAntiCollData(
      uid: StorageService.hexToBytes(card.uid),
      atqa: StorageService.hexToBytes(card.atqa),
      sak: StorageService.hexToBytes(
        card.sak.toRadixString(16).padLeft(2, '0'),
      ),
      ats: StorageService.hexToBytes(card.ats),
    );

    final blockCount = getBlockCountForTagType(card.tag);
    final blockChunk = <int>[];
    var lastSend = 0;
    for (var blockOffset = 0; blockOffset < blockCount; blockOffset++) {
      if ((blockOffset < card.data.length && card.data[blockOffset].isEmpty) ||
          blockChunk.length >= 128) {
        if (blockChunk.isNotEmpty) {
          await device.cmdMf1EmuWriteBlock(
            lastSend,
            Uint8List.fromList(blockChunk),
          );
          blockChunk.clear();
          lastSend = blockOffset;
        }
      }
      if (blockOffset < card.data.length) {
        final bytes = StorageService.hexToBytes(card.data[blockOffset]);
        if (bytes.length == 16) {
          blockChunk.addAll(bytes);
        }
      }
      onProgress?.call((blockOffset / blockCount * 100).round());
    }
    if (blockChunk.isNotEmpty) {
      await device.cmdMf1EmuWriteBlock(
        lastSend,
        Uint8List.fromList(blockChunk),
      );
    }
    onProgress?.call(100);

    await device.cmdSlotSetFreqName(slot, freqHf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (isEM410X(card.tag)) {
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqLf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdEm410xSetEmuId(StorageService.hexToBytes(card.uid));
    await device.cmdSlotSetFreqName(slot, freqLf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (card.tag == TagType.hidProx) {
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqLf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdHidProxSetEmuId(StorageService.hexToBytes(card.uid));
    await device.cmdSlotSetFreqName(slot, freqLf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (card.tag == TagType.viking) {
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqLf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdVikingSetEmuId(StorageService.hexToBytes(card.uid));
    await device.cmdSlotSetFreqName(slot, freqLf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (card.tag == TagType.pac) {
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqLf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdPacSetEmuId(StorageService.hexToBytes(card.uid));
    await device.cmdSlotSetFreqName(slot, freqLf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (card.tag == TagType.ioProx) {
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqLf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdIoProxSetEmuId(StorageService.hexToBytes(card.uid));
    await device.cmdSlotSetFreqName(slot, freqLf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (card.tag == TagType.idteck) {
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqLf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdIdteckSetEmuId(StorageService.hexToBytes(card.uid));
    await device.cmdSlotSetFreqName(slot, freqLf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (isMifareUltralight(card.tag)) {
    onProgress?.call(0);
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqHf, true);
    await device.cmdSlotSetActive(slot);
    await device.cmdSlotChangeTagType(slot, card.tag.value);
    await device.cmdSlotResetTagType(slot, card.tag.value);
    await device.cmdHf14aSetAntiCollData(
      uid: StorageService.hexToBytes(card.uid),
      atqa: StorageService.hexToBytes(card.atqa),
      sak: StorageService.hexToBytes(
        card.sak.toRadixString(16).padLeft(2, '0'),
      ),
      ats: StorageService.hexToBytes(card.ats),
    );

    final pageCount = mfUltralightGetPagesCount(card.tag);
    for (var page = 0; page < pageCount && page < card.data.length; page++) {
      await device.cmdMf0EmuWritePages(
        page,
        StorageService.hexToBytes(card.data[page]),
      );
      onProgress?.call((page / pageCount * 100).round());
    }

    if (card.ultralightVersion.isNotEmpty) {
      await device.cmdMf0EmuSetVersionData(
        StorageService.hexToBytes(card.ultralightVersion),
      );
    }
    if (card.ultralightSignature.isNotEmpty) {
      await device.cmdMf0EmuSetSignatureData(
        StorageService.hexToBytes(card.ultralightSignature),
      );
    }
    if (card.ultralightCounters.isNotEmpty) {
      for (var i = 0; i < card.ultralightCounters.length; i++) {
        await device.cmdMf0EmuSetCounterData(
          i,
          card.ultralightCounters[i],
          true,
        );
      }
    }
    if (mfUltralightHasCounters(card.tag)) {
      await device.cmdMf0ResetAuthCount();
    }

    onProgress?.call(100);
    await device.cmdSlotSetFreqName(slot, freqHf, card.name);
    await device.cmdSlotSaveSettings();
  }
}

/// 读取实体卡槽中的完整数据（对齐 CU slot_card_io.readSlotDump）
/// [slot] 从 0 起，[isHf] 为 true 读高频槽，false 读低频槽
Future<SaveCard?> readSlotDump(
  DeviceService device,
  int slot,
  bool isHf, {
  String? name,
  int? readCmd,
}) async {
  int originalSlot = -1;
  DeviceMode? originalMode;
  try {
    final slotTypes = await device.cmdSlotGetInfo();
    if (slot < 0 || slot >= slotTypes.length) return null;

    final typeValue = isHf ? slotTypes[slot].$1 : slotTypes[slot].$2;
    final TagType tag;
    try {
      tag = TagType.from(typeValue);
    } catch (_) {
      return null;
    }

    // 记录读取前现场，结束后恢复（围栏固件无 getActiveSlot 时 originalSlot 保持 -1，仅恢复模式）
    try {
      originalSlot = await device.cmdSlotGetActive();
    } catch (_) {}
    try {
      originalMode = await device.cmdGetDeviceMode();
    } catch (_) {}

    await device.cmdSlotSetActive(slot);
    await device.cmdChangeDeviceMode(DeviceMode.tag);

    if (!isHf) {
      // LF 卡：读取模拟器 ID
      Uint8List uid;
      switch (tag) {
        case TagType.em410X:
        case TagType.em410X16:
        case TagType.em410X32:
        case TagType.em410X64:
        case TagType.em410XElectra:
          uid = await device.cmdEm410xGetEmuId();
          break;
        case TagType.hidProx:
          uid = await device.cmdHidProxGetEmuId();
          break;
        case TagType.viking:
          uid = await device.cmdVikingGetEmuId();
          break;
        case TagType.pac:
          uid = await device.cmdPacGetEmuId();
          break;
        case TagType.ioProx:
          uid = await device.cmdIoProxGetEmuId();
          break;
        case TagType.idteck:
          uid = await device.cmdIdteckGetEmuId();
          break;
        default:
          return null;
      }
      return SaveCard(
        uid: StorageService.bytesToHex(uid),
        name: name ?? '',
        tag: tag,
      );
    }

    // HF 卡：读取反碰撞数据
    final anti = await device.cmdHf14aGetAntiCollData();
    if (anti == null) return null;

    if (isMifareUltralight(tag)) {
      final pageCount = mfUltralightGetPagesCount(tag);
      final pages = <String>[];
      for (int page = 0; page < pageCount; page++) {
        final pageData = await device.cmdMf0EmuReadPages(page, 1);
        pages.add(StorageService.bytesToHex(pageData));
      }

      final versionData = await device.cmdMf0EmuGetVersionData();
      final signatureData = await device.cmdMf0EmuGetSignatureData();
      final counters = <int>[];
      for (int i = 0; i < mfUltralightGetCounterCount(tag); i++) {
        final (val, _) = await device.cmdMf0EmuGetCounterData(i);
        counters.add(val);
      }

      return SaveCard(
        uid: anti.uidHex,
        name: name ?? '',
        sak: anti.sak,
        atqa: anti.atqaHex,
        ats: anti.atsHex,
        tag: tag,
        data: pages,
        ultralightVersion: StorageService.bytesToHex(versionData),
        ultralightSignature: StorageService.bytesToHex(signatureData),
        ultralightCounters: counters,
      );
    } else if (isMifareClassic(tag)) {
      final blockCount = getBlockCountForTagType(tag);
      final blocks = <String>[];
      final readCount = 16;
      var binDataIndex = 0;
      final binData = Uint8List(blockCount * 16);

      for (
        int currentBlock = 0;
        currentBlock < blockCount;
        currentBlock += readCount
      ) {
        final result = await device.cmdRaw(
          readCmd ?? 4008,
          Uint8List.fromList([currentBlock, readCount]),
        );
        if (result.length >= 16) {
          binData.setRange(binDataIndex, binDataIndex + result.length, result);
          binDataIndex += result.length;
        }
      }

      for (int i = 0; i < binData.length; i += 16) {
        final block = binData.sublist(i, i + 16);
        blocks.add(StorageService.bytesToHex(block));
      }

      return SaveCard(
        uid: anti.uidHex,
        name: name ?? '',
        sak: anti.sak,
        atqa: anti.atqaHex,
        ats: anti.atsHex,
        tag: tag,
        data: blocks,
      );
    }

    return null;
  } catch (_) {
    return null;
  } finally {
    // 恢复原激活槽与设备模式（容错：固件不支持时静默跳过）
    try {
      if (originalSlot >= 0 && originalSlot != slot) {
        await device.cmdSlotSetActive(originalSlot);
      }
      if (originalMode != null && originalMode != DeviceMode.tag) {
        await device.cmdChangeDeviceMode(originalMode);
      }
    } catch (_) {}
  }
}
