import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

// ============================================================================
//  VTracer — Dart port of visioncortex/vtracer image vectorization
//  Original: https://github.com/visioncortex/vtracer (Apache-2.0 / MIT)
// ============================================================================

/// Configuration for VTracer.
class VTracerConfig {
  /// Discard clusters smaller than filterSpeckle² pixels. Default 4.
  final int filterSpeckle;

  /// Color precision: 1-8, higher = more colors. Default 6.
  final int colorPrecision;

  /// Minimum color difference (Manhattan RGB) to keep a cluster as separate layer.
  /// Default 16.
  final int layerDifference;

  /// Corner detection threshold in degrees. Default 60.
  final int cornerThreshold;

  /// Minimum segment length for subdivision. Default 4.0.
  final double lengthThreshold;

  /// Angle displacement threshold (degrees) for Bezier splice points. Default 45.
  final int spliceThreshold;

  /// Maximum smoothing iterations. Default 10.
  final int maxIterations;

  /// Decimal places for SVG coordinates. Default 2.
  final int pathPrecision;

  /// Path simplification mode: 'polygon' or 'spline'. Default 'spline'.
  final String mode;

  /// Color mode: 'color' (full color) or 'binary' (black & white). Default 'color'.
  final String colorMode;

  /// Hierarchical mode: 'stacked' (layers overlap) or 'cutout' (no overlap). Default 'stacked'.
  final String hierarchical;

  const VTracerConfig({
    this.filterSpeckle = 4,
    this.colorPrecision = 6,
    this.layerDifference = 16,
    this.cornerThreshold = 60,
    this.lengthThreshold = 4.0,
    this.spliceThreshold = 45,
    this.maxIterations = 10,
    this.pathPrecision = 2,
    this.mode = 'spline',
    this.colorMode = 'color',
    this.hierarchical = 'stacked',
  });

  /// Fewer shapes, cleaner contours, smaller SVG.
  const VTracerConfig.coarse({
    this.colorMode = 'color',
    this.hierarchical = 'stacked',
  })  : filterSpeckle = 10,
        colorPrecision = 4,
        layerDifference = 32,
        cornerThreshold = 60,
        lengthThreshold = 4.0,
        spliceThreshold = 45,
        maxIterations = 10,
        pathPrecision = 2,
        mode = 'spline';
}

/// Convert RGBA image data to SVG string using VTracer algorithm.
String vtrace(Uint8List pixels, int width, int height, {VTracerConfig? config}) {
  config ??= const VTracerConfig();
  final shift = 8 - config.colorPrecision.clamp(1, 8);
  final filterArea = config.filterSpeckle * config.filterSpeckle;
  final cornerThresholdRad = config.cornerThreshold * pi / 180.0;
  final spliceThresholdRad = config.spliceThreshold * pi / 180.0;
  final diagonal = config.layerDifference == 0;

  // --- Stage 1: Transparency keying ---
  final hasTransparency = _shouldKeyImage(pixels, width, height);
  _Color keyColor = const _Color(0, 0, 0, 0);
  if (hasTransparency) {
    keyColor = _findUnusedColor(pixels, width, height);
    _applyKeyColor(pixels, width, height, keyColor);
  }

  // --- Stage 1b: Binary mode — convert to black & white ---
  if (config.colorMode == 'binary') {
    for (var i = 0; i < pixels.length; i += 4) {
      final lum = (pixels[i] * 299 + pixels[i + 1] * 587 + pixels[i + 2] * 114) ~/ 1000;
      final v = lum < 128 ? 0 : 255;
      pixels[i] = v;
      pixels[i + 1] = v;
      pixels[i + 2] = v;
    }
  }

  // --- Stage 2: Connected component clustering ---
  final cr = _buildClusters(
    pixels, width, height,
    shift: shift,
    diagonal: diagonal,
    keyColor: hasTransparency ? keyColor : null,
  );

  // --- Stage 3: Build adjacency map ---
  final adjacency = _buildAdjacency(cr.clusterIndices, width, height, cr.uf);

  // --- Stage 4: Hierarchical merge ---
  final outputIndices = _hierarchicalMerge(
    cr, adjacency,
    filterArea: filterArea,
    deepenDiff: config.layerDifference,
    maxArea: width * height,
    hasKeyColor: hasTransparency,
  );

  // --- Stage 5: Collect pixels per output cluster ---
  final isCutout = config.hierarchical == 'cutout';
  final outputSet = <int>{};
  for (final idx in outputIndices) {
    outputSet.add(idx);
  }

  final clusterPixels = <int, List<int>>{};
  for (final idx in outputSet) {
    clusterPixels[idx] = [];
  }

  // Map each pixel to its topmost output cluster (first in merge chain).
  final mergedInto = cr.mergedInto;
  // For cutout mode: track which pixel belongs to which topmost cluster.
  final pixelOwner = isCutout ? Int32List(width * height) : null;
  for (var i = 0; i < width * height; i++) {
    var raw = cr.clusterIndices[i];
    if (raw == 0) continue;
    var hops = 0;
    while (!outputSet.contains(raw) && hops < 10000) {
      final next = mergedInto[raw];
      if (next == raw) break;
      raw = next;
      hops++;
    }
    if (pixelOwner != null) pixelOwner[i] = raw;
    final list = clusterPixels[raw];
    if (list != null) {
      list.add(i);
    }
  }

  // In stacked mode, every cluster gets ALL its merged pixels (layers overlap).
  // In cutout mode, lower clusters lose pixels claimed by higher clusters.
  if (isCutout) {
    // outputIndices is ordered bottom→top; reversed = top→bottom.
    // Top clusters keep their pixels; lower clusters have them removed.
    final claimed = Uint8List(width * height);
    for (final idx in outputIndices.reversed) {
      final pixelList = clusterPixels[idx];
      if (pixelList == null) continue;
      final kept = <int>[];
      for (final i in pixelList) {
        if (claimed[i] == 0) {
          kept.add(i);
          claimed[i] = 1;
        }
      }
      clusterPixels[idx] = kept;
    }
  }

  // --- Stage 6: Path extraction + simplification + curve fitting ---
  final svgPaths = <_SvgPath>[];
  final savedMeta = cr.savedMeta;
  for (final idx in outputIndices.reversed) {
    final meta = savedMeta[idx];
    if (meta == null) continue;
    final pixelList = clusterPixels[idx];
    if (pixelList == null || pixelList.isEmpty) continue;

    final compoundPath = _clusterToCompoundPath(
      meta.rect, pixelList, width,
      mode: config.mode,
      cornerThreshold: cornerThresholdRad,
      lengthThreshold: config.lengthThreshold,
      maxIterations: config.maxIterations,
      spliceThreshold: spliceThresholdRad,
    );
    if (compoundPath.isNotEmpty) {
      svgPaths.add(_SvgPath(compoundPath, meta.color, config.pathPrecision));
    }
  }

  // --- Stage 7: SVG assembly ---
  return _buildSvg(svgPaths, width, height);
}

