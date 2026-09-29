import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/scan_projection.dart';

class BathroomModelView extends StatefulWidget {
  const BathroomModelView({
    super.key,
    required this.scene,
    this.selectedId,
    this.selectedLabel,
    required this.onSelect,
  });
  final BathroomScanScene scene;
  final String? selectedId;

  final String? selectedLabel;
  final ValueChanged<String> onSelect;
  @override
  State<BathroomModelView> createState() => _BathroomModelViewState();
}

class _BathroomModelViewState extends State<BathroomModelView> {
  double yaw = -.65, pitch = .55, zoom = 1, startZoom = 1;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: ColoredBox(
          color: const Color(0xFF123F3C),
          child: SizedBox(
            height: 300,
            child: LayoutBuilder(
              builder: (context, bounds) {
                final projection = ScanProjection.project(
                  widget.scene,
                  width: bounds.maxWidth,
                  height: 300,
                  yaw: yaw,
                  pitch: pitch,
                );
                return Semantics(
                  value: widget.selectedLabel == null
                      ? null
                      : 'Selected: ${widget.selectedLabel}',
                  label:
                      'Partial bathroom model. ${widget.scene.elements.length} detected features and ${widget.scene.points.length} point samples. Use the feature list below to review each item.',
                  child: GestureDetector(
                    onScaleStart: (_) => startZoom = zoom,
                    onScaleUpdate: (details) => setState(() {
                      zoom = (startZoom * details.scale).clamp(.7, 2.5);
                      if (details.pointerCount == 1) {
                        yaw += details.focalPointDelta.dx * .008;
                        pitch = (pitch + details.focalPointDelta.dy * .008)
                            .clamp(-math.pi / 2, math.pi / 2);
                      }
                    }),
                    onTapUp: (details) {
                      final middle = Offset(bounds.maxWidth / 2, 150);
                      final at =
                          (details.localPosition - middle) / zoom + middle;
                      for (final face in projection.faces.reversed) {
                        if (_facePath(face).contains(at)) {
                          widget.onSelect(face.elementId);
                          return;
                        }
                      }
                    },
                    child: CustomPaint(
                      painter: _ModelPainter(
                        projection,
                        widget.selectedId,
                        zoom,
                      ),
                      child: const Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: ExcludeSemantics(
                            child: Text(
                              'PARTIAL 3D MODEL',
                              style: TextStyle(
                                color: Color(0xFFD4E8DF),
                                fontSize: 12,
                                letterSpacing: 1.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          IconButton(
            tooltip: 'Rotate model left',
            onPressed: () => setState(() => yaw -= .3),
            icon: const Icon(Icons.rotate_left),
          ),
          IconButton(
            tooltip: 'Rotate model right',
            onPressed: () => setState(() => yaw += .3),
            icon: const Icon(Icons.rotate_right),
          ),
          TextButton(
            onPressed: () => setState(() {
              yaw = 0;
              pitch = math.pi / 2;
            }),
            child: const Text('Top'),
          ),
          TextButton(
            onPressed: () => setState(() {
              yaw = 0;
              pitch = 0;
            }),
            child: const Text('Front'),
          ),
          IconButton(
            tooltip: 'Zoom out',
            onPressed: () => setState(() => zoom = (zoom - .2).clamp(.7, 2.5)),
            icon: const Icon(Icons.remove),
          ),
          IconButton(
            tooltip: 'Zoom in',
            onPressed: () => setState(() => zoom = (zoom + .2).clamp(.7, 2.5)),
            icon: const Icon(Icons.add),
          ),
          TextButton(
            onPressed: () => setState(() {
              yaw = -.65;
              pitch = .55;
              zoom = 1;
            }),
            child: const Text('Reset view'),
          ),
        ],
      ),
      const Text(
        'Drag to rotate · Pinch to zoom · Tap a feature\nEmpty space can mean unscanned space.',
        textAlign: TextAlign.center,
      ),
    ],
  );
}

Path _facePath(ProjectedScanFace face) =>
    Path()
      ..addPolygon(face.vertices.map((p) => Offset(p.x, p.y)).toList(), true);

class _ModelPainter extends CustomPainter {
  _ModelPainter(this.projection, this.selectedId, this.zoom);
  final ScanProjection projection;
  final String? selectedId;
  final double zoom;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(zoom);
    canvas.translate(-size.width / 2, -size.height / 2);
    final grid = Paint()
      ..color = const Color(0xFF37615B)
      ..strokeWidth = .5;
    for (var x = 0.0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final points = Paint()..color = const Color(0xFF91C6B7);
    for (final p in projection.points) {
      canvas.drawCircle(Offset(p.x, p.y), .9 / zoom, points);
    }
    for (final face in projection.faces) {
      final selected = face.elementId == selectedId;
      final base = selected
          ? const Color(0xFFF2B48E)
          : switch (face.kind) {
              ScanElementKind.wall ||
              ScanElementKind.floor => const Color(0xFFAFCEBE),
              ScanElementKind.door ||
              ScanElementKind.opening => const Color(0xFFB7DDEE),
              _ => const Color(0xFFE2EBCB),
            };
      final path = _facePath(face);
      canvas.drawPath(
        path,
        Paint()..color = base.withValues(alpha: selected ? .65 : .16),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = base.withValues(alpha: selected ? 1 : .65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (selected ? 2 : 1) / zoom,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ModelPainter oldDelegate) => true;
}
