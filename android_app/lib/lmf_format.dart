import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:archive/archive.dart';

/// Decoded LMF payload: a single stacked RGBA buffer, width, per-frame height
/// and frame count. The full buffer is already in "top to bottom" order, so
/// it can be drawn directly as one image of size width x (height * count).
class LmfDecoded {
  final int width;
  final int height; // per frame
  final int count;
  final Uint8List rgba; // width * (height*count) * 4 bytes

  LmfDecoded({
    required this.width,
    required this.height,
    required this.count,
    required this.rgba,
  });

  int get totalHeight => height * count;
}

class LmfFormatException implements Exception {
  final String message;
  LmfFormatException(this.message);
  @override
  String toString() => message;
}

class LmfCodec {
  static const List<int> _magic = [0x4C, 0x4D, 0x46, 0x31]; // "LMF1"
  static const int _version = 1;
  static const int _formatRgba8888 = 0;
  static const int headerSize = 26;

  /// Encodes raw image file bytes (png/jpg/webp/bmp/gif/...) into the LMF
  /// binary format. All images must share identical pixel dimensions.
  static Uint8List encode(List<Uint8List> rawImageFiles) {
    if (rawImageFiles.isEmpty) {
      throw LmfFormatException('Нет изображений для упаковки');
    }

    final decoded = <img.Image>[];
    for (final bytes in rawImageFiles) {
      final image = img.decodeImage(bytes);
      if (image == null) {
        throw LmfFormatException('Не удалось прочитать изображение');
      }
      decoded.add(image.convert(numChannels: 4));
    }

    final width = decoded.first.width;
    final height = decoded.first.height;
    for (final image in decoded) {
      if (image.width != width || image.height != height) {
        throw LmfFormatException(
            'Все изображения должны быть одного размера (${width}x$height)');
      }
    }

    final pixelBuffer = BytesBuilder();
    for (final image in decoded) {
      pixelBuffer.add(image.getBytes(order: img.ChannelOrder.rgba));
    }
    final rawPixels = pixelBuffer.toBytes();
    final compressed = const ZLibEncoder().encode(rawPixels, level: 9);

    final out = BytesBuilder();
    out.add(_magic);
    out.addByte(_version);
    out.add(_u32le(decoded.length));
    out.add(_u32le(width));
    out.add(_u32le(height));
    out.addByte(_formatRgba8888);
    out.add(_u64le(compressed.length));
    out.add(compressed);
    return out.toBytes();
  }

  static LmfDecoded decode(Uint8List data) {
    if (data.length < headerSize) {
      throw LmfFormatException('Файл повреждён');
    }
    for (int i = 0; i < 4; i++) {
      if (data[i] != _magic[i]) {
        throw LmfFormatException('Это не LMF-файл');
      }
    }
    final version = data[4];
    if (version != _version) {
      throw LmfFormatException('Неподдерживаемая версия LMF: $version');
    }

    final count = _readU32le(data, 5);
    final width = _readU32le(data, 9);
    final height = _readU32le(data, 13);
    final colorFormat = data[17];
    if (colorFormat != _formatRgba8888) {
      throw LmfFormatException('Неподдерживаемый формат пикселя');
    }
    final compressedLen = _readU64le(data, 18);

    const start = headerSize;
    final end = start + compressedLen;
    if (data.length < end) {
      throw LmfFormatException('Файл обрезан');
    }

    final compressed = data.sublist(start, end);
    final raw = const ZLibDecoder().decodeBytes(compressed);

    final expected = width * height * count * 4;
    if (raw.length != expected) {
      throw LmfFormatException('Несоответствие размера данных');
    }

    return LmfDecoded(
      width: width,
      height: height,
      count: count,
      rgba: Uint8List.fromList(raw),
    );
  }

  static List<int> _u32le(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  static List<int> _u64le(int v) {
    final b = List<int>.filled(8, 0);
    for (int i = 0; i < 8; i++) {
      b[i] = (v >> (8 * i)) & 0xFF;
    }
    return b;
  }

  static int _readU32le(Uint8List d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

  static int _readU64le(Uint8List d, int o) {
    int v = 0;
    for (int i = 0; i < 8; i++) {
      v |= d[o + i] << (8 * i);
    }
    return v;
  }
}