// ============================================================================
//  Color types
// ============================================================================

class _Color {
  final int r, g, b, a;
  const _Color(this.r, this.g, this.b, this.a);

  @override
  bool operator ==(Object other) =>
      other is _Color && r == other.r && g == other.g && b == other.b && a == other.a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  String toHex() {
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    return '#${h(r)}${h(g)}${h(b)}';
  }
}

class _ColorSum {
  int r = 0, g = 0, b = 0, count = 0;

  void add(_Color c) {
    r += c.r;
    g += c.g;
    b += c.b;
    count++;
  }

  void merge(_ColorSum other) {
    r += other.r;
    g += other.g;
    b += other.b;
    count += other.count;
  }

  _Color average() {
    if (count == 0) return const _Color(0, 0, 0, 255);
    return _Color(r ~/ count, g ~/ count, b ~/ count, 255);
  }
}

// ============================================================================
//  Bounding rect
// ============================================================================

class _Rect {
  int left, top, right, bottom;
  _Rect() : left = 1 << 30, top = 1 << 30, right = 0, bottom = 0;

  void addXY(int x, int y) {
    if (x < left) left = x;
    if (y < top) top = y;
    if (x + 1 > right) right = x + 1;
    if (y + 1 > bottom) bottom = y + 1;
  }

  void merge(_Rect other) {
    if (other.isEmpty) return;
    if (other.left < left) left = other.left;
    if (other.top < top) top = other.top;
    if (other.right > right) right = other.right;
    if (other.bottom > bottom) bottom = other.bottom;
  }

  int get width => right > left ? right - left : 0;
  int get height => bottom > top ? bottom - top : 0;
  bool get isEmpty => left >= right || top >= bottom;
}

// ============================================================================
//  Union-Find
// ============================================================================

class _UF {
  final Int32List _parent;
  final Int32List _rank;

  _UF(int n)
      : _parent = Int32List(n),
        _rank = Int32List(n) {
    for (var i = 0; i < n; i++) {
      _parent[i] = i;
    }
  }

  int find(int x) {
    while (_parent[x] != x) {
      _parent[x] = _parent[_parent[x]]; // path halving
      x = _parent[x];
    }
    return x;
  }

  /// Union a into b (b becomes canonical). Returns canonical.
  int union(int a, int b) {
    a = find(a);
    b = find(b);
    if (a == b) return a;
    // Always make b the root
    _parent[a] = b;
    if (_rank[a] == _rank[b]) _rank[b]++;
    return b;
  }
}


// ============================================================================
//  Cluster
// ============================================================================

class _Cluster {
  int area = 0;
  final _ColorSum sum = _ColorSum();
  final _ColorSum residueSum = _ColorSum();
  final _Rect rect = _Rect();

  _Color get color => sum.average();
  _Color get residueColor => residueSum.average();

  void addPixel(_Color c, int x, int y) {
    area++;
    sum.add(c);
    rect.addXY(x, y);
  }

  void mergeFrom(_Cluster other) {
    area += other.area;
    sum.merge(other.sum);
    rect.merge(other.rect);
    other.area = 0;
  }
}

// ============================================================================
//  Saved cluster metadata (snapshot at output time)
// ============================================================================

class _ClusterMeta {
  final _Color color;
  final _Rect rect;
  _ClusterMeta(this.color, this.rect);
}

// ============================================================================
//  Cluster builder result
// ============================================================================

class _ClusterResult {
  final int width, height;
  final Uint8List pixels;
  final List<_Cluster> clusters;
  final Int32List clusterIndices;
  final _UF uf;

  /// mergedInto[i] = i means no merge; mergedInto[i] = j means cluster i was merged into j.
  late final List<int> mergedInto;

  /// Metadata saved at the time a cluster is output (before merge destroys it).
  final Map<int, _ClusterMeta> savedMeta = {};

  _ClusterResult({
    required this.width,
    required this.height,
    required this.pixels,
    required this.clusters,
    required this.clusterIndices,
    required this.uf,
  });
}

// ============================================================================
//  Transparency keying
// ============================================================================

bool _shouldKeyImage(Uint8List pixels, int w, int h) {
  if (w == 0 || h == 0) return false;
  final threshold = (w * 2 * 0.2).toInt();
  var transparent = 0;
  for (final y in [0, h ~/ 4, h ~/ 2, 3 * h ~/ 4, h - 1]) {
    for (var x = 0; x < w; x++) {
      if (pixels[(y * w + x) * 4 + 3] == 0) {
        transparent++;
        if (transparent >= threshold) return true;
      }
    }
  }
  return false;
}

