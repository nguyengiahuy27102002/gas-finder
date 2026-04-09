import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONFIG
// ─────────────────────────────────────────────────────────────────────────────
// Your machine's local IP: 10.1.10.139 (detected automatically)
//
// Uncomment the line that matches where you're running the app:

// const String _kBackendBase = 'http://10.0.2.2:3000/api';      // Android emulator
// const String _kBackendBase = 'http://localhost:3000/api';      // iOS simulator
const String _kBackendBase = 'http://10.1.10.139:3000/api';       // Physical device (WiFi)

// ─────────────────────────────────────────────────────────────────────────────
// MODEL
// ─────────────────────────────────────────────────────────────────────────────

class FuelPrices {
  final double? regular;
  final double? midgrade;
  final double? premium;

  const FuelPrices({this.regular, this.midgrade, this.premium});

  factory FuelPrices.fromJson(Map<String, dynamic> json) => FuelPrices(
        regular: (json['regular'] as num?)?.toDouble(),
        midgrade: (json['midgrade'] as num?)?.toDouble(),
        premium: (json['premium'] as num?)?.toDouble(),
      );

  double? get lowest {
    final prices = [regular, midgrade, premium].whereType<double>().toList();
    return prices.isEmpty ? null : prices.reduce(math.min);
  }
}

class GasStation {
  final String id;
  final String name;
  final String brand;
  final String address;
  final double distance;
  final double? rating;
  final int reviewCount;
  final bool? isOpenNow;
  final String? logoUrl;
  final String brandColor; // hex string e.g. "#DD1D21"
  final FuelPrices fuelPrices;
  final String lastUpdated;
  final double lat;
  final double lng;

  const GasStation({
    required this.id,
    required this.name,
    required this.brand,
    required this.address,
    required this.distance,
    this.rating,
    required this.reviewCount,
    this.isOpenNow,
    this.logoUrl,
    required this.brandColor,
    required this.fuelPrices,
    required this.lastUpdated,
    required this.lat,
    required this.lng,
  });

  factory GasStation.fromJson(Map<String, dynamic> json) => GasStation(
        id: json['id'] as String,
        name: json['name'] as String,
        brand: json['brand'] as String? ?? json['name'] as String,
        address: json['address'] as String? ?? '',
        distance: (json['distance'] as num).toDouble(),
        rating: (json['rating'] as num?)?.toDouble(),
        reviewCount: json['reviewCount'] as int? ?? 0,
        isOpenNow: json['isOpenNow'] as bool?,
        logoUrl: json['logoUrl'] as String?,
        brandColor: json['brandColor'] as String? ?? '#2196F3',
        fuelPrices: FuelPrices.fromJson(
            json['fuelPrices'] as Map<String, dynamic>? ?? {}),
        lastUpdated: json['lastUpdated'] as String? ?? '',
        lat: (json['location']['lat'] as num).toDouble(),
        lng: (json['location']['lng'] as num).toDouble(),
      );

