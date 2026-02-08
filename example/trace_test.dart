import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:vtracer_dart/vtracer_dart.dart';

Uint8List _imageToRgba(img.Image image) {
  final rgba = Uint8List(image.width * image.height * 4);
  var i = 0;
  for (final pixel in image) {
    rgba[i++] = pixel.r.toInt();
    rgba[i++] = pixel.g.toInt();
    rgba[i++] = pixel.b.toInt();
    rgba[i++] = pixel.a.toInt();
  }
  return rgba;
}

void main(List<String> args) {
  final inputFile = args.isNotEmpty ? args[0] : 'iMac 24" - Silver.png';

  final imagePath = Platform.script
      .resolve('../../../$inputFile')
      .toFilePath();
  final outputDir = Platform.script.resolve('..').toFilePath();

  print('Loading image: $imagePath');
  final stopwatch = Stopwatch()..start();

  final bytes = File(imagePath).readAsBytesSync();
  final decoded = img.decodePng(bytes)!;
  print('Image decoded: ${decoded.width}x${decoded.height} (${stopwatch.elapsedMilliseconds}ms)');

  // Downscale 2x only for large images
  final img.Image working;
  if (decoded.width * decoded.height > 4000000) {
    working = img.copyResize(
      decoded,
      width: decoded.width ~/ 2,
      height: decoded.height ~/ 2,
      interpolation: img.Interpolation.average,
    );
    print('Downscaled 2x: ${working.width}x${working.height}');
  } else {
    working = decoded;
    print('Using original: ${working.width}x${working.height}');
  }

  final pixels = _imageToRgba(working);
  final w = working.width;
  final h = working.height;

  final baseName = inputFile.replaceAll(RegExp(r'\.[^.]+$'), '');

  final configs = <String, VTracerConfig>{
    'default': const VTracerConfig(),
    'coarse': const VTracerConfig.coarse(),
    'binary': const VTracerConfig.coarse(colorMode: 'binary'),
    'cutout': const VTracerConfig.coarse(hierarchical: 'cutout'),
  };

  for (final entry in configs.entries) {
    stopwatch.reset();
    print('\n--- ${entry.key} ---');
    final svg = vtrace(Uint8List.fromList(pixels), w, h, config: entry.value);
    final elapsed = stopwatch.elapsedMilliseconds;

    final outFile = File('$outputDir/${baseName}_${entry.key}.svg');
    outFile.writeAsStringSync(svg);

    final sizeKb = (svg.length / 1024).toStringAsFixed(1);
    print('[${entry.key}] TOTAL: ${elapsed}ms, ${sizeKb}KB');
  }

  print('\nDone!');
}
