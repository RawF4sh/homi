import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../domain/capture/capture_adapter.dart';
import '../domain/image/private_media_platform.dart';

class NativeCaptureAdapter implements CaptureAdapter {
  NativeCaptureAdapter({
    required this.context,
    PrivateMediaPlatform media = const PrivateMediaPlatform(),
    ImagePicker? picker,
  }) : _media = media,
       _picker = picker ?? ImagePicker();
  final BuildContext Function() context;
  final PrivateMediaPlatform _media;
  final ImagePicker _picker;

  static Future<bool> discardInterruptedImport() async {
    if (!Platform.isAndroid) return false;
    final response = await ImagePicker().retrieveLostData();
    for (final file in response.files ?? <XFile>[]) {
      try {
        await File(file.path).delete();
      } catch (_) {}
    }
    return !response.isEmpty;
  }

  @override
  Future<CaptureResult> capture(CaptureRequest request) async {
    XFile? file;
    try {
      await discardInterruptedImport();
      await _media.prepareCaptureStorage();
      if (request.source == CaptureSource.library) {
        if (Platform.isIOS) {
          final path = await _media.pickPhoto();
          file = path == null ? null : XFile(path);
        } else {
          file = await _picker.pickImage(
            source: ImageSource.gallery,
            requestFullMetadata: false,
          );
        }
      } else {
        final outcome = await Navigator.of(context()).push<_CameraOutcome>(
          MaterialPageRoute(builder: (_) => const _CameraScreen()),
        );
        if (outcome?.error != null) {
          return _failure(outcome!.error!);
        }
        file = outcome?.file;
      }
      if (file == null) return const CaptureCancelled();
      final bytes = await _media.normalizePath(file.path);
      return CaptureSucceeded(
        bytes,
        orientationNormalized: true,
        capturedAt: request.source == CaptureSource.camera
            ? DateTime.now().toUtc().toIso8601String()
            : null,
      );
    } on CameraException catch (error) {
      return _failure(error.code);
    } on PlatformException catch (error) {
      return _failure(error.code);
    } catch (_) {
      return const CaptureFailed('photo_processing_failed');
    } finally {
      if (file != null) {
        try {
          await File(file.path).delete();
        } catch (_) {
          // ignore: empty_catches
        }
      }
    }
  }

  CaptureResult _failure(String code) => switch (code) {
    'CameraAccessDenied' ||
    'CameraAccessDeniedWithoutPrompt' ||
    'CameraAccessRestricted' ||
    'photo_access_denied' => const CapturePermissionDenied(canAskAgain: false),
    'no_camera' => const CaptureUnavailable(),
    _ => const CaptureFailed('camera_unavailable'),
  };
}

class _CameraOutcome {
  const _CameraOutcome({this.file, this.error});
  final XFile? file;
  final String? error;
}

class _CameraScreen extends StatefulWidget {
  const _CameraScreen();
  @override
  State<_CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<_CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _taking = false;
  bool _foreground = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (!mounted || generation != _generation || !_foreground) return;
      if (cameras.isEmpty) {
        Navigator.of(context).pop(const _CameraOutcome(error: 'no_camera'));
        return;
      }
      final camera =
          cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .firstOrNull ??
          cameras.first;
      controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      if (!mounted || generation != _generation || !_foreground) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } on CameraException catch (error) {
      await controller?.dispose();
      if (mounted && generation == _generation) {
        Navigator.of(context).pop(_CameraOutcome(error: error.code));
      }
    } catch (_) {
      await controller?.dispose();
      if (mounted && generation == _generation) {
        Navigator.of(context).pop(const _CameraOutcome(error: 'unavailable'));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _foreground = false;
      _generation++;
      final previous = _controller;
      _controller = null;
      previous?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && !_foreground) {
      _foreground = true;
      _open();
    }
  }

  Future<void> _take() async {
    final controller = _controller;
    if (_taking || controller == null || !controller.value.isInitialized) {
      return;
    }
    setState(() => _taking = true);
    try {
      final file = await controller.takePicture();
      if (mounted) {
        Navigator.of(context).pop(_CameraOutcome(file: file));
      } else {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
    } catch (_) {
      if (mounted) {
        setState(() => _taking = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The photo was interrupted. Please try again.'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Take a home photo')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Keep people, mail, medicines and account details out of the picture.',
            ),
          ),
          Expanded(
            child: _controller == null
                ? const Center(
                    child: CircularProgressIndicator(
                      semanticsLabel: 'Preparing camera',
                    ),
                  )
                : Center(child: CameraPreview(_controller!)),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _taking || _controller == null ? null : _take,
              icon: const Icon(Icons.camera_alt),
              label: Text(_taking ? 'Taking photo…' : 'Take photo'),
            ),
          ),
        ],
      ),
    ),
  );
}
