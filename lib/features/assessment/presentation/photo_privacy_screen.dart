import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../domain/image/image_validator.dart';
import '../domain/image/private_media_platform.dart';

class PhotoPrivacyScreen extends StatefulWidget {
  const PhotoPrivacyScreen({
    super.key,
    required this.bytes,
    this.media = const PrivateMediaPlatform(),
  });
  final Uint8List bytes;
  final PrivateMediaPlatform media;
  @override
  State<PhotoPrivacyScreen> createState() => _PhotoPrivacyScreenState();
}

class _PhotoPrivacyScreenState extends State<PhotoPrivacyScreen> {
  Rect selection = const Rect.fromLTWH(.2, .2, .4, .4);
  Rect? crop;
  final List<Rect> covers = [];
  bool busy = false;
  String? error;
  List<double> wire(Rect r) => [r.left, r.top, r.width, r.height];
  void adjust(double x, double y, double size) => setState(() {
    final width = (selection.width + size).clamp(.02, 1.0);
    final height = (selection.height + size).clamp(.02, 1.0);
    selection = Rect.fromLTWH(
      (selection.left + x).clamp(0, 1 - width),
      (selection.top + y).clamp(0, 1 - height),
      width,
      height,
    );
  });
  Future<void> apply() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final bytes = await widget.media.edit(
        widget.bytes,
        crop: crop == null ? null : wire(crop!),
        redactions: covers.map(wire).toList(),
      );
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error =
              'The edit could not be applied. Your original photo is still available.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = const ImageValidator().check(widget.bytes);
    if (info is! ImageAccepted) {
      return const Scaffold(
        body: Center(child: Text('This photo could not be opened.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Remove private details')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Move the outlined rectangle over a private detail, then add a solid cover. You can also keep only a cropped area. Check the edited photo afterward.',
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: info.width / info.height,
              child: LayoutBuilder(
                builder: (context, constraints) => Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      widget.bytes,
                      fit: BoxFit.fill,
                      cacheWidth: 1024,
                      semanticLabel: 'Photo before privacy edits',
                    ),
                    for (final r in covers)
                      Positioned(
                        left: r.left * constraints.maxWidth,
                        top: r.top * constraints.maxHeight,
                        width: r.width * constraints.maxWidth,
                        height: r.height * constraints.maxHeight,
                        child: const ColoredBox(color: Colors.black),
                      ),
                    for (final r in [?crop, selection])
                      Positioned(
                        left: r.left * constraints.maxWidth,
                        top: r.top * constraints.maxHeight,
                        width: r.width * constraints.maxWidth,
                        height: r.height * constraints.maxHeight,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: r == selection
                                    ? Colors.orange
                                    : Colors.lightGreenAccent,
                                width: 3,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                IconButton(
                  tooltip: 'Move left',
                  onPressed: busy ? null : () => adjust(-.025, 0, 0),
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  tooltip: 'Move right',
                  onPressed: busy ? null : () => adjust(.025, 0, 0),
                  icon: const Icon(Icons.arrow_forward),
                ),
                IconButton(
                  tooltip: 'Move up',
                  onPressed: busy ? null : () => adjust(0, -.025, 0),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Move down',
                  onPressed: busy ? null : () => adjust(0, .025, 0),
                  icon: const Icon(Icons.arrow_downward),
                ),
                IconButton(
                  tooltip: 'Smaller area',
                  onPressed: busy ? null : () => adjust(0, 0, -.025),
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  tooltip: 'Larger area',
                  onPressed: busy ? null : () => adjust(0, 0, .025),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            OutlinedButton(
              onPressed: busy || covers.length >= 20
                  ? null
                  : () => setState(() => covers.add(selection)),
              child: const Text('Add opaque cover'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => setState(() => crop = selection),
              child: const Text('Crop to outlined area'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      covers.clear();
                      crop = null;
                    }),
              child: const Text('Clear edits'),
            ),
            if (error != null) Text(error!, semanticsLabel: error),
            FilledButton(
              onPressed: busy || (covers.isEmpty && crop == null)
                  ? null
                  : apply,
              child: Text(busy ? 'Applying…' : 'Apply and review photo'),
            ),
          ],
        ),
      ),
    );
  }
}
