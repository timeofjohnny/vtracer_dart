# vtracer_dart

Pure Dart port of [vtracer](https://github.com/visioncortex/vtracer) — convert raster images (PNG, JPEG, etc.) to SVG vector graphics.

No native dependencies, works in Flutter, Dart CLI, and web. Takes RGBA pixel data and produces clean, layered SVG with smooth Bezier curves. Supports transparency, configurable color precision, and multiple output modes.

## Usage

```dart
import 'package:vtracer_dart/vtracer_dart.dart';

// RGBA pixel data as Uint8List (width * height * 4 bytes)
final svg = vtrace(rgbaPixels, width, height);

// Coarse preset — fewer shapes, smaller SVG
final svg2 = vtrace(rgbaPixels, width, height,
  config: const VTracerConfig.coarse(),
);

// Custom config
final svg3 = vtrace(rgbaPixels, width, height,
  config: const VTracerConfig(
    colorPrecision: 8,
    filterSpeckle: 10,
    layerDifference: 32,
  ),
);
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `colorPrecision` | 6 | Color quantization: 1-8, higher = more colors |
| `filterSpeckle` | 4 | Discard clusters smaller than n² pixels |
| `layerDifference` | 16 | Min color diff to keep a cluster as separate layer |
| `cornerThreshold` | 60 | Corner detection threshold in degrees |
| `lengthThreshold` | 4.0 | Min segment length for curve subdivision |
| `spliceThreshold` | 45 | Angle threshold for Bezier splice points |
| `maxIterations` | 10 | Max smoothing iterations |
| `mode` | spline | `spline` (curves) or `polygon` (straight lines) |
| `colorMode` | color | `color` or `binary` (black & white) |
| `hierarchical` | stacked | `stacked` (layers overlap) or `cutout` (no overlap) |

## Acknowledgments

Based on [vtracer](https://github.com/visioncortex/vtracer) by [visioncortex](https://github.com/visioncortex), licensed under Apache-2.0 / MIT.