_Color _findUnusedColor(Uint8List pixels, int w, int h) {
  final candidates = [
    const _Color(255, 0, 0, 255),
    const _Color(0, 255, 0, 255),
    const _Color(0, 0, 255, 255),
    const _Color(255, 255, 0, 255),
    const _Color(0, 255, 255, 255),
    const _Color(255, 0, 255, 255),
  ];
  final rng = Random(42);
  for (var i = 0; i < 6; i++) {
    candidates.add(_Color(rng.nextInt(256), rng.nextInt(256), rng.nextInt(256), 255));
  }
  for (final c in candidates) {
    var found = false;
    for (var i = 0; i < w * h; i++) {
      final idx = i * 4;
      if (pixels[idx] == c.r && pixels[idx + 1] == c.g && pixels[idx + 2] == c.b) {
        found = true;
        break;
      }
    }
    if (!found) return c;
  }
  return const _Color(1, 2, 3, 255);
}

void _applyKeyColor(Uint8List pixels, int w, int h, _Color key) {
  for (var i = 0; i < w * h; i++) {
    final idx = i * 4;
    if (pixels[idx + 3] == 0) {
      pixels[idx] = key.r;
      pixels[idx + 1] = key.g;
      pixels[idx + 2] = key.b;
      pixels[idx + 3] = 255;
    }
  }
}

// ============================================================================
//  Stage 1: Connected component clustering
// ============================================================================

_ClusterResult _buildClusters(
  Uint8List pixels, int w, int h, {
  required int shift,
  required bool diagonal,
  _Color? keyColor,
}) {
  // Each pixel gets assigned a cluster index (1-based, 0 = keyed/unassigned)
  final clusterIndices = Int32List(w * h);
  final clusters = <_Cluster>[_Cluster()]; // index 0 reserved (dummy)
  final uf = _UF(w * h); // pixel-level union-find
  var nextCluster = 1;

  bool isSame(int i1, int i2) {
    final a = i1 * 4, b = i2 * 4;
    return (pixels[a] >> shift) == (pixels[b] >> shift) &&
        (pixels[a + 1] >> shift) == (pixels[b + 1] >> shift) &&
        (pixels[a + 2] >> shift) == (pixels[b + 2] >> shift);
  }

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final idx4 = i * 4;

      // Skip keyed pixels
      if (keyColor != null &&
          pixels[idx4] == keyColor.r &&
          pixels[idx4 + 1] == keyColor.g &&
          pixels[idx4 + 2] == keyColor.b) {
        continue;
      }

      final hasUp = y > 0;
      final hasLeft = x > 0;
      final hasUpLeft = x > 0 && y > 0;
      final iUp = hasUp ? (y - 1) * w + x : -1;
      final iLeft = hasLeft ? y * w + (x - 1) : -1;
      final iUpLeft = hasUpLeft ? (y - 1) * w + (x - 1) : -1;

      final matchUp = hasUp && clusterIndices[iUp] != 0 && isSame(i, iUp);
      final matchLeft = hasLeft && clusterIndices[iLeft] != 0 && isSame(i, iLeft);
      final matchUpLeft = hasUpLeft && clusterIndices[iUpLeft] != 0 && isSame(i, iUpLeft);

      final c = _Color(pixels[idx4], pixels[idx4 + 1], pixels[idx4 + 2], pixels[idx4 + 3]);
      int clusterIdx;

      if (matchUp && matchLeft) {
        // Both match — join to up's cluster, and merge left's cluster into up's if different
        final rootUp = uf.find(iUp);
        final rootLeft = uf.find(iLeft);
        clusterIdx = clusterIndices[rootUp];
        if (rootUp != rootLeft) {
          final cLeft = clusterIndices[rootLeft];
          if (cLeft != clusterIdx) {
            // Merge smaller into larger
            if (clusters[cLeft].area <= clusters[clusterIdx].area) {
              clusters[clusterIdx].mergeFrom(clusters[cLeft]);
              clusterIndices[uf.union(rootLeft, rootUp)] = clusterIdx;
            } else {
              clusters[cLeft].mergeFrom(clusters[clusterIdx]);
              clusterIndices[uf.union(rootUp, rootLeft)] = cLeft;
              clusterIdx = cLeft;
            }
          } else {
            uf.union(rootLeft, rootUp);
          }
        }
        uf.union(i, rootUp);
      } else if (matchUp && matchUpLeft) {
        final root = uf.find(iUp);
        clusterIdx = clusterIndices[root];
        uf.union(i, root);
      } else if (matchLeft && matchUpLeft) {
        final root = uf.find(iLeft);
        clusterIdx = clusterIndices[root];
        uf.union(i, root);
      } else if (diagonal && matchUpLeft) {
        final root = uf.find(iUpLeft);
        clusterIdx = clusterIndices[root];
        uf.union(i, root);
      } else if (matchUp) {
        final root = uf.find(iUp);
        clusterIdx = clusterIndices[root];
        uf.union(i, root);
      } else if (matchLeft) {
        final root = uf.find(iLeft);
        clusterIdx = clusterIndices[root];
        uf.union(i, root);
      } else {
        // New cluster
        final newCluster = _Cluster();
        clusters.add(newCluster);
        clusterIdx = nextCluster++;
      }

      clusterIndices[i] = clusterIdx;
      clusters[clusterIdx].addPixel(c, x, y);
    }
  }

  // Normalize: resolve UF and fix clusterIndices to canonical cluster index
  // First, build a mapping from pixel-UF-root → cluster index
  for (var i = 0; i < w * h; i++) {
    if (clusterIndices[i] == 0) continue;
    final root = uf.find(i);
    clusterIndices[i] = clusterIndices[root];
  }

  // Copy sum to residueSum
  for (final c in clusters) {
    c.residueSum.r = c.sum.r;
    c.residueSum.g = c.sum.g;
    c.residueSum.b = c.sum.b;
    c.residueSum.count = c.sum.count;
  }

  final result = _ClusterResult(
    width: w, height: h, pixels: pixels,
    clusters: clusters, clusterIndices: clusterIndices,
    uf: uf,
  );
  // Initialize mergedInto: each cluster points to itself (no merge yet)
  result.mergedInto = List.generate(clusters.length, (i) => i);
  return result;
}

