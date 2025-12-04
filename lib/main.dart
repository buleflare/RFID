import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) => MaterialApp(home: RFIDPage());
}

class RFIDPage extends StatefulWidget {
  @override
  _RFIDPageState createState() => _RFIDPageState();
}

class _RFIDPageState extends State<RFIDPage> with WidgetsBindingObserver {
  static const methodCh = MethodChannel('mifare_classic/method');
  static const eventCh = EventChannel('mifare_classic/events');

  StreamSubscription? _nfcSubscription;
  String _uid = '';
  String _hexData = '';
  String _textData = '';
  String _status = 'Ready - tap RFID card';
  bool _isWriting = false;
  bool _isAppActive = true;
  TextEditingController _writeTextController = TextEditingController();
  TextEditingController _writeHexController = TextEditingController();
  bool _fillHexWithZeros = false;

  // For showing writing notification
  OverlayEntry? _writingNotificationOverlay;
  String _writingProgress = '';

  // Performance optimizations
  DateTime? _lastTagEventTime;
  static const Duration _debounceDelay = Duration(milliseconds: 1000);
  bool _isProcessingEvent = false;
  final Duration _nfcReinitDelay = Duration(milliseconds: 1000);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeNFC();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('App lifecycle state changed: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        _isAppActive = true;
        Future.delayed(_nfcReinitDelay, () {
          if (_isAppActive && !_isWriting) {
            _initializeNFC();
          }
        });
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
        _isAppActive = false;
        _stopNFC();
        break;
      default:
        break;
    }
  }

  Future<void> _initializeNFC() async {
    if (_isWriting || !_isAppActive) return;

    try {
      await _stopNFC();

      _nfcSubscription = eventCh.receiveBroadcastStream().listen(
        _handleTagEvent,
        onError: (e) => print('NFC event error: $e'),
        cancelOnError: true,
      );

      await methodCh.invokeMethod('startScan');
      _updateStatus('Ready - tap RFID card');
    } catch (e) {
      _updateStatus('NFC init error: $e');
    }
  }

  Future<void> _stopNFC() async {
    try {
      await _nfcSubscription?.cancel();
      _nfcSubscription = null;
      await methodCh.invokeMethod('stopScan');
    } catch (e) {
      print('Error stopping NFC: $e');
    }
  }

  Future<void> _handleTagEvent(dynamic event) async {
    if (!_isAppActive || _isWriting) return;

    final now = DateTime.now();
    if (_lastTagEventTime != null &&
        now.difference(_lastTagEventTime!) < _debounceDelay) {
      return;
    }
    _lastTagEventTime = now;

    if (_isProcessingEvent) return;
    _isProcessingEvent = true;

    try {
      if (event is Map) {
        final eventMap = Map<String, dynamic>.from(event);

        if (eventMap.containsKey('error')) {
          _updateStatus('Error: ${eventMap['error']}');
          return;
        }

        final uid = eventMap['uid']?.toString() ?? '';
        final blocks = eventMap['blocks'] as List<dynamic>? ?? [];

        await _processTagData(uid, blocks);
      }
    } catch (e) {
      _updateStatus('Error processing tag: $e');
    } finally {
      _isProcessingEvent = false;
    }
  }

  Future<void> _processTagData(String uid, List<dynamic> rawBlocks) async {
    if (uid.isNotEmpty && uid != _uid) {
      setState(() => _uid = uid);
    }

    _updateStatus('Tag detected');

    final processed = await _extractTagData(rawBlocks);

    if (mounted) {
      setState(() {
        _textData = processed['text'] ?? '(No text)';
        _hexData = processed['hex'] ?? '(No hex)';
      });
    }
  }

  Future<Map<String, String>> _extractTagData(List<dynamic> rawBlocks) async {
    final textBuffer = StringBuffer();
    final hexBuffer = StringBuffer();

    final blocksToProcess = rawBlocks.length > 20
        ? rawBlocks.sublist(0, 20)
        : rawBlocks;

    for (var block in blocksToProcess) {
      if (block is Map) {
        final blockMap = Map<String, dynamic>.from(block);

        final text = blockMap['text']?.toString() ?? '';
        final hex = blockMap['hex']?.toString() ?? '';
        final sector = blockMap['sector'] ?? 0;
        final blockNum = blockMap['block'] ?? 0;

        if (sector > 0 && blockNum < 3 && hex.isNotEmpty && hex != 'AUTH ERROR') {
          hexBuffer.write(hex);

          if (text.isNotEmpty) {
            final cleanText = text.replaceAll(RegExp(r'[^\x20-\x7E]'), '');
            if (cleanText.isNotEmpty) {
              textBuffer.write(cleanText);
            }
          }
        }
      }
    }

    return {
      'text': textBuffer.toString().isNotEmpty
          ? textBuffer.toString()
          : '(No printable text)',
      'hex': hexBuffer.toString().isNotEmpty
          ? hexBuffer.toString()
          : '(No hex data)',
    };
  }

  // Show writing notification overlay
  void _showWritingNotification({required bool isHex}) {
    // Remove any existing notification first
    _hideWritingNotification();

    _writingNotificationOverlay = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 10,
        left: 16,
        right: 16,
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.nfc, color: Colors.white, size: 24),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Approach Card to Write',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  'Bring the RFID card close to your phone',
                  style: TextStyle(color: Colors.white70),
                ),
                SizedBox(height: 8),
                if (_writingProgress.isNotEmpty)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(height: 4),
                      Text(
                        _writingProgress,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                SizedBox(height: 8),
                LinearProgressIndicator(
                  backgroundColor: Colors.orange[200],
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_writingNotificationOverlay!);
  }

  // Update writing progress
  void _updateWritingProgress(String progress) {
    if (_writingNotificationOverlay != null) {
      setState(() {
        _writingProgress = progress;
      });
      _writingNotificationOverlay!.markNeedsBuild();
    }
  }

  // Hide writing notification
  void _hideWritingNotification() {
    if (_writingNotificationOverlay != null) {
      _writingNotificationOverlay!.remove();
      _writingNotificationOverlay = null;
    }
    _writingProgress = '';
  }

  Future<void> _writeToCard({required bool isHex}) async {
    if (_isWriting) return;

    _isWriting = true;
    _updateStatus('Preparing write...');

    // Show notification
    _showWritingNotification(isHex: isHex);

    try {
      await _stopNFC();

      String data;
      if (isHex) {
        data = await _prepareHexData();
      } else {
        data = await _prepareTextData();
      }

      if (data.isEmpty) {
        _showSnackBar('No data to write');
        _hideWritingNotification();
        _isWriting = false;
        return;
      }

      _updateStatus('Writing to card...');
      _updateWritingProgress('Starting write...');

      // Add a small delay to show the notification
      await Future.delayed(Duration(milliseconds: 500));

      final result = await methodCh.invokeMethod('writeData', {
        'data': data,
        'isHex': isHex,
      });

      if (result == true) {
        _updateStatus('Write successful!');
        _updateWritingProgress('✓ Write completed!');

        // Delay before hiding notification to show success
        await Future.delayed(Duration(seconds: 1));

        _hideWritingNotification();
        _showSuccessDialog();
      } else {
        _updateStatus('Write failed');
        _updateWritingProgress('✗ Write failed');

        // Delay before hiding notification to show error
        await Future.delayed(Duration(seconds: 1));

        _hideWritingNotification();
        _showSnackBar('Write failed. Please try again.');
      }
    } catch (e) {
      _updateStatus('Write error: $e');
      _updateWritingProgress('✗ Error: $e');

      // Delay before hiding notification to show error
      await Future.delayed(Duration(seconds: 1));

      _hideWritingNotification();
      _showSnackBar('Write error: $e');
    } finally {
      _isWriting = false;
      _clearWriteFields();

      // Restart NFC after a delay
      Future.delayed(Duration(seconds: 2), () {
        if (_isAppActive && !_isWriting) {
          _initializeNFC();
        }
      });
    }
  }

  Future<String> _prepareHexData() async {
    String hex = _writeHexController.text.trim().replaceAll(RegExp(r'\s'), '').toUpperCase();

    if (hex.isNotEmpty && !RegExp(r'^[0-9A-F]+$').hasMatch(hex)) {
      throw 'Invalid hex characters';
    }

    if (hex.isNotEmpty && hex.length % 2 != 0) {
      throw 'Hex must have even number of characters';
    }

    if (hex.isEmpty && _fillHexWithZeros) {
      hex = '00' * 768;
      _updateWritingProgress('Using zeros (00) for all blocks');
    } else if (hex.isNotEmpty) {
      const maxHexChars = 1536;
      if (hex.length >= maxHexChars) {
        hex = hex.substring(0, maxHexChars);
        _updateWritingProgress('Hex truncated to $maxHexChars chars');
      } else {
        final zerosNeeded = maxHexChars - hex.length;
        final evenZerosNeeded = zerosNeeded % 2 == 0 ? zerosNeeded : zerosNeeded - 1;
        hex = hex + ('00' * (evenZerosNeeded ~/ 2));
        _updateWritingProgress('Added ${evenZerosNeeded ~/ 2} zero pairs');
      }
    }

    return hex;
  }

  Future<String> _prepareTextData() async {
    String text = _writeTextController.text.trim();

    if (text.isEmpty) {
      throw 'Please enter text to write';
    }

    const maxLength = 768;
    if (text.length >= maxLength) {
      text = text.substring(0, maxLength);
      _updateWritingProgress('Text truncated to $maxLength chars');
    } else {
      final dotsNeeded = maxLength - text.length;
      text = text + ('.' * dotsNeeded);
      _updateWritingProgress('Added $dotsNeeded tail dots');
    }

    return text;
  }

  void _clearWriteFields() {
    _writeTextController.clear();
    _writeHexController.clear();
    if (mounted) {
      setState(() => _fillHexWithZeros = false);
    }
  }

  void _updateStatus(String status) {
    if (mounted) {
      setState(() => _status = status);
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: 3),
        backgroundColor: message.contains('error') || message.contains('failed')
            ? Colors.red
            : null,
      ),
    );
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 10),
            Text('Success'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 60, color: Colors.green),
            SizedBox(height: 16),
            Text(
              'Data written successfully!',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Card is ready for use.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nfcSubscription?.cancel();
    _writeTextController.dispose();
    _writeHexController.dispose();
    // Ensure notification is removed
    _hideWritingNotification();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('RFID Reader/Writer'),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _isWriting ? null : () {
              _updateStatus('Restarting...');
              _initializeNFC();
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status Card
          _buildStatusCard(),
          SizedBox(height: 20),

          // Data Display
          _buildDataSection(),
          SizedBox(height: 20),

          // Write Section
          _buildWriteSection(),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isWriting ? Icons.edit : Icons.nfc,
                  color: _isWriting ? Colors.orange : Colors.blue,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _status,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: _isWriting ? Colors.orange : Colors.black,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'UID: ${_uid.isEmpty ? '-' : _uid}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isWriting)
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tag Data', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),

        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Text Data', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: BoxConstraints(minHeight: 60, maxHeight: 150),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _textData,
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 10),

        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hex Data', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: BoxConstraints(minHeight: 60, maxHeight: 150),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _hexData,
                      style: TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWriteSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Write to Card', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        SizedBox(height: 10),

        // Text Write
        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Write Text', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                TextField(
                  controller: _writeTextController,
                  decoration: InputDecoration(
                    labelText: 'Enter text',
                    border: OutlineInputBorder(),
                    hintText: 'Text + auto dots to fill 768 chars',
                  ),
                  maxLines: 2,
                  enabled: !_isWriting,
                ),
                SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 45,
                  child: ElevatedButton(
                    onPressed: _isWriting ? null : () => _writeToCard(isHex: false),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                    child: _isWriting
                        ? CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      strokeWidth: 2,
                    )
                        : Text('WRITE TEXT'),
                  ),
                ),
              ],
            ),
          ),
        ),

        SizedBox(height: 10),

        // Hex Write
        Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Write Hex', style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Row(
                  children: [
                    Checkbox(
                      value: _fillHexWithZeros,
                      onChanged: _isWriting ? null : (value) {
                        setState(() => _fillHexWithZeros = value ?? false);
                      },
                    ),
                    Expanded(
                      child: Text('Fill with zeros if empty'),
                    ),
                  ],
                ),
                TextField(
                  controller: _writeHexController,
                  decoration: InputDecoration(
                    labelText: 'Enter hex (no spaces)',
                    border: OutlineInputBorder(),
                    hintText: _fillHexWithZeros ? 'Leave empty for zeros' : 'Enter hex data',
                  ),
                  enabled: !_isWriting,
                ),
                SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 45,
                  child: ElevatedButton(
                    onPressed: _isWriting ? null : () => _writeToCard(isHex: true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                    ),
                    child: _isWriting
                        ? CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      strokeWidth: 2,
                    )
                        : Text('WRITE HEX'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}