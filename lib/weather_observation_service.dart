import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Wind forecast point used by the existing map renderer.
/// Speeds are stored in m/s and direction in compass degrees.
class WeatherObservation {
  final double? windSpd;
  final double? windGust;
  final double? windDir;
  final String stationId;
  final LatLng latlng;
  final DateTime timeObserved;
  final DateTime timeFetched;
  late final Color color;

  WeatherObservation(
      this.stationId, this.latlng, this.timeFetched, this.timeObserved, this.windSpd, this.windGust, this.windDir) {
    if ((windSpd ?? 0) > 5.3 || (windGust ?? 0) > 7) {
      color = Colors.red.withAlpha(150);
    } else if ((windSpd ?? 0) > 3.6 || (windGust ?? 0) > 4.5) {
      color = Colors.amber.withAlpha(150);
    } else {
      color = Colors.white.withAlpha(150);
    }
  }

  Map<String, dynamic> toJson() => {
        'id': stationId,
        'lat': latlng.latitude,
        'lng': latlng.longitude,
        'observed': timeObserved.toIso8601String(),
        'fetched': timeFetched.toIso8601String(),
        'speed': windSpd,
        'gust': windGust,
        'dir': windDir,
      };

  factory WeatherObservation.fromJson(Map<String, dynamic> j) => WeatherObservation(
        j['id'] as String? ?? 'cache',
        LatLng((j['lat'] as num).toDouble(), (j['lng'] as num).toDouble()),
        DateTime.parse(j['fetched'] as String),
        DateTime.parse(j['observed'] as String),
        (j['speed'] as num?)?.toDouble(),
        (j['gust'] as num?)?.toDouble(),
        (j['dir'] as num?)?.toDouble(),
      );
}

/// Forecast providers exposed through Open-Meteo. The UI can later select any
/// provider without changing the map renderer or offline cache format.
enum WindForecastModel {
  automatic('best_match'),
  ecmwf('ecmwf_ifs025'),
  gfs('gfs_global'),
  icon('icon_seamless');

  final String apiName;
  const WindForecastModel(this.apiName);
}

/// Global wind service for MUQATIL.
///
/// Replaces the old weather.gov/state-only implementation. It downloads a
/// 5x5 grid covering roughly a 100 km radius around the viewed area, stores
/// the latest successful grid locally, and keeps returning that grid offline.
class WeatherObservationService {
  static const _cacheKey = 'muqatilWindForecastCacheV1';
  static const _modelKey = 'muqatilWindForecastModelV1';
  static const _refreshEvery = Duration(minutes: 15);
  static const double _radiusKm = 100;
  static const int _gridSide = 5;

  final http.Client _client = http.Client();
  final List<WeatherObservation> _observations = [];
  late final Timer _timer;

  LatLngBounds? mapBounds;
  DateTime? _lastFetch;
  LatLng? _lastFetchCenter;
  bool _fetching = false;
  bool _loadedCache = false;
  WindForecastModel model = WindForecastModel.automatic;