// ============================================================================
//  Adjacency map
// ============================================================================

Map<int, Set<int>> _buildAdjacency(Int32List clusterIndices, int w, int h, _UF uf) {
  final adj = <int, Set<int>>{};

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final ci = clusterIndices[i];
      if (ci == 0) continue;

      // Check right and down neighbors
      if (x < w - 1) {
        final cn = clusterIndices[i + 1];
        if (cn != 0 && cn != ci) {
          (adj[ci] ??= {}).add(cn);
          (adj[cn] ??= {}).add(ci);
        }
      }
      if (y < h - 1) {
        final cn = clusterIndices[i + w];
        if (cn != 0 && cn != ci) {
          (adj[ci] ??= {}).add(cn);
          (adj[cn] ??= {}).add(ci);
        }
      }
    }
  }

  return adj;
}

// ============================================================================
//  Stage 2: Hierarchical merge
// ============================================================================

int _colorDiff(_Color a, _Color b) {
  return (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();
}

List<int> _hierarchicalMerge(
  _ClusterResult cr,
  Map<int, Set<int>> adjacency, {
  required int filterArea,
  required int deepenDiff,
  required int maxArea,
  required bool hasKeyColor,
}) {
  final clusters = cr.clusters;
  final mergedInto = cr.mergedInto;
  final savedMeta = cr.savedMeta;
  final output = <int>[];

  // Build bucket map: area → set of cluster indices
  final areaBuckets = <int, Set<int>>{};
  for (var i = 1; i < clusters.length; i++) {
    final a = clusters[i].area;
    if (a > 0) {
      (areaBuckets[a] ??= {}).add(i);
    }
  }

  final pendingAreas = SplayTreeSet<int>()..addAll(areaBuckets.keys);

  void saveMeta(int idx) {
    final c = clusters[idx];
    // Copy rect so merge doesn't mutate it
    final r = _Rect()
      ..left = c.rect.left
      ..top = c.rect.top
      ..right = c.rect.right
      ..bottom = c.rect.bottom;
    savedMeta[idx] = _ClusterMeta(c.residueColor, r);
  }

  void mergeCluster(int from, int to) {
    final oldArea = clusters[to].area;
    areaBuckets[oldArea]?.remove(to);

    clusters[to].mergeFrom(clusters[from]);
    mergedInto[from] = to;

    final newArea = clusters[to].area;
    (areaBuckets[newArea] ??= {}).add(to);
    pendingAreas.add(newArea);

    // Update adjacency
    final fromNeighbors = adjacency.remove(from);
    if (fromNeighbors != null) {
      final toNeighbors = adjacency[to] ??= {};
      for (final n in fromNeighbors) {
        if (n == to) continue;
        final nSet = adjacency[n];
        if (nSet != null) {
          nSet.remove(from);
          nSet.add(to);
        }
        toNeighbors.add(n);
      }
      toNeighbors.remove(from);
      toNeighbors.remove(to);
    }
  }

  while (pendingAreas.isNotEmpty) {
    final curArea = pendingAreas.first;
    pendingAreas.remove(curArea);

    final bucket = areaBuckets[curArea];
    if (bucket == null || bucket.isEmpty) continue;

    final toProcess = bucket.toList();
    for (final idx in toProcess) {
      final cluster = clusters[idx];
      if (cluster.area != curArea) continue;

      final neighbors = adjacency[idx];
      final isLargeEnough = filterArea > 0 && cluster.area >= filterArea;
      final isMaxArea = cluster.area >= maxArea;

      if (isMaxArea) {
        saveMeta(idx);
        output.add(idx);
        continue;
      }

      if (neighbors == null || neighbors.isEmpty) {
        if (pendingAreas.isEmpty || hasKeyColor) {
          saveMeta(idx);
          output.add(idx);
        }
        continue;
      }

      final myColor = cluster.color;
      var bestNeighbor = neighbors.first;
      var bestDiff = _colorDiff(myColor, clusters[bestNeighbor].color);
      for (final n in neighbors) {
        final d = _colorDiff(myColor, clusters[n].color);
        if (d < bestDiff) {
          bestDiff = d;
          bestNeighbor = n;
        }
      }

      if (isLargeEnough) {
        final shouldDeepen = bestDiff > deepenDiff;
        if (shouldDeepen) {
          saveMeta(idx);
          output.add(idx);
        } else {
          clusters[bestNeighbor].residueSum.merge(cluster.residueSum);
        }
        bucket.remove(idx);
        mergeCluster(idx, bestNeighbor);
      } else {
        clusters[bestNeighbor].residueSum.merge(cluster.residueSum);
        bucket.remove(idx);
        mergeCluster(idx, bestNeighbor);
      }
    }
  }

  return output;
}

// ============================================================================
//  Binary image
// ============================================================================

class _BinaryImage {
  final int width, height;
  final Uint8List _data;

  _BinaryImage(this.width, this.height) : _data = Uint8List(width * height);

  bool get(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return false;
    return _data[y * width + x] != 0;
  }

  void set(int x, int y, bool v) {
    if (x >= 0 && y >= 0 && x < width && y < height) {
      _data[y * width + x] = v ? 1 : 0;
    }
  }

  _BinaryImage negative() {
    final result = _BinaryImage(width, height);
    for (var i = 0; i < _data.length; i++) {
      result._data[i] = _data[i] == 0 ? 1 : 0;
    }
    return result;
  }

  List<_BinaryCluster> toClusters() {
    final clusterMap = Int32List(width * height);
    for (var i = 0; i < clusterMap.length; i++) {
      clusterMap[i] = -1;
    }
    final clusters = <_BinaryCluster>[];
    var nextIdx = 0;

    void combine(int from, int to) {
      final fc = clusters[from];
      final tc = clusters[to];
      for (final p in fc.points) {
        clusterMap[p.y * width + p.x] = to;
      }
      tc.points.addAll(fc.points);
      tc.rect.merge(fc.rect);
      fc.points.clear();
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!get(x, y)) continue;
        final up = y > 0 && get(x, y - 1);
        final left = x > 0 && get(x - 1, y);
        var clusterUp = (y > 0 && up) ? clusterMap[(y - 1) * width + x] : -1;
        var clusterLeft = (x > 0 && left) ? clusterMap[y * width + (x - 1)] : -1;

        if (up && left && clusterUp >= 0 && clusterLeft >= 0 && clusterUp != clusterLeft) {
          if (clusters[clusterLeft].points.length <= clusters[clusterUp].points.length) {
            combine(clusterLeft, clusterUp);
            clusterLeft = clusterUp;
          } else {
            combine(clusterUp, clusterLeft);
            clusterUp = clusterLeft;
          }
        }

        final pos = _PointI(x, y);
        if (up && clusterUp >= 0) {
          clusterMap[y * width + x] = clusterUp;
          clusters[clusterUp].add(pos);
        } else if (left && clusterLeft >= 0) {
          clusterMap[y * width + x] = clusterLeft;
          clusters[clusterLeft].add(pos);
        } else {
          final c = _BinaryCluster();
          c.add(pos);
          clusters.add(c);
          clusterMap[y * width + x] = nextIdx;
          nextIdx++;
        }
      }
    }
    return clusters.where((c) => c.points.isNotEmpty).toList();
  }
}

