import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera Error: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'My Live Cam',
      theme: ThemeData.dark(),
      home: const CameraStreamScreen(),
    );
  }
}

class CameraStreamScreen extends StatefulWidget {
  const CameraStreamScreen({super.key});

  @override
  State<CameraStreamScreen> createState() => _CameraStreamScreenState();
}

class _CameraStreamScreenState extends State<CameraStreamScreen> {
  CameraController? _cameraController;
  HttpServer? _server;
  
  int _selectedCameraIndex = 0; // 0: Back Camera, 1: Front Camera
  bool _isStreaming = false;
  String _ipAddress = 'Fetching IP...';
  String _statusMessage = 'Press Start';
  final int _port = 8080;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _getIPAddress();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera].request();
    _initCamera(_selectedCameraIndex);
  }

  Future<void> _getIPAddress() async {
    try {
      final info = NetworkInfo();
      String? ip = await info.getWifiIP();
      setState(() {
        _ipAddress = ip ?? '127.0.0.1';
      });
    } catch (_) {
      setState(() {
        _ipAddress = '127.0.0.1';
      });
    }
  }

  // ക്യാമറ തുടക്കത്തിൽ ക്രമീകരിക്കാനും (ResolutionPreset.medium) ക്യാമറ സ്വിച്ച് ചെയ്യാനും
  Future<void> _initCamera(int cameraIndex) async {
    if (_cameras.isEmpty) return;

    if (_cameraController != null) {
      await _cameraController!.dispose();
    }

    _cameraController = CameraController(
      _cameras[cameraIndex],
      ResolutionPreset.medium, // സ്ക്രീൻ വലിപ്പവും ക്വാളിറ്റിയും കൂട്ടാൻ Medium റെസല്യൂഷൻ നൽകി
      enableAudio: false,
    );

    await _cameraController!.initialize();
    if (mounted) setState(() {});
  }

  // ഫ്രണ്ട് / ബാക്ക് ക്യാമറ സ്വിച്ച് ചെയ്യാനുള്ള ഫംഗ്ഷൻ
  void _toggleCamera() {
    if (_cameras.length < 2) return;
    setState(() {
      _selectedCameraIndex = (_selectedCameraIndex == 0) ? 1 : 0;
    });
    _initCamera(_selectedCameraIndex);
  }

  Future<void> _startStreaming() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      
      _server!.listen((HttpRequest request) async {
        if (request.uri.path == '/shot.jpg') {
          try {
            XFile photo = await _cameraController!.takePicture();
            Uint8List bytes = await photo.readAsBytes();
            request.response.headers.contentType = ContentType('image', 'jpeg');
            request.response.add(bytes);
            await request.response.close();
          } catch (e) {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });

      setState(() {
        _isStreaming = true;
        _statusMessage = 'Streaming Live...';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Server Error: $e';
        _isStreaming = false;
      });
    }
  }

  Future<void> _stopStreaming() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}

    setState(() {
      _isStreaming = false;
      _statusMessage = 'Stream Stopped';
    });
  }

  @override
  void dispose() {
    _stopStreaming();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Live Webcam'),
        actions: [
          // ഫ്രണ്ട്/ബാക്ക് ക്യാമറ മാറ്റാനുള്ള ഐക്കൺ ബട്ടൺ
          if (_cameras.length > 1)
            IconButton(
              icon: const Icon(Icons.switch_camera),
              onPressed: _isStreaming ? null : _toggleCamera, // സ്ട്രീമിംഗ് നടക്കുമ്പോൾ ക്യാമറ മാറാതിരിക്കാൻ
              tooltip: 'Switch Camera',
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _cameraController != null && _cameraController!.value.isInitialized
                ? AspectRatio(
                    aspectRatio: _cameraController!.value.aspectRatio,
                    child: CameraPreview(_cameraController!),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            padding: const EdgeInsets.all(16.0),
            color: Colors.black87,
            child: Column(
              children: [
                SelectableText(
                  _isStreaming
                      ? 'URL: http://$_ipAddress:$_port/shot.jpg'
                      : _statusMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.greenAccent),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isStreaming ? Colors.red : Colors.green,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
                  label: Text(_isStreaming ? 'STOP STREAMING' : 'START STREAMING'),
                  onPressed: () {
                    if (_isStreaming) {
                      _stopStreaming();
                    } else {
                      _startStreaming();
                    }
                  },
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
