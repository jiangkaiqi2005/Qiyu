import 'dart:typed_data';

/// 大端序字节序原语：豆包 ASR 网关（volc_seed_asr_gateway）与豆包双向
/// WS 合成 adapter（volc_bidirection_tts_gateway）的帧编解码共用同一
/// 处——序列号、载荷长度、错误码的读写口径收口一处，不再各写一份改名
/// 复制。src 内共用，不进包导出面。
Uint8List u32BeBytes(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

Uint8List i32BeBytes(int value) => u32BeBytes(value & 0xFFFFFFFF);

int readU32Be(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int readI32Be(List<int> bytes, int offset) {
  final raw = readU32Be(bytes, offset);
  return raw >= 0x80000000 ? raw - 0x100000000 : raw;
}