class _BinaryCluster {
  final List<_PointI> points = [];
  final _Rect rect = _Rect();

  void add(_PointI p) {
    points.add(p);
    rect.addXY(p.x, p.y);
  }

  _BinaryImage toBinaryImage() {
    final img = _BinaryImage(rect.width, rect.height);
    for (final p in points) {
      img.set(p.x - rect.left, p.y - rect.top, true);
    }
    return img;
  }
}

// ============================================================================
//  Point types
// ============================================================================

class _PointI {
  final int x, y;
  const _PointI(this.x, this.y);

  @override
  bool operator ==(Object other) => other is _PointI && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(x, y);
}

class _PointF {
  double x, y;
  _PointF(this.x, this.y);

  _PointF operator +(_PointF o) => _PointF(x + o.x, y + o.y);
  _PointF operator -(_PointF o) => _PointF(x - o.x, y - o.y);
  _PointF operator *(double s) => _PointF(x * s, y * s);

  double get norm => sqrt(x * x + y * y);

  _PointF normalized() {
    final n = norm;
    if (n < 1e-10) return _PointF(0, 0);
    return _PointF(x / n, y / n);
  }
}

// ============================================================================
//  Path walking
// ============================================================================

List<_PointI> _walkPath(_BinaryImage image, _PointI start, bool clockwise) {
  final path = <_PointI>[start];
  var curr = start;
  var prev = start;
  var prevPrev = start;

  _PointI dirVec(int d) {
    switch (d) {
      case 0: return const _PointI(0, -1);
      case 2: return const _PointI(1, 0);
      case 4: return const _PointI(0, 1);
      case 6: return const _PointI(-1, 0);
      default: return const _PointI(0, 0);
    }
  }

  (bool, bool) sidePixels(int dir, _PointI at) {
    switch (dir) {
      case 0: return (image.get(at.x - 1, at.y - 1), image.get(at.x, at.y - 1));
      case 2: return (image.get(at.x, at.y), image.get(at.x, at.y - 1));
      case 4: return (image.get(at.x - 1, at.y), image.get(at.x, at.y));
      case 6: return (image.get(at.x - 1, at.y), image.get(at.x - 1, at.y - 1));
      default: return (false, false);
    }
  }

  _PointI ahead(_PointI p, int d) {
    final v = dirVec(d);
    return _PointI(p.x + v.x, p.y + v.y);
  }

  final range = clockwise ? [0, 2, 4, 6] : [6, 4, 2, 0];

  for (var step = 0; step < 10000000; step++) {
    var dir = -1;

    while (true) {
      var go = -1;
      for (final k in range) {
        final next = ahead(curr, k);
        if (next == prev || next == prevPrev) continue;
        final (a, b) = sidePixels(k, curr);
        if (a != b) {
          go = k;
          break;
        }
      }

      if (go == -1) break;
      if (dir != -1 && dir != go) break;

      dir = go;
      prevPrev = prev;
      prev = curr;
      curr = ahead(curr, go);

      if (curr == start && path.length > 1) {
        return path;
      }
    }

    if (dir == -1) break;
    path.add(curr);
  }

  return path;
}

_PointI? _findBoundaryStart(_BinaryImage image) {
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if (image.get(x, y) && !image.get(x, y - 1)) {
        return _PointI(x, y);
      }
    }
  }
  return null;
}

// ============================================================================
//  Path simplification
// ============================================================================

int _signedArea(_PointI p1, _PointI p2, _PointI p3) {
  return (p2.x - p1.x) * (p3.y - p1.y) - (p3.x - p1.x) * (p2.y - p1.y);
}

List<_PointI> _removeStaircase(List<_PointI> path, bool clockwise) {
  final len = path.length;
  if (len == 0) return [];

  int segLen(int i, int j) {
    return (path[i].x - path[j].x).abs() + (path[i].y - path[j].y).abs();
  }

  final result = <_PointI>[];
  for (var i = 0; i < len; i++) {
    final j = (i + 1) % len;
    final h = i > 0 ? i - 1 : len - 1;

    final keep = (i == 0 || i == len - 1)
        ? true
        : (segLen(i, h) == 1 || segLen(i, j) == 1)
            ? (() {
                final area = _signedArea(path[h], path[i], path[j]);
                return area != 0 && (area > 0) == clockwise;
              })()
            : true;

    if (keep) result.add(path[i]);
  }
  return result;
}

