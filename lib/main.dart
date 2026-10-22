// language: Dart, file: main.dart, target: Flutter 3.19+, Android 14
// WiFi Heatmap — single-file app: models, bridge, painter, screen, entry.
// Android bridge (MainActivity.kt) unchanged — still required for WifiManager access.

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const HeatmapScreen(),
      );
}

// ---------- models ----------

class WifiReading {
  final String ssid;
  final String bssid;
  final int rssi;
  final int frequency;
  WifiReading({
    required this.ssid,
    required this.bssid,
    required this.rssi,
    required this.frequency,
  });
}

class ScanPoint {
  final double nx; // 0..1 normalized
  final double ny; // 0..1 normalized
  final int rssi;
  final String bssid;
  ScanPoint({
    required this.nx,
    required this.ny,
    required this.rssi,
    required this.bssid,
  });
}

// ---------- wifi bridge ----------

class WifiBridge {
  static const _ch = MethodChannel('wifi_heatmap');

  Future<List<WifiReading>> startScan() async =>
      _parse(await _ch.invokeMethod<List<dynamic>>('startScan'));

  Future<List<WifiReading>> getResults() async =>
      _parse(await _ch.invokeMethod<List<dynamic>>('getResults'));

  Future<bool> isLocationEnabled() async =>
      (await _ch.invokeMethod<bool>('isLocationEnabled')) ?? false;

  Future<void> openLocationSettings() async =>
      _ch.invokeMethod('openLocationSettings');

  List<WifiReading> _parse(List<dynamic>? raw) {
    if (raw == null) return [];
    return raw.map((m) {
      final map = Map<String, dynamic>.from(m as Map);
      return WifiReading(
        ssid: (map['ssid'] as String?) ?? '',
        bssid: map['bssid'] as String,
        rssi: map['rssi'] as int,
        frequency: map['frequency'] as int,
      );
    }).toList();
  }
}

// ---------- heatmap painter ----------

class HeatmapPainter extends CustomPainter {
  final List<ScanPoint> points;
  final int version;
  final Size canvasSize;

  HeatmapPainter({
    required this.points,
    required this.version,
    required this.canvasSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    double minR = double.infinity, maxR = double.negativeInfinity;
    for (final p in points) {
      if (p.rssi < minR) minR = p.rssi.toDouble();
      if (p.rssi > maxR) maxR = p.rssi.toDouble();
    }
    if ((maxR - minR) < 10) {
      final mid = (maxR + minR) / 2;
      minR = mid - 10;
      maxR = mid + 10;
    }

    const cell = 12.0;
    final fill = Paint()..style = PaintingStyle.fill;
    final dot = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (double y = 0; y < size.height; y += cell) {
      for (double x = 0; x < size.width; x += cell) {
        final v = _idw(Offset(x + cell / 2, y + cell / 2), size);
        if (v == null) continue;
        fill.color = _color(v, minR, maxR);
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), fill);
      }
    }

    for (final p in points) {
      canvas.drawCircle(Offset(p.nx * size.width, p.ny * size.height), 3, dot);
    }
  }

  double? _idw(Offset p, Size size) {
    double num = 0, den = 0;
    for (final sp in points) {
      final dx = p.dx - sp.nx * size.width;
      final dy = p.dy - sp.ny * size.height;
      final d2 = dx * dx + dy * dy;
      if (d2 < 1) return sp.rssi.toDouble();
      final w = 1.0 / d2; // IDW power = 2
      num += w * sp.rssi;
      den += w;
    }
    return den > 0 ? num / den : null;
  }

  Color _color(double v, double minR, double maxR) {
    final t = ((v - minR) / (maxR - minR)).clamp(0.0, 1.0);
    return HSVColor.fromAHSV(0.55, 120 * t, 0.9, 0.95).toColor();
  }

  @override
  bool shouldRepaint(covariant HeatmapPainter old) =>
      old.version != version || old.canvasSize != canvasSize;
}

// ---------- screen ----------

class HeatmapScreen extends StatefulWidget {
  const HeatmapScreen({super.key});
  @override
  State<HeatmapScreen> createState() => _HeatmapScreenState();
}

