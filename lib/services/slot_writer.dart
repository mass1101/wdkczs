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
      sak: StorageService.hexToBytes(card.sak.toRadixString(16).padLeft(2, '0')),
      ats: StorageService.hexToBytes(card.ats),
    );

    final blockCount = card.tag == TagType.mifareClassic4k ? 256 : 64;
    final blockChunk = <int>[];
    var lastSend = 0;
    for (var blockOffset = 0; blockOffset < blockCount; blockOffset++) {
      if ((blockOffset < card.data.length && card.data[blockOffset].isEmpty) ||
          blockChunk.length >= 128) {
        if (blockChunk.isNotEmpty) {
          await device.cmdMf1EmuWriteBlock(
              lastSend, Uint8List.fromList(blockChunk));
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
      await device
          .cmdMf1EmuWriteBlock(lastSend, Uint8List.fromList(blockChunk));
    }
    onProgress?.call(100);

    await device.cmdSlotSetFreqName(slot, freqHf, card.name);
    await device.cmdSlotSaveSettings();
  } else if (isEM410X(card.tag)) {
    await device.cmdChangeDeviceMode(DeviceMode.tag);
    await device.cmdSlotSetEnable(slot, freqLf, true);
    await device.cmdSlotSetActive(slot);
    final slotTagType =
        card.tag == TagType.electra ? TagType.electra : TagType.em4100;
    await device.cmdSlotChangeTagType(slot, slotTagType.value);
    await device.cmdSlotResetTagType(slot, slotTagType.value);
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
      sak: StorageService.hexToBytes(card.sak.toRadixString(16).padLeft(2, '0')),
      ats: StorageService.hexToBytes(card.ats),
    );

    final pageCount = card.tag == TagType.ntag215 ? 135 : 41;
    for (var page = 0; page < pageCount && page < card.data.length; page++) {
      await device
          .cmdMf0EmuWritePages(page, StorageService.hexToBytes(card.data[page]));
      onProgress?.call((page / pageCount * 100).round());
    }

    if (card.ultralightVersion.isNotEmpty) {
      await device
          .cmdMf0EmuSetVersionData(StorageService.hexToBytes(card.ultralightVersion));
    }
    if (card.ultralightSignature.isNotEmpty) {
      await device.cmdMf0EmuSetSignatureData(
          StorageService.hexToBytes(card.ultralightSignature));
    }
    if (card.ultralightCounters.isNotEmpty) {
      for (var i = 0; i < card.ultralightCounters.length; i++) {
        await device
            .cmdMf0EmuSetCounterData(i, card.ultralightCounters[i], true);
      }
    }
    await device.cmdMf0ResetAuthCount();

    onProgress?.call(100);
    await device.cmdSlotSetFreqName(slot, freqHf, card.name);
    await device.cmdSlotSaveSettings();
  }
}