double _evaluatePenalty(_PointI a, _PointI b, _PointI c) {
  double sq(int v) => (v * v).toDouble();
  final l1 = sqrt(sq(a.x - b.x) + sq(a.y - b.y));
  final l2 = sqrt(sq(b.x - c.x) + sq(b.y - c.y));
  final l3 = sqrt(sq(c.x - a.x) + sq(c.y - a.y));
  final p = (l1 + l2 + l3) / 2.0;
  final area = sqrt((p * (p - l1) * (p - l2) * (p - l3)).abs());
  if (l3 < 1e-10) return 0;
  return area * area / l3;
}

List<_PointI> _limitPenalties(List<_PointI> path) {
  const tolerance = 1.0;
  final len = path.length;
  if (len == 0) return [];

  double pastDelta(int from, int to) {
    var maxP = 0.0;
    for (var i = from + 1; i < to; i++) {
      final p = _evaluatePenalty(path[from], path[i], path[to]);
      if (p > maxP) maxP = p;
    }
    return maxP;
  }

  final result = <_PointI>[path[0]];
  var last = 0;
  for (var i = 1; i < len; i++) {
    if (i == last + 1) continue;
    if (pastDelta(last, i) >= tolerance) {
      last = i - 1;
      result.add(path[i - 1]);
    }
    if (i == len - 1) {
      result.add(path[i]);
    }
  }
  if (result.length == 1 && len > 1) result.add(path[len - 1]);
  return result;
}

// ============================================================================
//  Path smoothing — 4-point subdivision
// ============================================================================

double _angle(_PointF p) {
  if (p.y.isNegative) return -acos(p.x.clamp(-1.0, 1.0));
  return acos(p.x.clamp(-1.0, 1.0));
}

double _signedAngleDiff(double from, double to) {
  var v2 = to;
  if (from > v2) v2 += 2.0 * pi;
  final diff = v2 - from;
  return diff > pi ? diff - 2.0 * pi : diff;
}

List<bool> _findCorners(List<_PointF> path, double threshold) {
  final len = path.length;
  if (len == 0) return [];
  final corners = List.filled(len, false);
  for (var i = 0; i < len; i++) {
    final prev = i > 0 ? i - 1 : len - 1;
    final next = (i + 1) % len;
    final v1 = (path[i] - path[prev]).normalized();
    final v2 = (path[next] - path[i]).normalized();
    final angleDiff = _signedAngleDiff(_angle(v1), _angle(v2)).abs();
    if (angleDiff >= threshold) corners[i] = true;
  }
  return corners;
}

(List<_PointF>, List<bool>, bool) _subdivideKeepCorners(
  List<_PointF> path, List<bool> corners, double outsetRatio, double segLength,
) {
  final len = path.length;
  final newPath = <_PointF>[];
  final newCorners = <bool>[];
  var canTerminate = true;

  for (var i = 0; i < len; i++) {
    newPath.add(path[i]);
    newCorners.add(corners[i]);
    final j = (i + 1) % len;

    final lengthCurr = (path[i] - path[j]).norm;
    if (lengthCurr <= segLength) continue;

    var prev = i > 0 ? i - 1 : len - 1;
    var next = (j + 1) % len;

    final lengthPrev = (path[prev] - path[i]).norm;
    final lengthNext = (path[next] - path[j]).norm;
    if (lengthPrev / lengthCurr >= 2.0 || lengthNext / lengthCurr >= 2.0) continue;

    if (corners[i]) prev = i;
    if (corners[j]) next = j;
    if (prev == i && next == j) continue;

    final midOut = _PointF((path[i].x + path[j].x) / 2, (path[i].y + path[j].y) / 2);
    final midIn = _PointF((path[prev].x + path[next].x) / 2, (path[prev].y + path[next].y) / 2);
    final vecOut = midOut - midIn;
    final magnitude = vecOut.norm / outsetRatio;

    _PointF newPoint;
    if (magnitude < 1e-10) {
      newPoint = midOut;
    } else {
      newPoint = midOut + vecOut.normalized() * magnitude;
    }

    newPath.add(newPoint);
    newCorners.add(false);

    if ((path[i] - newPoint).norm > segLength || (path[j] - newPoint).norm > segLength) {
      canTerminate = false;
    }
  }

  return (newPath, newCorners, canTerminate);
}

List<_PointF> _smoothPath(List<_PointI> intPath, double cornerThreshold, double segLength, int maxIter) {
  if (intPath.length < 3) {
    return intPath.map((p) => _PointF(p.x.toDouble(), p.y.toDouble())).toList();
  }

  final fPath = intPath.map((p) => _PointF(p.x.toDouble(), p.y.toDouble())).toList();
  var corners = _findCorners(fPath, cornerThreshold);
  var path = fPath;

  for (var i = 0; i < maxIter; i++) {
    final (newPath, newCorners, done) = _subdivideKeepCorners(path, corners, 8.0, segLength);
    path = newPath;
    corners = newCorners;
    if (done) break;
  }

  return path;
}

// ============================================================================
//  Cubic Bezier fitting
// ============================================================================

List<bool> _findSplicePoints(List<_PointF> path, double threshold) {
  final len = path.length;
  if (len == 0) return [];
  final splicePoints = List.filled(len, false);
  var isIncreasing = false;
  var angleDisp = 0.0;

  for (var i = 0; i < len; i++) {
    final prev = i > 0 ? i - 1 : len - 1;
    final next = (i + 1) % len;
    final v1 = (path[i] - path[prev]).normalized();
    final v2 = (path[next] - path[i]).normalized();
    final angleDiff = _signedAngleDiff(_angle(v1), _angle(v2));
    final currentlyIncreasing = !angleDiff.isNegative;

    if (i == 0) {
      isIncreasing = currentlyIncreasing;
    } else if (isIncreasing != currentlyIncreasing) {
      splicePoints[i] = true;
      isIncreasing = currentlyIncreasing;
    }

    angleDisp += angleDiff;
    if (angleDisp.abs() >= threshold) {
      splicePoints[i] = true;
    }
    if (splicePoints[i]) angleDisp = 0.0;
  }
  return splicePoints;
}