  Color get brandColorValue {
    final hex = brandColor.replaceAll('#', '');
    return Color(int.parse('FF$hex', radix: 16));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// REPOSITORY
// ─────────────────────────────────────────────────────────────────────────────

class GasStationRepository {
  Future<List<GasStation>> getNearby({
    required double lat,
    required double lng,
    double radius = 5,
  }) async {
    final uri = Uri.parse('$_kBackendBase/gas-stations/nearby').replace(
      queryParameters: {
        'lat': lat.toString(),
        'lng': lng.toString(),
        'radius': radius.toString(),
      },
    );

    final http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 15));
    } on Exception catch (e) {
      // Connection refused, timeout, no network, etc.
      throw Exception(
        'Cannot reach backend at $_kBackendBase.\n'
        'Make sure the NestJS server is running:\n'
        '  cd backend && npm run start:dev\n\n'
        'Original error: $e',
      );
    }

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(body['message'] ?? 'Server error ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['stations'] as List<dynamic>;
    return list
        .map((e) => GasStation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Quick ping to verify the backend is reachable before fetching data.
  Future<bool> isBackendReachable() async {
    try {
      final uri = Uri.parse('$_kBackendBase/gas-stations/health');
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOCATION SERVICE
// ─────────────────────────────────────────────────────────────────────────────

class LocationService {
  /// Returns the user's current position.
  /// On web: browser will prompt for location permission.
  /// On mobile: uses GPS with full permission flow.
  /// Falls back to Miami coords if location is unavailable.
  Future<Position> getCurrentPosition() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        // Fall back to a default location so the app still shows stations
        return _fallbackPosition();
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return _fallbackPosition();
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return _fallbackPosition();
      }

      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => _fallbackPosition(),
      );
    } catch (_) {
      return _fallbackPosition();
    }
  }

  /// Default coordinates (Miami, FL) used when GPS is unavailable.
  /// Replace with your own city's coords if needed.
  Position _fallbackPosition() => Position(
        latitude: 25.7617,
        longitude: -80.1918,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN STATE
// ─────────────────────────────────────────────────────────────────────────────

enum _Status { idle, loading, loaded, error }

class _ScreenState {
  final _Status status;
  final List<GasStation> stations;
  final String? errorMessage;
  final Position? userPosition;
  final bool usingFallbackLocation;

  const _ScreenState({
    required this.status,
    this.stations = const [],
    this.errorMessage,
    this.userPosition,
    this.usingFallbackLocation = false,
  });

  _ScreenState copyWith({
    _Status? status,
    List<GasStation>? stations,
    String? errorMessage,
    Position? userPosition,
    bool? usingFallbackLocation,
  }) =>
      _ScreenState(
        status: status ?? this.status,
        stations: stations ?? this.stations,
        errorMessage: errorMessage ?? this.errorMessage,
        userPosition: userPosition ?? this.userPosition,
        usingFallbackLocation:
            usingFallbackLocation ?? this.usingFallbackLocation,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class GasStationsScreen extends StatefulWidget {
  const GasStationsScreen({super.key});

  @override
  State<GasStationsScreen> createState() => _GasStationsScreenState();
}

class _GasStationsScreenState extends State<GasStationsScreen> {
  final _repo = GasStationRepository();
  final _location = LocationService();
  final _searchController = TextEditingController();

  _ScreenState _state = const _ScreenState(status: _Status.idle);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _state = _state.copyWith(status: _Status.loading));

    try {
      // 1. Get position (falls back to Miami if GPS unavailable)
      final position = await _location.getCurrentPosition();
      final isFallback = position.accuracy == 0;

      // 2. Check backend is reachable
      final reachable = await _repo.isBackendReachable();
      if (!reachable) {
        throw Exception(
          'Backend is offline.\n\n'
          'Run in a terminal:\n'
          'cd backend\nnpm run start:dev\n\n'
          'URL: $_kBackendBase',
        );
      }

      // 3. Fetch real stations
      final stations = await _repo.getNearby(
        lat: position.latitude,
        lng: position.longitude,
      );

      setState(() => _state = _ScreenState(
            status: _Status.loaded,
            stations: stations,
            userPosition: position,
            usingFallbackLocation: isFallback,
          ));
    } catch (e) {
      setState(() => _state = _state.copyWith(
            status: _Status.error,
            errorMessage: e.toString().replaceFirst('Exception: ', ''),
          ));
    }
  }

  // Summary bar helpers
  double get _lowestPrice => _state.stations
      .where((s) => s.fuelPrices.regular != null)
      .map((s) => s.fuelPrices.regular!)
      .reduce(math.min);

  double get _highestPrice => _state.stations
      .where((s) => s.fuelPrices.regular != null)
      .map((s) => s.fuelPrices.regular!)
      .reduce(math.max);

  GasStation get _lowestStation => _state.stations
      .where((s) => s.fuelPrices.regular != null)
      .reduce((a, b) => a.fuelPrices.regular! < b.fuelPrices.regular! ? a : b);

  GasStation get _highestStation => _state.stations
      .where((s) => s.fuelPrices.regular != null)
      .reduce((a, b) => a.fuelPrices.regular! > b.fuelPrices.regular! ? a : b);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SafeArea(
        child: Column(
          children: [
            _buildAppBar(),
            _SearchBar(
              controller: _searchController,
              onMapTap: _state.status == _Status.loaded && _state.stations.isNotEmpty
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => GasStationMapScreen(
                            stations: _state.stations,
                            userLat: _state.userPosition?.latitude ?? 25.7617,
                            userLng: _state.userPosition?.longitude ?? -80.1918,
                          ),
                        ),
                      )
                  : null,
            ),
            if (_state.usingFallbackLocation)
              Container(
                width: double.infinity,
                color: const Color(0xFFFFF8E1),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.location_off,
                        size: 14, color: Color(0xFFF57F17)),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Using default location (Miami, FL). Allow location for nearby results.',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFFF57F17)),
                      ),
                    ),
                  ],
                ),
              ),
            if (_state.status == _Status.loaded && _state.stations.isNotEmpty)
              _PriceSummaryBar(
                lowest: _lowestPrice,
                lowestDist: _lowestStation.distance,
                highest: _highestPrice,
                highestDist: _highestStation.distance,
                spreadCents: ((_highestPrice - _lowestPrice) * 100).round(),
              ),
            const SizedBox(height: 8),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.chevron_left,
                  size: 22, color: Color(0xFF1A1A2E)),
            ),
          ),
          const Expanded(
            child: Center(
              child: Text(
                'Fuel',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1A2E),
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ),
          // Refresh button
          GestureDetector(
            onTap: _state.status == _Status.loading ? null : _load,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _state.status == _Status.loading
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF2196F3),
                      ),
                    )
                  : const Icon(Icons.refresh,
                      size: 18, color: Color(0xFF2196F3)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return switch (_state.status) {
      _Status.idle || _Status.loading => const _LoadingSkeleton(),
      _Status.error => _ErrorView(
          message: _state.errorMessage ?? 'Something went wrong.',
          onRetry: _load,
        ),
      _Status.loaded => _state.stations.isEmpty
          ? _EmptyView(onRetry: _load)
          : _StationList(
              stations: _state.stations,
              userLat: _state.userPosition?.latitude,
              userLng: _state.userPosition?.longitude,
            ),
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SEARCH BAR
// ─────────────────────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback? onMapTap;
  const _SearchBar({required this.controller, this.onMapTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Icon(Icons.search, color: Colors.grey[400], size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                style:
                    const TextStyle(fontSize: 14, color: Color(0xFF1A1A2E)),
                decoration: InputDecoration(
                  hintText: 'Search fuel station nearby',
                  hintStyle:
                      TextStyle(color: Colors.grey[400], fontSize: 14),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            Container(width: 1, height: 24, color: Colors.grey[200]),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onMapTap,
              child: const Icon(Icons.map_outlined,
                  color: Color(0xFF2196F3), size: 22),
            ),
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRICE SUMMARY BAR
// ─────────────────────────────────────────────────────────────────────────────

class _PriceSummaryBar extends StatelessWidget {
  final double lowest;
  final double lowestDist;
  final double highest;
  final double highestDist;
  final int spreadCents;

  const _PriceSummaryBar({
    required this.lowest,
    required this.lowestDist,
    required this.highest,
    required this.highestDist,
    required this.spreadCents,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            // Lowest
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Lowest',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey[500])),
                  const SizedBox(height: 2),
                  Text(
                    '\$${lowest.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A2E),
                      letterSpacing: -0.5,
                    ),
                  ),
                  Text(
                    '${lowestDist.toStringAsFixed(2)} mi',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            // Spread
            Expanded(
              child: Column(
                children: [
                  Text('Spread',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey[500])),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                          width: 20,
                          height: 2,
                          color: const Color(0xFFE53935)),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEBEE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '${spreadCents}¢',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFE53935),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                          width: 20,
                          height: 2,
                          color: const Color(0xFFE53935)),
                    ],
                  ),
                ],
              ),
            ),
            // Highest
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Highest',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey[500])),
                  const SizedBox(height: 2),
                  Text(
                    '\$${highest.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A2E),
                      letterSpacing: -0.5,
                    ),
                  ),
                  Text(
                    '${highestDist.toStringAsFixed(2)} mi',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STATION LIST
// ─────────────────────────────────────────────────────────────────────────────

class _StationList extends StatelessWidget {
  final List<GasStation> stations;
  final double? userLat;
  final double? userLng;

  const _StationList({
    required this.stations,
    this.userLat,
    this.userLng,
  });

  String? _badgeFor(GasStation station) {
    if (stations.isEmpty) return null;

    final withPrices = stations.where((s) => s.fuelPrices.regular != null).toList();
    final withRatings = stations.where((s) => s.rating != null).toList();

    final lowestPrice  = withPrices.isEmpty ? null : withPrices.map((s) => s.fuelPrices.regular!).reduce(math.min);
    final highestPrice = withPrices.isEmpty ? null : withPrices.map((s) => s.fuelPrices.regular!).reduce(math.max);
    final closestDist  = stations.map((s) => s.distance).reduce(math.min);
    final highestRating = withRatings.isEmpty ? null : withRatings.map((s) => s.rating!).reduce(math.max);

    if (lowestPrice != null && station.fuelPrices.regular == lowestPrice) return 'Cheapest';
    if (station.distance == closestDist) return 'Closest';
    if (highestRating != null && station.rating == highestRating) return 'Highest Rated';
    if (highestPrice != null && station.fuelPrices.regular == highestPrice) return 'Most Expensive';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final withPrices = stations.where((s) => s.fuelPrices.regular != null).toList();
    final cheapest = withPrices.isEmpty ? null : withPrices.map((s) => s.fuelPrices.regular!).reduce(math.min);

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: stations.length,
      itemBuilder: (context, index) {
        final station = stations[index];
        final isCheapest = station.fuelPrices.regular != null && station.fuelPrices.regular == cheapest;
        return _StationCard(
          station: station,
          isCheapest: isCheapest,
          badge: _badgeFor(station),
          userLat: userLat,
          userLng: userLng,
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STATION CARD
// ─────────────────────────────────────────────────────────────────────────────

class _StationCard extends StatelessWidget {
  final GasStation station;
  final bool isCheapest;
  final String? badge;
  final double? userLat;
  final double? userLng;

  const _StationCard({
    required this.station,
    this.isCheapest = false,
    this.badge,
    this.userLat,
    this.userLng,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isCheapest
            ? Border.all(color: const Color(0xFF2196F3), width: 1.5)
            : Border.all(color: Colors.transparent),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            // ── Top: logo + name + stars + distance ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BrandLogo(station: station),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (station.rating != null) ...[
                            _StarRow(rating: station.rating!),
                            const SizedBox(width: 4),
                            Text(
                              '${station.rating!.toStringAsFixed(1)} '
                              '(${station.reviewCount} Reviews)',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.grey[500]),
                            ),
                          ] else
                            Text('No reviews yet',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey[400])),
                          const Spacer(),
                          Text(
                            '${station.distance.toStringAsFixed(2)} mi',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey[500]),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              station.name,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A1A2E),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (station.isOpenNow != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: station.isOpenNow!
                                    ? const Color(0xFFE8F5E9)
                                    : const Color(0xFFFFEBEE),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                station.isOpenNow! ? 'Open' : 'Closed',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: station.isOpenNow!
                                      ? const Color(0xFF2E7D32)
                                      : const Color(0xFFC62828),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 1),
                      Text(
                        station.address,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[500]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (badge != null) ...[
                        const SizedBox(height: 5),
                        _BadgeLabel(label: badge!),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            Divider(color: Colors.grey[100], height: 1),
            const SizedBox(height: 10),

            // ── Bottom: prices ──
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Fuel type badges
                Expanded(
                  child: Row(
                    children: [
                      _PriceBadge(
                        label: '87',
                        price: station.fuelPrices.regular,
                        highlight: isCheapest,
                      ),
                      const SizedBox(width: 6),
                      _PriceBadge(
                        label: '89',
                        price: station.fuelPrices.midgrade,
                      ),
                      const SizedBox(width: 6),
                      _PriceBadge(
                        label: '91',
                        price: station.fuelPrices.premium,
                      ),
                    ],
                  ),
                ),
                // Directions button
                _DirectionsButton(
                  lat: station.lat,
                  lng: station.lng,
                  name: station.name,
                  userLat: userLat,
                  userLng: userLng,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BADGE LABEL  (Cheapest / Closest / Highest Rated / Most Expensive)
// ─────────────────────────────────────────────────────────────────────────────

class _BadgeLabel extends StatelessWidget {
  final String label;
  const _BadgeLabel({required this.label});

  // Each badge has its own colour scheme
  static const _styles = {
    'Cheapest':       (bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0), icon: Icons.local_offer),
    'Closest':        (bg: Color(0xFFE8F5E9), fg: Color(0xFF2E7D32), icon: Icons.near_me),
    'Highest Rated':  (bg: Color(0xFFFFF8E1), fg: Color(0xFFF57F17), icon: Icons.star),
    'Most Expensive': (bg: Color(0xFFFFEBEE), fg: Color(0xFFC62828), icon: Icons.trending_up),
  };

  @override
  Widget build(BuildContext context) {
    final style = _styles[label];
    if (style == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(style.icon, size: 11, color: style.fg),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: style.fg,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DIRECTIONS BUTTON
// ─────────────────────────────────────────────────────────────────────────────

class _DirectionsButton extends StatelessWidget {
  final double lat;
  final double lng;
  final String name;
  final double? userLat;
  final double? userLng;

  const _DirectionsButton({
    required this.lat,
    required this.lng,
    required this.name,
    this.userLat,
    this.userLng,
  });

  Future<void> _openMaps() async {
    final hasOrigin = userLat != null && userLng != null;

    // Apple Maps — saddr=origin, daddr=destination, dirflg=d (driving)
    final appleUrl = Uri.parse(
      hasOrigin
          ? 'https://maps.apple.com/?saddr=$userLat,$userLng&daddr=$lat,$lng&dirflg=d&t=m'
          : 'https://maps.apple.com/?daddr=$lat,$lng&dirflg=d&t=m',
    );

    // Google Maps — origin + destination for driving
    final googleUrl = Uri.parse(
      hasOrigin
          ? 'https://www.google.com/maps/dir/?api=1&origin=$userLat,$userLng&destination=$lat,$lng&travelmode=driving'
          : 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving',
    );

    if (await canLaunchUrl(appleUrl)) {
      await launchUrl(appleUrl, mode: LaunchMode.externalApplication);
    } else {
      await launchUrl(googleUrl, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _openMaps,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF2196F3),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2196F3).withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions, size: 14, color: Colors.white),
            SizedBox(width: 5),
            Text(
              'Directions',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRICE BADGE
// ─────────────────────────────────────────────────────────────────────────────

class _PriceBadge extends StatelessWidget {
  final String label;
  final double? price;
  final bool highlight;

  const _PriceBadge({
    required this.label,
    this.price,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: highlight && price != null
            ? const Color(0xFFE3F2FD)
            : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: highlight && price != null
            ? Border.all(color: const Color(0xFF2196F3), width: 1)
            : null,
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(fontSize: 10, color: Colors.grey[500])),
          const SizedBox(height: 1),
          Text(
            price != null ? '\$${price!.toStringAsFixed(2)}' : '--',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: highlight && price != null
                  ? const Color(0xFF1565C0)
                  : const Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BRAND LOGO — shows real Google photo, falls back to brand initial
// ─────────────────────────────────────────────────────────────────────────────

class _BrandLogo extends StatelessWidget {
  final GasStation station;
  const _BrandLogo({required this.station});

  @override
  Widget build(BuildContext context) {
    final color = station.brandColorValue;

    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      clipBehavior: Clip.antiAlias,
      child: station.logoUrl != null
          ? Image.network(
              station.logoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _Initials(station: station),
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : _Initials(station: station),
            )
          : _Initials(station: station),
    );
  }
}

class _Initials extends StatelessWidget {
  final GasStation station;
  const _Initials({required this.station});

  @override
  Widget build(BuildContext context) {
    final color = station.brandColorValue;
    final initial = station.brand.isNotEmpty
        ? station.brand[0].toUpperCase()
        : station.name[0].toUpperCase();

    return Center(
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STAR ROW
// ─────────────────────────────────────────────────────────────────────────────

class _StarRow extends StatelessWidget {
  final double rating;
  const _StarRow({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        if (i < rating.floor()) {
          return const Icon(Icons.star, size: 13, color: Color(0xFFFFC107));
        } else if (i < rating) {
          return const Icon(Icons.star_half,
              size: 13, color: Color(0xFFFFC107));
        } else {
          return const Icon(Icons.star_border,
              size: 13, color: Color(0xFFFFC107));
        }
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOADING SKELETON
// ─────────────────────────────────────────────────────────────────────────────

class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      itemCount: 5,
      itemBuilder: (_, __) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Shimmer(width: 52, height: 52, radius: 12),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Shimmer(width: 120, height: 12, radius: 4),
                      const SizedBox(height: 6),
                      _Shimmer(width: 160, height: 16, radius: 4),
                      const SizedBox(height: 4),
                      _Shimmer(width: 200, height: 12, radius: 4),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _Shimmer(width: double.infinity, height: 1, radius: 0),
            const SizedBox(height: 10),
            Row(
              children: [
                _Shimmer(width: 56, height: 40, radius: 8),
                const SizedBox(width: 6),
                _Shimmer(width: 56, height: 40, radius: 8),
                const SizedBox(width: 6),
                _Shimmer(width: 56, height: 40, radius: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Shimmer extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  const _Shimmer(
      {required this.width, required this.height, required this.radius});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.4, end: 0.9).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey[200]!.withOpacity(_animation.value),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ERROR VIEW
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off_outlined,
                size: 56, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, color: Colors.grey[600], height: 1.5),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try Again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2196F3),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EMPTY VIEW
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  final VoidCallback onRetry;
  const _EmptyView({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.local_gas_station, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'No gas stations found nearby.\nTry increasing the search radius.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAP SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class GasStationMapScreen extends StatefulWidget {
  final List<GasStation> stations;
  final double userLat;
  final double userLng;

  const GasStationMapScreen({
    super.key,
    required this.stations,
    required this.userLat,
    required this.userLng,
  });

  @override
  State<GasStationMapScreen> createState() => _GasStationMapScreenState();
}

class _GasStationMapScreenState extends State<GasStationMapScreen> {
  GasStation? _selected;
  late final MapController _mapController;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  // Cheapest station for highlight
  double get _cheapestPrice => widget.stations
      .where((s) => s.fuelPrices.regular != null)
      .map((s) => s.fuelPrices.regular!)
      .reduce(math.min);

  void _onMarkerTap(GasStation station) {
    setState(() => _selected = station);
    _mapController.move(
      LatLng(station.lat, station.lng),
      15,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cheapest = _cheapestPrice;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // ── Map ──────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(widget.userLat, widget.userLng),
              initialZoom: 13.5,
              onTap: (_, __) => setState(() => _selected = null),
            ),
            children: [
              // OpenStreetMap tiles — free, no API key
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.dashmateai.gasfinder',
              ),

              // Station markers
              MarkerLayer(
                markers: [
                  // User location marker
                  Marker(
                    point: LatLng(widget.userLat, widget.userLng),
                    width: 20,
                    height: 20,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF2196F3),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF2196F3).withOpacity(0.4),
                            blurRadius: 8,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Gas station markers
                  ...widget.stations.map((station) {
                    final isCheapest = station.fuelPrices.regular == cheapest;
                    final isSelected = _selected?.id == station.id;
                    return Marker(
                      point: LatLng(station.lat, station.lng),
                      width: isSelected ? 52 : 44,
                      height: isSelected ? 52 : 44,
                      child: GestureDetector(
                        onTap: () => _onMarkerTap(station),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF1565C0)
                                : isCheapest
                                    ? const Color(0xFF2196F3)
                                    : Colors.white,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF1565C0)
                                  : isCheapest
                                      ? const Color(0xFF2196F3)
                                      : Colors.grey.shade300,
                              width: 2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Icon(
                              Icons.local_gas_station,
                              size: isSelected ? 24 : 20,
                              color: isSelected || isCheapest
                                  ? Colors.white
                                  : const Color(0xFF2196F3),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ],
          ),

          // ── App bar overlay ───────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.12),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.arrow_back,
                            size: 18, color: Color(0xFF1A1A2E)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.08),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Text(
                          '${widget.stations.length} stations nearby',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A2E),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Popup card ────────────────────────────────────────────────────
          if (_selected != null)
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: _MapPopupCard(
                station: _selected!,
                isCheapest: _selected!.fuelPrices.regular == cheapest,
                userLat: widget.userLat,
                userLng: widget.userLng,
                onClose: () => setState(() => _selected = null),
              ),
            ),

          // ── Legend ────────────────────────────────────────────────────────
          if (_selected == null)
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _LegendItem(
                    color: const Color(0xFF2196F3),
                    label: 'Cheapest',
                    filled: true,
                  ),
                  const SizedBox(width: 16),
                  _LegendItem(
                    color: Colors.white,
                    label: 'Other stations',
                    filled: false,
                  ),
                  const SizedBox(width: 16),
                  _LegendItem(
                    color: const Color(0xFF2196F3),
                    label: 'You',
                    filled: true,
                    isUser: true,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ── Map Popup Card ────────────────────────────────────────────────────────────

class _MapPopupCard extends StatelessWidget {
  final GasStation station;
  final bool isCheapest;
  final double userLat;
  final double userLng;
  final VoidCallback onClose;

  const _MapPopupCard({
    required this.station,
    required this.isCheapest,
    required this.userLat,
    required this.userLng,
    required this.onClose,
  });

  Future<void> _openDirections() async {
    final appleUrl = Uri.parse(
      'https://maps.apple.com/?saddr=$userLat,$userLng&daddr=${station.lat},${station.lng}&dirflg=d&t=m',
    );
    final googleUrl = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&origin=$userLat,$userLng&destination=${station.lat},${station.lng}&travelmode=driving',
    );
    if (await canLaunchUrl(appleUrl)) {
      await launchUrl(appleUrl, mode: LaunchMode.externalApplication);
    } else {
      await launchUrl(googleUrl, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: isCheapest
            ? Border.all(color: const Color(0xFF2196F3), width: 1.5)
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header: name + close
            Row(
              children: [
                // Brand logo
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: station.brandColorValue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: station.brandColorValue.withOpacity(0.25)),
                  ),
                  child: Center(
                    child: Text(
                      station.brand.isNotEmpty
                          ? station.brand[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: station.brandColorValue,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              station.name,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A1A2E),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isCheapest)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE3F2FD),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'Cheapest',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1565C0),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.near_me,
                              size: 12, color: Colors.grey[400]),
                          const SizedBox(width: 3),
                          Text(
                            '${station.distance.toStringAsFixed(2)} mi away',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[500]),
                          ),
                          if (station.rating != null) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.star,
                                size: 12, color: Color(0xFFFFC107)),
                            const SizedBox(width: 2),
                            Text(
                              station.rating!.toStringAsFixed(1),
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey[500]),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: onClose,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      shape: BoxShape.circle,
                    ),
                    child:
                        Icon(Icons.close, size: 14, color: Colors.grey[600]),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),

            // Prices + Directions
            Row(
              children: [
                // Fuel prices
                Expanded(
                  child: Row(
                    children: [
                      _MapPricePill(
                          label: '87',
                          price: station.fuelPrices.regular,
                          highlight: isCheapest),
                      const SizedBox(width: 6),
                      _MapPricePill(
                          label: '89', price: station.fuelPrices.midgrade),
                      const SizedBox(width: 6),
                      _MapPricePill(
                          label: '91', price: station.fuelPrices.premium),
                    ],
                  ),
                ),
                // Directions button
                GestureDetector(
                  onTap: _openDirections,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2196F3),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2196F3).withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.directions, size: 14, color: Colors.white),
                        SizedBox(width: 5),
                        Text(
                          'Go',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MapPricePill extends StatelessWidget {
  final String label;
  final double? price;
  final bool highlight;

  const _MapPricePill({
    required this.label,
    this.price,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlight && price != null
            ? const Color(0xFFE3F2FD)
            : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: highlight && price != null
            ? Border.all(color: const Color(0xFF2196F3), width: 1)
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(fontSize: 9, color: Colors.grey[500])),
          Text(
            price != null ? '\$${price!.toStringAsFixed(2)}' : '--',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: highlight && price != null
                  ? const Color(0xFF1565C0)
                  : const Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Legend chip ────────────────────────────────────────────────────────────────

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  final bool filled;
  final bool isUser;

  const _LegendItem({
    required this.color,
    required this.label,
    required this.filled,
    this.isUser = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.08), blurRadius: 6),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: isUser ? BoxShape.circle : BoxShape.circle,
              color: filled ? color : Colors.white,
              border: Border.all(color: color, width: 2),
            ),
          ),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E))),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2196F3)),
        useMaterial3: true,
      ),
      home: const GasStationsScreen(),
    );
  }
}