class _HeatmapScreenState extends State<HeatmapScreen> {
  final _wifi = WifiBridge();
  final _picker = ImagePicker();

  final List<ScanPoint> _points = [];
  final Map<String, WifiReading> _networks = {};
  String? _targetBssid;
  Uint8List? _floorplan;
  int? _liveRssi;
  int _version = 0;
  Timer? _poll;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final loc = await Permission.location.request();
    await Permission.nearbyWifiDevices.request();
    if (!loc.isGranted) {
      setState(() => _error = 'Location permission denied');
      return;
    }
    if (!await _wifi.isLocationEnabled()) {
      setState(() =>
          _error = 'Location Services must be ON for WiFi scanning');
      return;
    }
    await _wifi.startScan();
    if (!mounted) return;
    setState(() => _ready = true);
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollWifi());
  }

  Future<void> _pollWifi() async {
    try {
      final list = await _wifi.getResults();
      if (!mounted) return;
      setState(() {
        for (final r in list) _networks[r.bssid] = r;
        _targetBssid ??= _pickDefault(list);
        _liveRssi =
            _targetBssid != null ? _networks[_targetBssid]?.rssi : null;
      });
    } catch (_) {}
  }

  String? _pickDefault(List<WifiReading> list) {
    final visible = list.where((r) => r.ssid.isNotEmpty).toList();
    if (visible.isEmpty) return list.isEmpty ? null : list.first.bssid;
    visible.sort((a, b) => b.rssi.compareTo(a.rssi));
    return visible.first.bssid;
  }

  void _onTapDown(TapDownDetails d, Size size) {
    if (_targetBssid == null) return _snack('Select a network first');
    final rssi = _liveRssi;
    if (rssi == null) return _snack('No signal from selected network');
    setState(() {
      _points.add(ScanPoint(
        nx: (d.localPosition.dx / size.width).clamp(0.0, 1.0),
        ny: (d.localPosition.dy / size.height).clamp(0.0, 1.0),
        rssi: rssi,
        bssid: _targetBssid!,
      ));
      _version++;
    });
  }

  Future<void> _loadFloorplan() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() => _floorplan = bytes);
  }

  void _clear() => setState(() {
        _points.clear();
        _version++;
      });

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(m)));

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _errorScaffold();
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('WiFi Heatmap'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _wifi.startScan(),
          ),
          IconButton(icon: const Icon(Icons.clear), onPressed: _clear),
        ],
      ),
      body: Column(
        children: [
          _header(),
          Expanded(child: _canvas()),
          _footer(),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.black26,
      child: Column(
        children: [
          DropdownButton<String>(
            isExpanded: true,
            value: _targetBssid,
            hint: const Text('Select network'),
            items: _networks.values
                .map((r) => DropdownMenuItem(
                      value: r.bssid,
                      child: Text(
                        '${r.ssid.isEmpty ? "<hidden>" : r.ssid} · '
                        '${r.bssid} · ${r.rssi} dBm',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _targetBssid = v),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Live: ${_liveRssi ?? "—"} dBm',
                  style: const TextStyle(fontSize: 13)),
              Text('Samples: ${_points.length}',
                  style: const TextStyle(fontSize: 13)),
              const Text('tap = sample',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _canvas() {
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        children: [
          if (_floorplan != null)
            Positioned.fill(
              child: Image.memory(_floorplan!, fit: BoxFit.contain),
            ),
          Positioned.fill(
            child: GestureDetector(
              onTapDown: (d) => _onTapDown(d, size),
              child: CustomPaint(
                painter: HeatmapPainter(
                  points: _points,
                  version: _version,
                  canvasSize: size,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _footer() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.image),
              label: const Text('Floorplan'),
              onPressed: _loadFloorplan,
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Clear'),
              onPressed: _clear,
            ),
            if (_floorplan != null) ...[
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Remove'),
                onPressed: () => setState(() => _floorplan = null),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _errorScaffold() {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => _wifi.openLocationSettings(),
                child: const Text('Open Location Settings'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => setState(() {
                  _error = null;
                  _ready = false;
                  _init();
                }),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}