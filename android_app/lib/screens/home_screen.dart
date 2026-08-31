import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../lmf_format.dart';
import 'reader_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _busy = false;

  // Extracts the trailing integer in a filename (before the extension),
  // e.g. "photo_12.png" -> 12. Falls back to 0 if none is found, so files
  // without a number still sort stably by original order.
  int _trailingNumber(String name) {
    final base = name.contains('.')
        ? name.substring(0, name.lastIndexOf('.'))
        : name;
    final match = RegExp(r'(\d+)$').firstMatch(base);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  Future<void> _pack() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'heic'],
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final files = [...result.files];
    files.sort((a, b) => _trailingNumber(a.name).compareTo(_trailingNumber(b.name)));

    setState(() => _busy = true);
    try {
      final bytesList = <Uint8List>[
        for (final f in files) f.bytes ?? await File(f.path!).readAsBytes(),
      ];
      final lmfBytes = LmfCodec.encode(bytesList);

      final dir = await getTemporaryDirectory();
      final outFile = File('${dir.path}/output.lmf');
      await outFile.writeAsBytes(lmfBytes);

      if (!mounted) return;
      await Share.shareXFiles([XFile(outFile.path)]);
    } catch (e) {
      if (mounted) _showError(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openReader() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['lmf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();

    try {
      final decoded = LmfCodec.decode(bytes);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ReaderScreen(image: decoded)),
      );
    } catch (e) {
      _showError(e.toString());
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.photo_library_outlined, size: 72),
                const SizedBox(height: 40),
                FilledButton.icon(
                  onPressed: _busy ? null : _pack,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Собрать LMF'),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _openReader,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Открыть LMF'),
                ),
                if (_busy) ...[
                  const SizedBox(height: 32),
                  const CircularProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
