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
  static const int _version = 2;
  static const int _formatRgba8888 = 0;
  static const int headerSize = 26;
  static const int _bpp = 4; // bytes per pixel, RGBA8888

  /// Encodes raw image file bytes (png/jpg/webp/bmp/gif/...) into the LMF
  /// binary format. Images are normalized to a common size by a centered
  /// "cover" crop around the first image's dimensions — the uniform-size
  /// rule only matters for how the format is laid out and read; the packer
  /// takes care of it automatically instead of rejecting mismatched photos.
  ///
  /// Before compression, every scanline is run through the same adaptive
  /// predictive filtering PNG uses (None/Sub/Up/Average/Paeth, picking
  /// whichever minimizes byte magnitude per row) so that zlib sees mostly
  /// small residuals instead of raw pixel noise. This is still fully
  /// lossless and dramatically improves the compression ratio on photos
  /// compared to compressing raw pixels directly.
  ///
  /// [onProgress] is called with a 0..1 fraction and a short stage label
  /// after each meaningful step, so the caller can drive a progress bar.
  static Future<Uint8List> encode(
    List<Uint8List> rawImageFiles, {
    void Function(double progress, String stage)? onProgress,
  }) async {
    if (rawImageFiles.isEmpty) {
      throw LmfFormatException('Нет изображений для упаковки');
    }

    final total = rawImageFiles.length;
    // Steps: decode+normalize+filter each image, then one compression step.
    final totalSteps = total + 1;
    int stepsDone = 0;
    void reportStep(String stage) {
      stepsDone++;
      onProgress?.call(stepsDone / totalSteps, stage);
    }

    int? targetWidth;
    int? targetHeight;
    final filteredFrames = <Uint8List>[];

    for (int i = 0; i < total; i++) {
      final source = img.decodeImage(rawImageFiles[i]);
      if (source == null) {
        throw LmfFormatException('Не удалось прочитать изображение ${i + 1}');
      }
      var image = source.convert(numChannels: 4);

      targetWidth ??= image.width;
      targetHeight ??= image.height;

      if (image.width != targetWidth || image.height != targetHeight) {
        image = _coverResize(image, targetWidth, targetHeight);
      }

      filteredFrames.add(_filterFrame(image));

      reportStep('Обработка фото ${i + 1} из $total');
      // Yield to the event loop so the UI can repaint the progress bar
      // between images instead of freezing until everything is done.
      await Future.delayed(Duration.zero);
    }

    final width = targetWidth!;
    final height = targetHeight!;

    final filteredBuffer = BytesBuilder();
    for (final frame in filteredFrames) {
      filteredBuffer.add(frame);
    }
    final compressed = const ZLibEncoder().encode(filteredBuffer.toBytes(), level: 9);
    reportStep('Сжатие данных');

    final out = BytesBuilder();
    out.add(_magic);
    out.addByte(_version);
    out.add(_u32le(filteredFrames.length));
    out.add(_u32le(width));
    out.add(_u32le(height));
    out.addByte(_formatRgba8888);
    out.add(_u64le(compressed.length));
    out.add(compressed);
    return out.toBytes();
  }

  /// Resizes [image] to exactly [targetWidth]x[targetHeight] using a
  /// centered "cover" crop: scales up so the shorter side matches, then
  /// crops the overflow from the center. Avoids stretching/distortion.
  static img.Image _coverResize(img.Image image, int targetWidth, int targetHeight) {
    final scale = (targetWidth / image.width) > (targetHeight / image.height)
        ? targetWidth / image.width
        : targetHeight / image.height;

    final scaledWidth = (image.width * scale).round();
    final scaledHeight = (image.height * scale).round();

    final resized = img.copyResize(
      image,
      width: scaledWidth,
      height: scaledHeight,
      interpolation: img.Interpolation.average,
    );

    final x = ((scaledWidth - targetWidth) / 2).round().clamp(0, scaledWidth - targetWidth);
    final y = ((scaledHeight - targetHeight) / 2).round().clamp(0, scaledHeight - targetHeight);

    return img.copyCrop(
      resized,
      x: x,
      y: y,
      width: targetWidth,
      height: targetHeight,
    );
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
    final filteredAll = Uint8List.fromList(const ZLibDecoder().decodeBytes(compressed));

    final rowBytes = width * _bpp;
    final frameFilteredSize = (rowBytes + 1) * height;
    final expected = frameFilteredSize * count;
    if (filteredAll.length != expected) {
      throw LmfFormatException('Несоответствие размера данных');
    }

    final rgba = Uint8List(rowBytes * height * count);
    for (int i = 0; i < count; i++) {
      final frameStart = i * frameFilteredSize;
      final frameFiltered = Uint8List.sublistView(
        filteredAll,
        frameStart,
        frameStart + frameFilteredSize,
      );
      final unfiltered = _unfilterFrame(frameFiltered, width, height);
      rgba.setRange(i * rowBytes * height, (i + 1) * rowBytes * height, unfiltered);
    }

    return LmfDecoded(
      width: width,
      height: height,
      count: count,
      rgba: rgba,
    );
  }

  // ---- PNG-style adaptive row filtering (None/Sub/Up/Average/Paeth) ----
  // Applied independently per frame (the "previous row" resets to zero at
  // the top of every frame). Output layout per frame: for each row, one
  // filter-type byte followed by the filtered row bytes.

  static Uint8List _filterFrame(img.Image image) {
    final width = image.width;
    final height = image.height;
    final rowBytes = width * _bpp;
    final raw = image.getBytes(order: img.ChannelOrder.rgba);
    final out = Uint8List((rowBytes + 1) * height);

    Uint8List prevRow = Uint8List(rowBytes);
    int outOffset = 0;
    for (int y = 0; y < height; y++) {
      final rowStart = y * rowBytes;
      final currentRow = Uint8List.sublistView(raw, rowStart, rowStart + rowBytes);
      final best = _bestFilter(currentRow, prevRow);
      out[outOffset] = best.type;
      out.setRange(outOffset + 1, outOffset + 1 + rowBytes, best.data);
      outOffset += rowBytes + 1;
      prevRow = currentRow;
    }
    return out;
  }

  static Uint8List _unfilterFrame(Uint8List filtered, int width, int height) {
    final rowBytes = width * _bpp;
    final out = Uint8List(rowBytes * height);

    int inOffset = 0;
    for (int y = 0; y < height; y++) {
      final type = filtered[inOffset];
      inOffset++;
      final rowStart = y * rowBytes;
      final prevRowStart = rowStart - rowBytes;

      for (int i = 0; i < rowBytes; i++) {
        final filByte = filtered[inOffset + i];
        final left = i >= _bpp ? out[rowStart + i - _bpp] : 0;
        final up = y > 0 ? out[prevRowStart + i] : 0;
        int recon;
        switch (type) {
          case 0:
            recon = filByte;
            break;
          case 1:
            recon = (filByte + left) & 0xFF;
            break;
          case 2:
            recon = (filByte + up) & 0xFF;
            break;
          case 3:
            recon = (filByte + ((left + up) >> 1)) & 0xFF;
            break;
          case 4:
            final upLeft = (y > 0 && i >= _bpp) ? out[prevRowStart + i - _bpp] : 0;
            recon = (filByte + _paeth(left, up, upLeft)) & 0xFF;
            break;
          default:
            throw LmfFormatException('Неизвестный тип фильтра строки');
        }
        out[rowStart + i] = recon;
      }
      inOffset += rowBytes;
    }
    return out;
  }

  static _FilterResult _bestFilter(Uint8List cur, Uint8List prev) {
    final candidates = [
      _FilterResult(0, _filterNone(cur)),
      _FilterResult(1, _filterSub(cur)),
      _FilterResult(2, _filterUp(cur, prev)),
      _FilterResult(3, _filterAverage(cur, prev)),
      _FilterResult(4, _filterPaeth(cur, prev)),
    ];
    candidates.sort((a, b) => _score(a.data).compareTo(_score(b.data)));
    return candidates.first;
  }

  static int _score(Uint8List data) {
    int sum = 0;
    for (final b in data) {
      sum += b < 128 ? b : 256 - b;
    }
    return sum;
  }

  static Uint8List _filterNone(Uint8List cur) => Uint8List.fromList(cur);

  static Uint8List _filterSub(Uint8List cur) {
    final out = Uint8List(cur.length);
    for (int i = 0; i < cur.length; i++) {
      final left = i >= _bpp ? cur[i - _bpp] : 0;
      out[i] = (cur[i] - left) & 0xFF;
    }
    return out;
  }

  static Uint8List _filterUp(Uint8List cur, Uint8List prev) {
    final out = Uint8List(cur.length);
    for (int i = 0; i < cur.length; i++) {
      out[i] = (cur[i] - prev[i]) & 0xFF;
    }
    return out;
  }

  static Uint8List _filterAverage(Uint8List cur, Uint8List prev) {
    final out = Uint8List(cur.length);
    for (int i = 0; i < cur.length; i++) {
      final left = i >= _bpp ? cur[i - _bpp] : 0;
      final up = prev[i];
      out[i] = (cur[i] - ((left + up) >> 1)) & 0xFF;
    }
    return out;
  }

  static Uint8List _filterPaeth(Uint8List cur, Uint8List prev) {
    final out = Uint8List(cur.length);
    for (int i = 0; i < cur.length; i++) {
      final left = i >= _bpp ? cur[i - _bpp] : 0;
      final up = prev[i];
      final upLeft = i >= _bpp ? prev[i - _bpp] : 0;
      out[i] = (cur[i] - _paeth(left, up, upLeft)) & 0xFF;
    }
    return out;
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs();
    final pb = (p - b).abs();
    final pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
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

class _FilterResult {
  final int type;
  final Uint8List data;
  _FilterResult(this.type, this.data);
}
