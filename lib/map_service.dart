import 'dart:math';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:path_provider/path_provider.dart';

import 'package:xcnav/datadog.dart';
import 'package:xcnav/dem_service.dart';

enum MapTileSrc {
  topo,
  sectional,
  satellite,
}

bool mapServiceIsInit = false;

TileProvider? _makeTileProvider(String instanceName) {
  debugPrint("------ make tile provider \"$instanceName\" ----");
  if (!mapServiceIsInit) return null;
  try {
    return FMTCTileProvider(stores: {instanceName: BrowseStoreStrategy.readUpdateCreate});
  } catch (e, trace) {
    error("FMTC: Error making tile provider",
        errorMessage: e.toString(), errorStackTrace: trace, attributes: {"layerName": instanceName});
    return null;
  }
}

final Map<MapTileSrc, TileLayer> _tileLayersCache = {};

String _getUrlTemplate(MapTileSrc src) {
  switch (src) {
    case MapTileSrc.sectional:
      // Global road/basemap replacement for the former US-only VFRMap layer.
      return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    case MapTileSrc.satellite:
      return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
    case MapTileSrc.topo:
      return "https://tile.opentopomap.org/{z}/{x}/{y}.png";
  }
}

TileLayer _buildMapTileLayer(MapTileSrc tileSrc) {
  final tileName = tileSrc.toString().split(".").last;
  switch (tileSrc) {
    case MapTileSrc.sectional:
      return TileLayer(
        urlTemplate: _getUrlTemplate(tileSrc),
        tileProvider: NetworkTileProvider(),
        userAgentPackageName: 'com.fateh.ce',
        maxNativeZoom: 19,
        panBuffer: 0,
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
        errorTileCallback: (tile, error, stackTrace) {
          debugPrint("$tileName: error: $tile, $error, $stackTrace");
        },
      );
    case MapTileSrc.satellite:
      return TileLayer(
        urlTemplate: _getUrlTemplate(tileSrc),
        tileProvider: NetworkTileProvider(),
        maxNativeZoom: 19,
        minZoom: 2,
        panBuffer: 0,
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
        errorTileCallback: (tile, error, stackTrace) {
          debugPrint("$tileName: error: $tile, $error, $stackTrace");
        },
      );
    case MapTileSrc.topo:
      debugPrint("------ make tile layer ----");
      return TileLayer(
        urlTemplate: _getUrlTemplate(tileSrc),
        tileProvider: NetworkTileProvider(),
        maxNativeZoom: 16,
        panBuffer: 0,
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
        errorTileCallback: (tile, error, stackTrace) {
          debugPrint("$tileName: error: $tile, $error, $stackTrace");
        },
      );
  }
}

TileLayer getMapTileLayer(MapTileSrc tileSrc) {
  if (_tileLayersCache.containsKey(tileSrc)) {
    return _tileLayersCache[tileSrc]!;
  } else {
    final newTileLayer = _buildMapTileLayer(tileSrc);
    _tileLayersCache[tileSrc] = newTileLayer;
    return newTileLayer;
  }
}

final Map<MapTileSrc, Image> mapTileThumbnails = {
  MapTileSrc.topo: Image.asset(
    "assets/images/topo.png",
    filterQuality: FilterQuality.high,
    fit: BoxFit.cover,
  ),
  MapTileSrc.sectional: Image.asset(
    "assets/images/sectional.png",
    filterQuality: FilterQuality.high,
    fit: BoxFit.cover,
  ),
  MapTileSrc.satellite: Image.asset(
    "assets/images/satellite.png",
    filterQuality: FilterQuality.high,
    fit: BoxFit.cover,
  ),
};

Future initMapCache() async {
  await FMTCObjectBoxBackend().initialise(rootDirectory: (await getApplicationDocumentsDirectory()).path);

  for (final tileSrc in mapTileThumbnails.keys) {
    final tileName = tileSrc.toString().split(".").last;
    final store = FMTCStore(tileName);
    await store.manage.create();
    await store.metadata.set(key: 'sourceURL', value: _getUrlTemplate(tileSrc));
    store.manage.removeTilesOlderThan(expiry: clock.now().subtract(const Duration(days: 16)));
  }

  await initDemCache();

  mapServiceIsInit = true;
}

String asReadableSize(double value) {
  if (value <= 0) return '0 B';
  final List<String> units = ['B', 'kB', 'MB', 'GB', 'TB'];
  final int digitGroups = (log(value) / log(1024)).round();
  return '${NumberFormat('#,##0.#').format(value / pow(1024, digitGroups))} ${units[digitGroups]}';
}

Future<String> getMapTileCacheSize() async {
  final sum = await FMTCRoot.stats.realSize * 1000;
  return asReadableSize(sum);
}

void emptyMapTileCache() {
  const demStore = FMTCStore("dem");
  debugPrint("Clear Map Cache: dem");
  demStore.manage.reset();

  for (final tileSrc in mapTileThumbnails.keys) {
    final tileName = tileSrc.toString().split(".").last;
    final store = FMTCStore(tileName);
    debugPrint("Clear Map Cache: $tileName");
    store.manage.reset();
  }
}
