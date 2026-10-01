import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(
    home: Scaffold(
      backgroundColor: Color(0xff16191d),
      body: Center(
        child: Text('Engine 包测试（非 Kirakara App）',
            style: TextStyle(color: Colors.white, fontSize: 24)),
      ),
    ),
  ));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // A frame callback is stronger than a process-alive check, but still does
    // not prove visual correctness, Stage isolation or Kirakara App behavior.
    print('KIRAKARA_ENGINE_PACKAGE_FIRST_DART_FRAME');
  });
}