List<_PointF> _getCircularSubpath(List<_PointF> path, int from, int to) {
  if (to > from) {
    return path.sublist(from, to + 1);
  }
  return [...path.sublist(from), ...path.sublist(0, to + 1)];
}

List<_PointF> _fitBezier(List<_PointF> points) {
  if (points.length < 2) return [_PointF(0, 0), _PointF(0, 0), _PointF(0, 0), _PointF(0, 0)];

  final p0 = points.first;
  final p3 = points.last;

  if (points.length == 2) {
    final mid = _PointF((p0.x + p3.x) / 2, (p0.y + p3.y) / 2);
    return [p0, mid, mid, p3];
  }

  final n = points.length;
  final t = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    t[i] = t[i - 1] + (points[i] - points[i - 1]).norm;
  }
  final totalLen = t[n - 1];
  if (totalLen < 1e-10) return [p0, p0, p3, p3];
  for (var i = 1; i < n; i++) {
    t[i] /= totalLen;
  }

  var c11 = 0.0, c12 = 0.0, c22 = 0.0;
  var x1 = 0.0, y1 = 0.0, x2 = 0.0, y2 = 0.0;

  for (var i = 0; i < n; i++) {
    final ti = t[i];
    final b1 = 3 * (1 - ti) * (1 - ti) * ti;
    final b2 = 3 * (1 - ti) * ti * ti;
    final b0 = (1 - ti) * (1 - ti) * (1 - ti);
    final b3 = ti * ti * ti;

    c11 += b1 * b1;
    c12 += b1 * b2;
    c22 += b2 * b2;

    final dx = points[i].x - b0 * p0.x - b3 * p3.x;
    final dy = points[i].y - b0 * p0.y - b3 * p3.y;
    x1 += b1 * dx;
    y1 += b1 * dy;
    x2 += b2 * dx;
    y2 += b2 * dy;
  }

  final det = c11 * c22 - c12 * c12;
  if (det.abs() < 1e-10) {
    final p1 = _PointF(p0.x + (p3.x - p0.x) / 3, p0.y + (p3.y - p0.y) / 3);
    final p2 = _PointF(p0.x + 2 * (p3.x - p0.x) / 3, p0.y + 2 * (p3.y - p0.y) / 3);
    return [p0, p1, p2, p3];
  }

  final p1 = _PointF(
    (c22 * x1 - c12 * x2) / det,
    (c22 * y1 - c12 * y2) / det,
  );
  final p2 = _PointF(
    (c11 * x2 - c12 * x1) / det,
    (c11 * y2 - c12 * y1) / det,
  );

  return _retractHandles(p0, p1, p2, p3);
}

List<_PointF> _retractHandles(_PointF a, _PointF b, _PointF c, _PointF d) {
  final da = a - d;
  final ab = b - a;
  final dab = _signedAngleDiff(_angle(da.normalized()), _angle(ab.normalized()));
  final bc = c - b;
  final abc = _signedAngleDiff(_angle(ab.normalized()), _angle(bc.normalized()));

  if (!dab.isNegative != !abc.isNegative) {
    final intersection = _findIntersection(a, b, c, d);
    if (intersection != null) {
      return [a, intersection, intersection, d];
    }
  }
  return [a, b, c, d];
}

_PointF? _findIntersection(_PointF p1, _PointF p2, _PointF p3, _PointF p4) {
  final denom = (p4.y - p3.y) * (p2.x - p1.x) - (p4.x - p3.x) * (p2.y - p1.y);
  final numera = (p4.x - p3.x) * (p1.y - p3.y) - (p4.y - p3.y) * (p1.x - p3.x);

  if (denom.abs() < 1e-7 && numera.abs() < 1e-7) {
    return _PointF((p1.x + p2.x) / 2, (p1.y + p2.y) / 2);
  }
  if (denom.abs() < 1e-7) return null;

  final mua = numera / denom;
  return _PointF(p1.x + mua * (p2.x - p1.x), p1.y + mua * (p2.y - p1.y));
}

// ============================================================================
//  Spline from smoothed path
// ============================================================================

class _Spline {
  final List<_PointF> points;
  _Spline(this.points);

  bool get isEmpty => points.length < 4;

  static _Spline fromSmoothedPath(List<_PointF> path, double spliceThreshold) {
    if (path.length <= 2) {
      return _Spline([]);
    }

    final splicePoints = _findSplicePoints(path, spliceThreshold);
    final cutPoints = <int>[];
    for (var i = 0; i < splicePoints.length; i++) {
      if (splicePoints[i]) cutPoints.add(i);
    }
    if (cutPoints.isEmpty) cutPoints.add(0);
    if (cutPoints.length == 1) cutPoints.add((cutPoints[0] + path.length ~/ 2) % path.length);

    final result = <_PointF>[];
    for (var i = 0; i < cutPoints.length; i++) {
      final j = (i + 1) % cutPoints.length;
      final subpath = _getCircularSubpath(path, cutPoints[i], cutPoints[j]);
      final bezier = _fitBezier(subpath);

      if (i == 0) {
        result.add(bezier[0]);
      }
      result.addAll([bezier[1], bezier[2], bezier[3]]);
    }

    return _Spline(result);
  }

