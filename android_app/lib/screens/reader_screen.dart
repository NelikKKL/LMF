import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../lmf_format.dart';

/// Renders the whole LMF payload as a single image (width x height*count),
/// which naturally gives the "stacked, touching, equal size" layout since
/// the frames are already laid out top-to-bottom in the decoded buffer.
class ReaderScreen extends StatefulWidget {
  final LmfDecoded image;
  const ReaderScreen({super.key, required this.image});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  ui.Image? _decodedImage;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      widget.image.rgba,
      widget.image.width,
      widget.image.totalHeight,
      ui.PixelFormat.rgba8888,
      (result) => completer.complete(result),
    );
    final result = await completer.future;
    if (mounted) setState(() => _decodedImage = result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: _decodedImage == null
          ? const Center(child: CircularProgressIndicator())
          : InteractiveViewer(
              minScale: 0.2,
              maxScale: 6,
              child: Center(
                child: AspectRatio(
                  aspectRatio: _decodedImage!.width / _decodedImage!.height,
                  child: CustomPaint(
                    painter: _ImagePainter(_decodedImage!),
                  ),
                ),
              ),
            ),
    );
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image image;
  _ImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _ImagePainter oldDelegate) =>
      oldDelegate.image != image;
}
