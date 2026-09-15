import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrCodeScanner extends StatefulWidget {
  const QrCodeScanner({super.key});

  @override
  State<QrCodeScanner> createState() => QrCodeScannerState();
}

class QrCodeScannerState extends State<QrCodeScanner> {
  final MobileScannerController cameraController = MobileScannerController();
  bool successfulScan = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('扫码输入', style: TextStyle(fontSize: 16)),
      content: successfulScan
          ? SizedBox(
              width: MediaQuery.of(context).size.width >
                      MediaQuery.of(context).size.height
                  ? MediaQuery.of(context).size.height * 0.8
                  : MediaQuery.of(context).size.width * 0.8,
              height: MediaQuery.of(context).size.width >
                      MediaQuery.of(context).size.height
                  ? MediaQuery.of(context).size.height * 0.8
                  : MediaQuery.of(context).size.width * 0.8,
              child: const Icon(Icons.check),
            )
          : SizedBox(
              width: MediaQuery.of(context).size.width >
                      MediaQuery.of(context).size.height
                  ? MediaQuery.of(context).size.height * 0.8
                  : MediaQuery.of(context).size.width * 0.8,
              height: MediaQuery.of(context).size.width >
                      MediaQuery.of(context).size.height
                  ? MediaQuery.of(context).size.height * 0.8
                  : MediaQuery.of(context).size.width * 0.8,
              child: MobileScanner(
                controller: cameraController,
                onDetect: (capture) async {
                  final List<Barcode> barcodes = capture.barcodes;
                  for (final Barcode barcode in barcodes) {
                    if (barcode.format == BarcodeFormat.qrCode &&
                        barcode.rawValue != null) {
                      setState(() {
                        successfulScan = true;
                      });
                      if (context.mounted) {
                        Navigator.pop(context, barcode.rawValue);
                      }
                      return;
                    }
                  }
                },
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
