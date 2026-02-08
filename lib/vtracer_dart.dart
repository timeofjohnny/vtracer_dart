/// Pure Dart port of vtracer — raster image to SVG vectorizer.
///
/// Uses connected-component color clustering, hierarchical merge,
/// boundary tracing, path simplification, and cubic Bézier fitting
/// to produce clean, layered SVG output.
///
/// ## Usage
///
/// ```dart
/// import 'package:vtracer_dart/vtracer_dart.dart';
///
/// // RGBA pixel data as Uint8List
/// final svg = vtrace(rgbaPixels, width, height);
///
/// // With custom config
/// final svg2 = vtrace(rgbaPixels, width, height,
///   config: VTracerConfig(
///     colorPrecision: 8,
///     filterSpeckle: 4,
///     layerDifference: 16,
///   ),
/// );
/// ```
library;

export 'src/vtracer.dart' show vtrace, VTracerConfig;