  WeatherObservationService() {
    _loadCache();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _tick());
  }

  void resetSomeTimers() {
    _lastFetch = null;
    _tick();
  }

  Future<void> _loadCache() async {
    if (_loadedCache) return;
    _loadedCache = true;
    final prefs = await SharedPreferences.getInstance();
    final savedModel = prefs.getString(_modelKey);
    if (savedModel != null) {
      model = WindForecastModel.values.firstWhere(
        (e) => e.name == savedModel,
        orElse: () => WindForecastModel.automatic,
      );
    }
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _observations
        ..clear()
        ..addAll(decoded.map((e) => WeatherObservation.fromJson(Map<String, dynamic>.from(e as Map))));
    } catch (_) {
      // Ignore a damaged cache; the next online refresh replaces it.
    }
  }

  Future<void> setModel(WindForecastModel value) async {
    if (model == value) return;
    model = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelKey, value.name);
    _lastFetch = null;
    _tick();
  }

  Iterable<WeatherObservation> getObservations() sync* {
    if (mapBounds == null) return;
    final bounds = mapBounds!;
    for (final o in _observations) {
      if (bounds.contains(o.latlng)) yield o;
    }
  }

  Future<void> _tick() async {
    if (mapBounds == null || _fetching) return;
    await _loadCache();

    final center = mapBounds!.center;
    final movedKm = _lastFetchCenter == null ? double.infinity : _distanceKm(_lastFetchCenter!, center);
    final fresh = _lastFetch != null && clock.now().difference(_lastFetch!) < _refreshEvery;
    if (fresh && movedKm < 25) return;

    _fetching = true;
    try {
      await _fetchGrid(center);
    } finally {
      _fetching = false;
    }
  }

  Future<void> _fetchGrid(LatLng center) async {
    // 5x5 points across a 200 km square. This guarantees at least a 100 km
    // local offline footprint around the centre while keeping requests small.
    final latStep = (_radiusKm * 2 / (_gridSide - 1)) / 111.0;
    final cosLat = max(0.2, cos(center.latitude * pi / 180).abs());
    final lngStep = (_radiusKm * 2 / (_gridSide - 1)) / (111.0 * cosLat);

    final points = <LatLng>[];
    for (var y = 0; y < _gridSide; y++) {
      for (var x = 0; x < _gridSide; x++) {
        points.add(LatLng(
          center.latitude + (y - (_gridSide - 1) / 2) * latStep,
          center.longitude + (x - (_gridSide - 1) / 2) * lngStep,
        ));
      }
    }

    final params = <String, String>{
      'latitude': points.map((p) => p.latitude.toStringAsFixed(5)).join(','),
      'longitude': points.map((p) => p.longitude.toStringAsFixed(5)).join(','),
      'current': 'wind_speed_10m,wind_direction_10m,wind_gusts_10m',
      'wind_speed_unit': 'ms',
      'timezone': 'UTC',
    };
    if (model != WindForecastModel.automatic) params['models'] = model.apiName;

    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', params);
    final response = await _client
        .get(uri, headers: {'User-Agent': 'MUQATIL/1.0 aviation-wind'})
        .timeout(const Duration(seconds: 15), onTimeout: () => http.Response('', 408));

    if (response.statusCode != 200) return;

    final decoded = jsonDecode(response.body);
    final rows = decoded is List ? decoded : [decoded];
    final now = clock.now();
    final next = <WeatherObservation>[];

    for (var i = 0; i < rows.length && i < points.length; i++) {
      final row = rows[i] as Map<String, dynamic>;
      final current = row['current'] as Map<String, dynamic>?;
      if (current == null) continue;
      final speed = (current['wind_speed_10m'] as num?)?.toDouble();
      final gust = (current['wind_gusts_10m'] as num?)?.toDouble();
      final dir = (current['wind_direction_10m'] as num?)?.toDouble();
      if (speed == null || dir == null) continue;
      final observed = DateTime.tryParse(current['time'] as String? ?? '')?.toUtc() ?? now;
      next.add(WeatherObservation('forecast_$i', points[i], now, observed, speed, gust, dir));
    }

    if (next.isEmpty) return;
    _observations
      ..clear()
      ..addAll(next);
    _lastFetch = now;
    _lastFetchCenter = center;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, jsonEncode(_observations.map((e) => e.toJson()).toList()));
  }

  static double _distanceKm(LatLng a, LatLng b) {
    const earthKm = 6371.0;
    final dLat = (b.latitude - a.latitude) * pi / 180;
    final dLng = (b.longitude - a.longitude) * pi / 180;
    final lat1 = a.latitude * pi / 180;
    final lat2 = b.latitude * pi / 180;
    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return earthKm * 2 * atan2(sqrt(h), sqrt(1 - h));
  }
}

WeatherObservationService? _weatherService;

void weatherServiceResetSomeTimers() {
  _weatherService?.resetSomeTimers();
}

Iterable<WeatherObservation> getWeatherObservations(LatLngBounds bounds) {
  _weatherService ??= WeatherObservationService();
  _weatherService!.mapBounds = bounds;
  return _weatherService!.getObservations();
}