  String toSvgString(_PointF offset, int precision) {
    if (isEmpty) return '';
    final buf = StringBuffer();
    String fmt(double v) => precision >= 0 ? v.toStringAsFixed(precision) : v.toString();

    buf.write('M${fmt(points[0].x + offset.x)} ${fmt(points[0].y + offset.y)} ');
    var i = 1;
    while (i < points.length - 2) {
      buf.write('C${fmt(points[i].x + offset.x)} ${fmt(points[i].y + offset.y)} '
          '${fmt(points[i + 1].x + offset.x)} ${fmt(points[i + 1].y + offset.y)} '
          '${fmt(points[i + 2].x + offset.x)} ${fmt(points[i + 2].y + offset.y)} ');
      i += 3;
    }
    buf.write('Z ');
    return buf.toString();
  }
}

// ============================================================================
//  Cluster → Compound path (outer boundary + holes)
// ============================================================================

String _clusterToCompoundPath(
  _Rect rect, List<int> pixelIndices, int parentWidth, {
  required String mode,
  required double cornerThreshold,
  required double lengthThreshold,
  required int maxIterations,
  required double spliceThreshold,
}) {
  final bw = rect.width;
  final bh = rect.height;
  if (bw == 0 || bh == 0) return '';

  final img = _BinaryImage(bw, bh);
  for (final i in pixelIndices) {
    final x = (i % parentWidth) - rect.left;
    final y = (i ~/ parentWidth) - rect.top;
    img.set(x, y, true);
  }

  // Decompose into 4-connected components — trace each separately
  final posComponents = img.toClusters();

  final pathParts = <String>[];

  for (final comp in posComponents) {
    if (comp.points.length < 3) continue;

    final cw = comp.rect.width;
    final ch = comp.rect.height;
    if (cw == 0 || ch == 0) continue;

    final compImg = _BinaryImage(cw, ch);
    for (final p in comp.points) {
      compImg.set(p.x - comp.rect.left, p.y - comp.rect.top, true);
    }

    // Fill holes
    final mainImg = _BinaryImage(cw, ch);
    for (var y = 0; y < ch; y++) {
      for (var x = 0; x < cw; x++) {
        mainImg.set(x, y, compImg.get(x, y));
      }
    }

    final holes = <(_BinaryImage, _PointI)>[];
    final negClusters = compImg.negative().toClusters();
    for (final hole in negClusters) {
      if (hole.rect.left == 0 || hole.rect.top == 0 ||
          hole.rect.right == cw || hole.rect.bottom == ch) {
        continue;
      }
      for (final p in hole.points) {
        mainImg.set(p.x, p.y, true);
      }
      holes.add((hole.toBinaryImage(), _PointI(hole.rect.left, hole.rect.top)));
    }

    final compOffset = _PointI(comp.rect.left, comp.rect.top);
    final globalOffset = _PointI(rect.left, rect.top);

    final outerStr = _imageToPathString(
      mainImg, true, compOffset, globalOffset,
      mode: mode,
      cornerThreshold: cornerThreshold,
      lengthThreshold: lengthThreshold,
      maxIterations: maxIterations,
      spliceThreshold: spliceThreshold,
    );
    if (outerStr.isNotEmpty) pathParts.add(outerStr);

    for (final (holeImg, holeOffset) in holes) {
      final holeStr = _imageToPathString(
        holeImg, false,
        _PointI(compOffset.x + holeOffset.x, compOffset.y + holeOffset.y),
        globalOffset,
        mode: mode,
        cornerThreshold: cornerThreshold,
        lengthThreshold: lengthThreshold,
        maxIterations: maxIterations,
        spliceThreshold: spliceThreshold,
      );
      if (holeStr.isNotEmpty) pathParts.add(holeStr);
    }
  }

  return pathParts.join();
}

String _imageToPathString(
  _BinaryImage image, bool clockwise, _PointI localOffset, _PointI globalOffset, {
  required String mode,
  required double cornerThreshold,
  required double lengthThreshold,
  required int maxIterations,
  required double spliceThreshold,
}) {
  final start = _findBoundaryStart(image);
  if (start == null) return '';

  final rawPath = _walkPath(image, start, clockwise);
  if (rawPath.length < 3) return '';

  if (mode == 'spline') {
    final simplified = _limitPenalties(_removeStaircase(rawPath, clockwise));
    if (simplified.length < 3) return '';

    final smoothed = _smoothPath(simplified, cornerThreshold, lengthThreshold, maxIterations);
    if (smoothed.length < 3) return '';

    final spline = _Spline.fromSmoothedPath(smoothed, spliceThreshold);
    final offset = _PointF(
      (localOffset.x + globalOffset.x).toDouble(),
      (localOffset.y + globalOffset.y).toDouble(),
    );
    return spline.toSvgString(offset, 2);
  } else {
    final simplified = _limitPenalties(_removeStaircase(rawPath, clockwise));
    if (simplified.isEmpty) return '';

    final ox = localOffset.x + globalOffset.x;
    final oy = localOffset.y + globalOffset.y;
    final buf = StringBuffer();
    buf.write('M${simplified[0].x + ox},${simplified[0].y + oy} ');
    for (var i = 1; i < simplified.length; i++) {
      buf.write('L${simplified[i].x + ox},${simplified[i].y + oy} ');
    }
    buf.write('Z ');
    return buf.toString();
  }
}

// ============================================================================
//  SVG assembly
// ============================================================================

class _SvgPath {
  final String pathData;
  final _Color color;
  final int precision;

  _SvgPath(this.pathData, this.color, this.precision);
}

String _buildSvg(List<_SvgPath> paths, int width, int height) {
  final buf = StringBuffer();
  buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  buf.writeln('<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="$width" height="$height">');

  for (final p in paths) {
    if (p.pathData.isEmpty) continue;
    buf.writeln('<path d="${p.pathData}" fill="${p.color.toHex()}"/>');
  }

  buf.writeln('</svg>');
  return buf.toString();
}
