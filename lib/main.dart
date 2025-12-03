import 'dart:async';
import 'dart:convert';
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

  StreamSubscription? _sub;
  String uid = '';
  String hexData = '';
  String textData = '';
  String status = '';
  bool isWriting = false;
  bool isReading = true;
  bool showWritePrompt = false;
  bool showSuccessDialog = false;
  String pendingWriteData = '';
  bool pendingWriteIsHex = false;
  bool fillHexWithZeros = false;
  bool addTailDots = true; // NEW: Always add tail dots for text
  TextEditingController _writeText = TextEditingController();
  TextEditingController _writeHex = TextEditingController();
  bool _isAppActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    print('App initialized');
    _initializeNFC();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('App lifecycle state changed: $state');

    switch (state) {
      case AppLifecycleState.resumed:
        _isAppActive = true;
        print('App resumed - reinitializing NFC');
        _reinitializeNFC();
        break;
      case AppLifecycleState.inactive:
        _isAppActive = false;
        print('App inactive');
        break;
      case AppLifecycleState.paused:
        _isAppActive = false;
        print('App paused');
        break;
      case AppLifecycleState.detached:
        _isAppActive = false;
        print('App detached');
        break;
      case AppLifecycleState.hidden:
        _isAppActive = false;
        print('App hidden');
        break;
    }
  }

  void _initializeNFC() async {
    print('Initializing NFC...');

    try {
      await _sub?.cancel();
      _sub = null;

      _sub = eventCh.receiveBroadcastStream().listen(
        _onTagEvent,
        onError: (e) {
          print('Event channel error: $e');
          setState(() => status = "Event error: $e");
        },
        cancelOnError: true,
      );

      print('NFC listener initialized');
      await _startScan();
    } catch (e) {
      print('Error initializing NFC: $e');
      setState(() => status = 'Initialization error: $e');
    }
  }

  void _reinitializeNFC() {
    print('Reinitializing NFC...');

    Future.delayed(Duration(milliseconds: 500), () {
      if (_isAppActive) {
        _initializeNFC();
      }
    });
  }

  void _onTagEvent(dynamic event) {
    print('Received event: $event');

    if (!_isAppActive) {
      print('App not active, ignoring event');
      return;
    }

    setState(() {
      if (event is Map) {
        final eventMap = Map<String, dynamic>.from(event);

        uid = eventMap['uid']?.toString() ?? eventMap['fullUid']?.toString() ?? '';

        if (eventMap.containsKey('error')) {
          status = eventMap['error']?.toString() ?? 'Unknown error';
          hexData = '';
          textData = '';
          isWriting = false;
          showWritePrompt = false;
        } else {
          if (isWriting && pendingWriteData.isNotEmpty) {
            _executeWrite();
          } else {
            status = 'Tag detected';

            final rawBlocks = eventMap['blocks'] as List<dynamic>? ?? [];
            final blocks = _safeConvertBlocks(rawBlocks);

            textData = _extractAllText(blocks);
            hexData = _extractAllHex(blocks);

            print('Extracted ${textData.length} chars of text, ${hexData.length} chars of hex');
          }
        }
      } else {
        status = 'Unknown event';
        hexData = '';
        textData = '';
        isWriting = false;
        showWritePrompt = false;
      }
    });
  }

  List<Map<String, dynamic>> _safeConvertBlocks(List<dynamic> rawBlocks) {
    final List<Map<String, dynamic>> converted = [];

    for (var block in rawBlocks) {
      if (block is Map) {
        try {
          final safeBlock = Map<String, dynamic>.from(block);
          converted.add(safeBlock);
        } catch (e) {
          print('Error converting block: $e');
        }
      }
    }

    return converted;
  }

  String _extractAllText(List<Map<String, dynamic>> blocks) {
    if (blocks.isEmpty) return '(No data)';

    String allText = '';

    for (var block in blocks) {
      final text = block['text']?.toString() ?? '';
      final sector = block['sector'] ?? 0;
      final blockNum = block['block'] ?? 0;

      if (sector > 0 && blockNum < 3) {
        final cleanText = text.replaceAll(RegExp(r'[^\x20-\x7E]'), '');
        if (cleanText.isNotEmpty) {
          allText += cleanText;
        }
      }
    }

    if (allText.isEmpty) {
      for (var block in blocks) {
        final text = block['text']?.toString() ?? '';
        final cleanText = text.replaceAll(RegExp(r'[^\x20-\x7E]'), '');
        if (cleanText.isNotEmpty) {
          allText += cleanText;
        }
      }
    }

    return allText.isNotEmpty ? allText : '(No printable text found)';
  }

  String _extractAllHex(List<Map<String, dynamic>> blocks) {
    if (blocks.isEmpty) return '(No data)';

    String allHex = '';

    for (var block in blocks) {
      final hex = block['hex']?.toString() ?? '';
      final sector = block['sector'] ?? 0;
      final blockNum = block['block'] ?? 0;

      if (sector > 0 && blockNum < 3) {
        if (hex.isNotEmpty && hex != 'AUTH ERROR' && hex != 'READ ERROR') {
          allHex += hex;
        }
      }
    }

    if (allHex.isEmpty) {
      for (var block in blocks) {
        final hex = block['hex']?.toString() ?? '';
        if (hex.isNotEmpty && hex != 'AUTH ERROR' && hex != 'READ ERROR') {
          allHex += hex;
        }
      }
    }

    return allHex.isNotEmpty ? allHex : '(No hex data found)';
  }

  Future _startScan() async {
    try {
      print('Starting scan...');
      await methodCh.invokeMethod('startScan');
      setState(() {
        status = 'Ready - tap tag';
        isReading = true;
        isWriting = false;
      });
      print('Scan started successfully');
    } catch (e) {
      print('startScan error: $e');
      setState(() => status = 'startScan error: $e');
    }
  }

  Future<void> _executeWrite() async {
    try {
      print('Executing write: isHex=$pendingWriteIsHex');
      print('Data length: ${pendingWriteData.length}');
      print('Fill hex with zeros: $fillHexWithZeros');

      final result = await methodCh.invokeMethod('writeData', {
        'data': pendingWriteData,
        'isHex': pendingWriteIsHex,
      });

      if (result == true) {
        if (showWritePrompt) {
          Navigator.of(context).pop();
        }

        _showSuccessDialog();

        setState(() {
          status = 'Write successful!';
          isWriting = false;
          showWritePrompt = false;
          pendingWriteData = '';
          fillHexWithZeros = false; // Reset flag
        });

        _writeText.clear();
        _writeHex.clear();

        Future.delayed(Duration(seconds: 2), () {
          if (mounted && _isAppActive) {
            setState(() {
              isReading = true;
            });
          }
        });
      } else {
        if (showWritePrompt) {
          Navigator.of(context).pop();
        }

        setState(() {
          status = 'Write failed - try again';
          isWriting = false;
          showWritePrompt = false;
          pendingWriteData = '';
          fillHexWithZeros = false; // Reset flag
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Write failed. Please try again.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (showWritePrompt) {
        Navigator.of(context).pop();
      }

      setState(() {
        status = 'Write error: $e';
        isWriting = false;
        showWritePrompt = false;
        pendingWriteData = '';
        fillHexWithZeros = false; // Reset flag
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Write error: $e'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _showSuccessDialog() {
    String message = 'Data has been written successfully!';
    if (pendingWriteIsHex && fillHexWithZeros && _writeHex.text.isEmpty) {
      message = 'Card filled with zeros (0x00) successfully!';
    } else if (!pendingWriteIsHex) {
      message = 'Text with tail dots written successfully!';
    } else if (pendingWriteIsHex && _writeHex.text.isNotEmpty) {
      message = 'Hex with tail zeros written successfully!';
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
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
              Icon(
                Icons.check_circle_outline,
                size: 60,
                color: Colors.green,
              ),
              SizedBox(height: 20),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              if (!pendingWriteIsHex)
                SizedBox(height: 10),
              if (!pendingWriteIsHex)
                Text(
                  'Added ${768 - _writeText.text.length} tail dots',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
              if (pendingWriteIsHex && _writeHex.text.isNotEmpty)
                SizedBox(height: 10),
              if (pendingWriteIsHex && _writeHex.text.isNotEmpty)
                Text(
                  'Added ${1536 - _writeHex.text.replaceAll(RegExp(r'\s'), '').length} tail zeros',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
              if (pendingWriteIsHex && fillHexWithZeros && _writeHex.text.isEmpty)
                Text(
                  'All blocks filled with 0x00 (zeros)',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
              ),
              child: Text('OK'),
            ),
          ],
        );
      },
    );
  }

  Future _initiateWrite({required bool isHex}) async {
    String data = '';

    if (isHex) {
      data = _writeHex.text.trim();

      // If hex field is empty and fillHexWithZeros is checked, use zeros
      if (data.isEmpty && fillHexWithZeros) {
        // Create hex zeros for full card (768 bytes = 1536 hex chars)
        data = '00' * 768; // 768 bytes = 1536 hex characters
        print('Using default zeros (${data.length} hex chars = 768 bytes)');
      }

      // Clean hex (remove spaces) if not empty
      if (data.isNotEmpty) {
        data = data.replaceAll(RegExp(r'\s'), '').toUpperCase();

        // Validate hex format
        if (!RegExp(r'^[0-9A-F]+$').hasMatch(data)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Invalid hex characters. Use only 0-9, A-F.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
          return;
        }

        if (data.length % 2 != 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Hex string must have even number of characters'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
          return;
        }
      }

      final maxHexChars = 1536;
      final hexLength = data.length;
      if (hexLength >= maxHexChars) {
        // Truncate to max length
        data = data.substring(0, maxHexChars);
        print('Hex truncated to $maxHexChars chars');
      } else {
        // Add tail zeros to reach 1536 total
        final zerosNeeded = maxHexChars - hexLength;
        // Ensure zerosNeeded is even (since we add "00" pairs)
        final evenZerosNeeded = zerosNeeded % 2 == 0 ? zerosNeeded : zerosNeeded - 1;
        data = data + ('00' * (evenZerosNeeded ~/ 2));
        print('Added ${evenZerosNeeded ~/ 2} pairs of zeros to make $maxHexChars total');
      }

    } else {
      // For text writing - ALWAYS add tail dots to make 768 total
      data = _writeText.text.trim();

      if (data.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Please enter text to write'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }

      // Calculate tail dots needed
      final textLength = data.length;
      final maxLength = 768;

      if (textLength >= maxLength) {
        // Truncate to max length
        data = data.substring(0, maxLength);
        print('Text truncated to $maxLength chars');
      } else {
        // Add tail dots to reach 768 total
        final dotsNeeded = maxLength - textLength;
        data = data + ('.' * dotsNeeded);
        print('Added $dotsNeeded tail dots to make $maxLength total');
      }
    }

    // Validate data is not empty
    if (data.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Please enter data to write'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    pendingWriteData = data;

    setState(() {
      showWritePrompt = true;
      isWriting = true;
      isReading = false;
      pendingWriteIsHex = isHex;
      status = 'Ready to write - bring card close...';
    });

    _showWritePrompt(isHex: isHex, dataLength: data.length);
  }

  void _showWritePrompt({required bool isHex, required int dataLength}) {
    String dataType = isHex ? 'Hex' : 'Text';
    String dataPreview = pendingWriteData.length > 50
        ? '${pendingWriteData.substring(0, 50)}...'
        : pendingWriteData;

    // Calculate tail dots info for text
    // Calculate tail dots/zeros info
    String tailInfo = '';
    if (!isHex && _writeText.text.isNotEmpty) {
      final textLength = _writeText.text.length;
      final dotsAdded = dataLength - textLength;
      if (dotsAdded > 0) {
        tailInfo = ' + $dotsAdded tail dots';
      }
    } else if (isHex && _writeHex.text.isNotEmpty) {
      final hexLength = _writeHex.text.replaceAll(RegExp(r'\s'), '').length;
      final zerosAdded = dataLength - hexLength;
      if (zerosAdded > 0) {
        tailInfo = ' + $zerosAdded tail zeros';
      }
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.nfc, color: Colors.orange),
              SizedBox(width: 10),
              Text('Ready to Write'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.touch_app,
                size: 60,
                color: Colors.orange,
              ),
              SizedBox(height: 20),
              Text(
                'Bring the RFID card close to your phone',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
              SizedBox(height: 10),
              Text(
                'Writing will start automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              SizedBox(height: 15),
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[300]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Write Details:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Type: $dataType',
                      style: TextStyle(fontSize: 12),
                    ),
                    Text(
                      'Total length: $dataLength chars$tailInfo',
                      style: TextStyle(fontSize: 12),
                    ),
                    if (isHex && fillHexWithZeros && _writeHex.text.isEmpty)
                      Text(
                        'Using: Auto-filled zeros (00)',
                        style: TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.bold),
                      ),
                    if (!isHex && _writeText.text.isNotEmpty)
                      Text(
                        'Input: ${_writeText.text.length} chars',
                        style: TextStyle(fontSize: 12, color: Colors.green),
                      ),
                    SizedBox(height: 5),
                    Text(
                      'Preview:',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    Text(
                      dataPreview,
                      style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  showWritePrompt = false;
                  isWriting = false;
                  isReading = true;
                  pendingWriteData = '';
                  fillHexWithZeros = false;
                  status = 'Cancelled';
                });
              },
              child: Text('CANCEL'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _executeWrite();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
              child: Text('CONTINUE'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    print('Disposing...');
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _writeText.dispose();
    _writeHex.dispose();
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
            onPressed: isWriting ? null : _startScan,
            tooltip: 'Scan',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status and UID
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isWriting ? Colors.orange[50] : Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isWriting ? Colors.orange : Colors.blue,
                  width: isWriting ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isWriting ? Icons.edit : Icons.nfc,
                    color: isWriting ? Colors.orange : Colors.blue,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.isEmpty ? 'Ready - tap RFID card' : status,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: isWriting ? Colors.orange : Colors.black,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'UID: ${uid.isEmpty ? '-' : uid}',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Colors.grey[700],
                          ),
                        ),
                        if (isWriting && pendingWriteData.isNotEmpty) ...[
                          SizedBox(height: 4),
                          Text(
                            'Writing: ${pendingWriteData.length} ${pendingWriteIsHex ? 'hex chars' : 'chars'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.orange,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isWriting)
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                    ),
                ],
              ),
            ),

            SizedBox(height: 24),

            // Text Data Display
            _dataDisplay('TEXT DATA', textData, Colors.green),

            SizedBox(height: 20),

            // Hex Data Display
            _dataDisplay('HEX DATA', hexData, Colors.blue),

            SizedBox(height: 30),

            Divider(),

            // Write Section
            Text(
              'Write Data to Card',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Colors.purple,
              ),
            ),
            SizedBox(height: 16),

            // Write Text (ALWAYS adds tail dots)
            Card(
              elevation: 2,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Write as Text',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green[50],
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.green),
                          ),
                          child: Text(
                            'Writes to ALL blocks',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.green,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Will write to all writable blocks (max 768 chars total)',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),

                    SizedBox(height: 10),
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.yellow[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.yellow),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info, color: Colors.orange, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Automatically adds tail dots to fill 768 characters',
                              style: TextStyle(fontSize: 12, color: Colors.orange[800]),
                            ),
                          ),
                        ],
                      ),
                    ),

                    SizedBox(height: 10),
                    TextField(
                      controller: _writeText,
                      decoration: InputDecoration(
                        labelText: 'Enter text to write',
                        border: OutlineInputBorder(),
                        hintText: 'Your text + auto dots to fill card',
                        suffixIcon: IconButton(
                          icon: Icon(Icons.clear),
                          onPressed: () {
                            _writeText.clear();
                            setState(() {});
                          },
                        ),
                      ),
                      maxLines: 3,
                      enabled: !isWriting,
                      onChanged: (value) {
                        // Show character count
                        setState(() {});
                      },
                    ),
                    SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Input: ${_writeText.text.length} chars',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.green,
                              ),
                            ),
                            if (_writeText.text.isNotEmpty)
                              Text(
                                'Tail dots: ${768 - min(_writeText.text.length, 768)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.blue,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          'Total: ${min(_writeText.text.length, 768)}/${min(_writeText.text.length + max(0, 768 - _writeText.text.length), 768)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: _writeText.text.length > 768 ? Colors.red : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: isWriting ? null : () => _initiateWrite(isHex: false),
                      style: ElevatedButton.styleFrom(
                        minimumSize: Size(double.infinity, 50),
                        backgroundColor: isWriting ? Colors.grey : Colors.green,
                      ),
                      child: isWriting
                          ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                          SizedBox(width: 10),
                          Text('WAITING...'),
                        ],
                      )
                          : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit),
                          SizedBox(width: 8),
                          Text('WRITE TEXT + TAIL DOTS'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            SizedBox(height: 20),

            // Write Hex with "Fill with zeros if empty" option
            Card(
              elevation: 2,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Write as Hex',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.blue[50],
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.blue),
                          ),
                          child: Text(
                            'Writes to ALL blocks',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Will write to all writable blocks (max 1536 hex chars = 768 bytes)',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),

                    // Fill hex with zeros checkbox
                    SizedBox(height: 10),
                    Row(
                      children: [
                        Checkbox(
                          value: fillHexWithZeros,
                          onChanged: isWriting ? null : (value) {
                            setState(() {
                              fillHexWithZeros = value ?? false;
                            });
                          },
                          activeColor: Colors.blue,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Fill with zeros (00) if empty',
                                style: TextStyle(fontWeight: FontWeight.w500),
                              ),
                              Text(
                                'If hex field is empty, fills card with 0x00',
                                style: TextStyle(fontSize: 11, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Input: ${_writeHex.text.replaceAll(RegExp(r'\s'), '').length} hex chars',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blue,
                              ),
                            ),
                            if (_writeHex.text.isNotEmpty)
                              Text(
                                'Tail zeros: ${1536 - min(_writeHex.text.replaceAll(RegExp(r'\s'), '').length, 1536)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.purple,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          'Total: ${min(_writeHex.text.replaceAll(RegExp(r'\s'), '').length, 1536)}/${min(_writeHex.text.replaceAll(RegExp(r'\s'), '').length + max(0, 1536 - _writeHex.text.replaceAll(RegExp(r'\s'), '').length), 1536)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: _writeHex.text.replaceAll(RegExp(r'\s'), '').length > 1536 ? Colors.red : Colors.grey,
                          ),
                        ),
                      ],
                    ),
// Add this Container after the checkbox Row in hex section
                    Container(
                      padding: EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue[50],
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info, color: Colors.blue, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Automatically adds tail zeros (00) to fill 1536 hex chars',
                              style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 10),
                    SizedBox(height: 10),
                    TextField(
                      controller: _writeHex,
                      decoration: InputDecoration(
                        labelText: 'Enter hex data (no spaces)',
                        border: OutlineInputBorder(),
                        hintText: fillHexWithZeros ? 'Leave empty for zeros (00)' : 'Type hex or leave empty and check above',
                        suffixIcon: IconButton(
                          icon: Icon(Icons.clear),
                          onPressed: () => _writeHex.clear(),
                        ),
                      ),
                      enabled: !isWriting,
                      onChanged: (value) {
                        // If user starts typing and checkbox is checked, uncheck it
                        if (fillHexWithZeros && value.isNotEmpty) {
                          setState(() {
                            fillHexWithZeros = false;
                          });
                        }
                        setState(() {});
                      },
                    ),
                    SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Hex characters: ${_writeHex.text.replaceAll(RegExp(r'\s'), '').length}/1536',
                          style: TextStyle(
                            fontSize: 12,
                            color: _writeHex.text.replaceAll(RegExp(r'\s'), '').length > 1536 ? Colors.red : Colors.grey,
                          ),
                        ),
                        if (_writeHex.text.replaceAll(RegExp(r'\s'), '').length > 1536)
                          Text(
                            'Will be truncated',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.red,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: isWriting ? null : () => _initiateWrite(isHex: true),
                      style: ElevatedButton.styleFrom(
                        minimumSize: Size(double.infinity, 50),
                        backgroundColor: isWriting ? Colors.grey : Colors.blue,
                      ),
                      child: isWriting
                          ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                          SizedBox(width: 10),
                          Text('WAITING...'),
                        ],
                      )
                          : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.code),
                          SizedBox(width: 8),
                          Text(fillHexWithZeros && _writeHex.text.isEmpty
                              ? 'WRITE ZEROS (ALL BLOCKS)'
                              : 'WRITE HEX + TAIL ZEROS'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            SizedBox(height: 20),

            // Info Section
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '📝 Write Summary:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text('• Text writing: Your text + tail dots = 768 total chars'),
                  Text('• Hex writing: Your hex + tail zeros = 1536 total hex chars'),
                  Text('• Example hex: "2E2E" (2 bytes) + 1532 zeros = 1536 total'),
                  Text('• Hex field empty + "Fill with zeros" = writes full card zeros'),
                  SizedBox(height: 8),
                  Text(
                    'Card Capacity:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  Text('• Always 768 total characters for text'),
                  Text('• 1536 hex characters max (768 bytes)'),
                  Text('• Tail dots ensure full card utilization'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dataDisplay(String title, String data, Color color) {
    return Card(
      elevation: 2,
      color: color.withOpacity(0.1),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: color,
                  ),
                ),
                SizedBox(width: 10),
                Text(
                  '(${data.length} chars)',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withOpacity(0.3)),
              ),
              constraints: BoxConstraints(minHeight: 100, maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText(
                  data,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}