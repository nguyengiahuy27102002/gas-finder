# CLAUDE.md — DashMateAI: Nearby Gas Stations + Fuel Prices

> Engineering guide for AI agents and developers building this feature.
> Treat this as law. Every decision here exists for a reason.

---

## 1. Feature Overview

### What We Are Building

A screen inside DashMateAI that shows the user nearby gas stations with real-time fuel prices for Regular (87), Mid-grade (89), and Premium (91/92/93). Users can switch between a map view and a list view, sort by price, and filter by fuel type.

### Business Value

Fuel is one of the top recurring costs for drivers. Showing prices within a 2–5 mile radius, sorted cheapest first, gives users a direct, tangible reason to open the app daily. This is a retention and engagement driver, not just a utility feature.

### UX Goal

Fast. Simple. Actionable.

- Load in under 2 seconds on 4G
- No more than 2 taps to find the cheapest nearby station
- Price must be the dominant visual element on each card
- The user should never wonder what to do next

---

## 2. System Architecture

### High-Level Data Flow

```
User GPS → Flutter App → DashMateAI Backend → External Gas Price API
                                            ↓
                              Redis Cache (5–10 min TTL)
                                            ↓
                              Normalized Response → Flutter App → UI
```

Never call external APIs directly from Flutter. All external calls go through the backend. This enforces security, caching, and normalization in one place.

---

### Frontend (Flutter)

**Location:**
- Use `geolocator` package for GPS coordinates
- Request `locationWhenInUse` permission on first launch
- Fall back gracefully if permission is denied (show a city-level search input)
- Do not poll GPS more than once per 30 seconds unless the user manually refreshes

**Map Integration:**
- Use `google_maps_flutter` or `flutter_map` (OpenStreetMap-based, no billing)
- Display station markers on the map
- Tap a marker → expand the bottom card to show that station's details
- Keep map and list in sync via shared state

**UI Layout (3-zone design):**
```
┌─────────────────────────────┐
│  Search bar + Filter chips  │  ← Zone 1: Controls
├─────────────────────────────┤
│                             │
│         Map View            │  ← Zone 2: Map (collapsible)
│                             │
├─────────────────────────────┤
│  Scrollable Station List    │  ← Zone 3: List
└─────────────────────────────┘
```

The map is collapsible. List-only mode is the default on smaller screens.

---

### Backend (Node.js — NestJS)

**Module:** `GasStationModule`

**Responsibilities:**
- Accept lat/lng/radius from Flutter
- Query external gas price API (CollectAPI, GasBuddy API, or Google Places + price enrichment)
- Normalize response into a consistent schema
- Cache result in Redis by `{lat_rounded}:{lng_rounded}:{radius}:{fuelType}` key
- Return clean, validated JSON

**External API Options (pick one, abstract it behind a service interface):**

| API | Pros | Cons |
|-----|------|------|
| CollectAPI Gas Prices | Real prices, easy REST | Paid, US-focused |
| GasBuddy (unofficial) | Most accurate crowd data | TOS risk, unstable |
| Google Places + scraping | Reliable station data | No prices natively |
| OpenChargeMap (EV only) | Free | Not relevant here |

Recommendation: Use **CollectAPI** for MVP. Abstract behind `IGasPriceProvider` interface so you can swap providers without touching the controller or consumer code.

---

## 3. API Design

### Endpoint

```
GET /gas-stations/nearby
```

### Query Parameters

| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `lat` | float | Yes | User latitude |
| `lng` | float | Yes | User longitude |
| `radius` | int | No | Search radius in miles. Default: 5. Max: 25 |
| `fuelType` | string | No | `regular`, `midgrade`, `premium`. Omit for all |
| `sortBy` | string | No | `price` or `distance`. Default: `distance` |
| `limit` | int | No | Max results. Default: 20. Max: 50 |

### Success Response — 200 OK

```json
{
  "stations": [
    {
      "id": "station_abc123",
      "name": "Shell",
      "address": "1234 Main St, Houston, TX 77001",
      "distance": 0.8,
      "distanceUnit": "miles",
      "fuelPrices": {
        "regular": 3.29,
        "midgrade": 3.49,
        "premium": 3.69
      },
      "lastUpdated": "2026-04-08T14:30:00Z",
      "location": {
        "lat": 29.7604,
        "lng": -95.3698
      },
      "brand": "Shell",
      "amenities": ["restroom", "atm", "carwash"]
    }
  ],
  "meta": {
    "total": 14,
    "radius": 5,
    "center": { "lat": 29.7604, "lng": -95.3698 },
    "cachedAt": "2026-04-08T14:28:00Z"
  }
}
```

### Error Responses

```json
// 400 — Invalid params
{
  "statusCode": 400,
  "error": "Bad Request",
  "message": ["lat must be a valid latitude", "lng must be a valid longitude"]
}

// 503 — External API down
{
  "statusCode": 503,
  "error": "Service Unavailable",
  "message": "Gas price data temporarily unavailable. Showing cached results.",
  "cachedAt": "2026-04-08T14:00:00Z"
}

// 429 — Rate limited
{
  "statusCode": 429,
  "error": "Too Many Requests",
  "message": "Slow down. Retry after 10 seconds.",
  "retryAfter": 10
}
```

### Validation Rules

- `lat` must be between -90 and 90
- `lng` must be between -180 and 180
- `radius` must be a positive integer, max 25
- `fuelType` must be one of: `regular`, `midgrade`, `premium`
- `sortBy` must be one of: `price`, `distance`
- All prices in the response must be positive floats or `null` (never 0, never negative)
- `lastUpdated` must be a valid ISO 8601 timestamp

### Rate Limiting

- 60 requests per minute per IP
- 10 requests per minute per authenticated user against the external API (cache reduces this in practice)
- Use `@nestjs/throttler` with Redis store

---

## 4. Backend Implementation

### Module Structure

```
src/
  gas-station/
    gas-station.module.ts
    gas-station.controller.ts
    gas-station.service.ts
    gas-station.repository.ts        ← optional, for DB caching
    dto/
      nearby-query.dto.ts
      gas-station-response.dto.ts
    interfaces/
      gas-price-provider.interface.ts
      gas-station.interface.ts
    providers/
      collect-api.provider.ts        ← external API adapter
    cache/
      gas-station-cache.service.ts
```

### DTO — `nearby-query.dto.ts`

```typescript
import { IsLatitude, IsLongitude, IsOptional, IsInt, Min, Max, IsEnum } from 'class-validator';
import { Type } from 'class-transformer';

export enum FuelType {
  REGULAR = 'regular',
  MIDGRADE = 'midgrade',
  PREMIUM = 'premium',
}

export enum SortBy {
  PRICE = 'price',
  DISTANCE = 'distance',
}

export class NearbyQueryDto {
  @IsLatitude()
  @Type(() => Number)
  lat: number;

  @IsLongitude()
  @Type(() => Number)
  lng: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(25)
  @Type(() => Number)
  radius: number = 5;

  @IsOptional()
  @IsEnum(FuelType)
  fuelType?: FuelType;

  @IsOptional()
  @IsEnum(SortBy)
  sortBy: SortBy = SortBy.DISTANCE;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(50)
  @Type(() => Number)
  limit: number = 20;
}
```

### Controller — `gas-station.controller.ts`

```typescript
import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { NearbyQueryDto } from './dto/nearby-query.dto';
import { GasStationService } from './gas-station.service';

@Controller('gas-stations')
export class GasStationController {
  constructor(private readonly gasStationService: GasStationService) {}

  @Get('nearby')
  @Throttle({ default: { limit: 60, ttl: 60000 } })
  async getNearby(@Query() query: NearbyQueryDto) {
    return this.gasStationService.getNearbyStations(query);
  }
}
```

### Service — `gas-station.service.ts`

```typescript
import { Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';
import { NearbyQueryDto } from './dto/nearby-query.dto';
import { GasStationCacheService } from './cache/gas-station-cache.service';
import { CollectApiProvider } from './providers/collect-api.provider';
import { normalizeStations } from './utils/normalize-stations';

@Injectable()
export class GasStationService {
  private readonly logger = new Logger(GasStationService.name);

  constructor(
    private readonly cache: GasStationCacheService,
    private readonly provider: CollectApiProvider,
  ) {}

  async getNearbyStations(query: NearbyQueryDto) {
    const cacheKey = this.buildCacheKey(query);
    const cached = await this.cache.get(cacheKey);

    if (cached) {
      this.logger.debug(`Cache hit: ${cacheKey}`);
      return cached;
    }

    let raw;
    try {
      raw = await this.provider.fetchNearby(query);
    } catch (err) {
      this.logger.error(`External API failed: ${err.message}`);
      const stale = await this.cache.getStale(cacheKey);
      if (stale) return { ...stale, stale: true };
      throw new ServiceUnavailableException('Gas price data temporarily unavailable.');
    }

    const normalized = normalizeStations(raw, query);
    await this.cache.set(cacheKey, normalized, 600); // 10-minute TTL
    return normalized;
  }

  private buildCacheKey(query: NearbyQueryDto): string {
    const latR = query.lat.toFixed(2);
    const lngR = query.lng.toFixed(2);
    return `gas:${latR}:${lngR}:${query.radius}:${query.fuelType ?? 'all'}`;
  }
}
```

### Provider Interface — `gas-price-provider.interface.ts`

```typescript
export interface IGasPriceProvider {
  fetchNearby(query: NearbyQueryDto): Promise<RawStationData[]>;
}
```

Always code against this interface. Never instantiate a provider class directly in the service.

### Retry Logic

Use `axios-retry` or a custom interceptor on the HTTP client:

```typescript
import axiosRetry from 'axios-retry';

axiosRetry(axiosInstance, {
  retries: 3,
  retryDelay: axiosRetry.exponentialDelay,
  retryCondition: (err) => axiosRetry.isNetworkOrIdempotentRequestError(err),
});
```

### Normalization

```typescript
// utils/normalize-stations.ts
export function normalizeStations(raw: RawStationData[], query: NearbyQueryDto): NormalizedResponse {
  const stations = raw
    .map((s) => ({
      id: s.id ?? s.place_id ?? generateStableId(s),
      name: s.name ?? s.station_name ?? 'Unknown Station',
      address: s.address ?? s.formatted_address ?? '',
      distance: parseFloat(s.distance ?? '0'),
      distanceUnit: 'miles',
      fuelPrices: {
        regular: parsePriceOrNull(s.regular ?? s.price_regular),
        midgrade: parsePriceOrNull(s.midgrade ?? s.price_midgrade),
        premium: parsePriceOrNull(s.premium ?? s.price_premium),
      },
      lastUpdated: s.updated_at ?? s.last_updated ?? new Date().toISOString(),
      location: {
        lat: parseFloat(s.lat ?? s.latitude),
        lng: parseFloat(s.lng ?? s.longitude),
      },
    }))
    .filter((s) => s.location.lat && s.location.lng);

  return { stations, meta: buildMeta(stations, query) };
}

function parsePriceOrNull(val: unknown): number | null {
  const n = parseFloat(String(val));
  return isFinite(n) && n > 0 ? n : null;
}
```

---

## 5. Frontend Implementation (Flutter)

### Package Dependencies

```yaml
# pubspec.yaml additions
dependencies:
  geolocator: ^11.0.0
  google_maps_flutter: ^2.6.0   # or flutter_map: ^6.0.0
  flutter_riverpod: ^2.5.0
  dio: ^5.4.0
  cached_network_image: ^3.3.0
  shimmer: ^3.0.0               # loading skeletons
```

### File Structure

```
lib/
  features/
    gas_stations/
      data/
        gas_station_repository.dart
        gas_station_api_client.dart
        models/
          gas_station.dart
          fuel_prices.dart
      domain/
        gas_station_notifier.dart
        gas_station_state.dart
      presentation/
        gas_stations_screen.dart
        widgets/
          station_card.dart
          station_map.dart
          filter_bar.dart
          price_badge.dart
```

### State — `gas_station_state.dart`

```dart
import 'package:freezed_annotation/freezed_annotation.dart';
import '../data/models/gas_station.dart';

part 'gas_station_state.freezed.dart';

@freezed
class GasStationState with _$GasStationState {
  const factory GasStationState.initial() = _Initial;
  const factory GasStationState.loading() = _Loading;
  const factory GasStationState.loaded({
    required List<GasStation> stations,
    required bool isMapView,
    required String? activeFuelFilter,
    required String sortBy,
  }) = _Loaded;
  const factory GasStationState.error(String message) = _Error;
}
```

### Notifier — `gas_station_notifier.dart`

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../data/gas_station_repository.dart';
import 'gas_station_state.dart';

final gasStationProvider = StateNotifierProvider<GasStationNotifier, GasStationState>((ref) {
  return GasStationNotifier(ref.read(gasStationRepositoryProvider));
});

class GasStationNotifier extends StateNotifier<GasStationState> {
  final GasStationRepository _repo;

  GasStationNotifier(this._repo) : super(const GasStationState.initial());

  Future<void> load({String? fuelType, String sortBy = 'distance'}) async {
    state = const GasStationState.loading();
    try {
      final position = await _getLocation();
      final stations = await _repo.getNearby(
        lat: position.latitude,
        lng: position.longitude,
        fuelType: fuelType,
        sortBy: sortBy,
      );
      state = GasStationState.loaded(
        stations: stations,
        isMapView: false,
        activeFuelFilter: fuelType,
        sortBy: sortBy,
      );
    } catch (e) {
      state = GasStationState.error(e.toString());
    }
  }

  Future<Position> _getLocation() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) throw Exception('Location services are disabled.');

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission denied.');
      }
    }
    return Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
  }

  void toggleView() {
    state.mapOrNull(
      loaded: (s) => state = s.copyWith(isMapView: !s.isMapView),
    );
  }
}
```

### Screen — `gas_stations_screen.dart`

```dart
class GasStationsScreen extends ConsumerStatefulWidget {
  const GasStationsScreen({super.key});

  @override
  ConsumerState<GasStationsScreen> createState() => _GasStationsScreenState();
}

class _GasStationsScreenState extends ConsumerState<GasStationsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(gasStationProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(gasStationProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            const FilterBar(),
            state.when(
              initial: () => const SizedBox.shrink(),
              loading: () => const _LoadingSkeleton(),
              loaded: (stations, isMapView, filter, sortBy) => Expanded(
                child: isMapView
                    ? StationMap(stations: stations)
                    : _StationList(stations: stations),
              ),
              error: (msg) => _ErrorView(message: msg, onRetry: () {
                ref.read(gasStationProvider.notifier).load();
              }),
            ),
          ],
        ),
      ),
    );
  }
}
```

### Station Card — `station_card.dart`

```dart
class StationCard extends StatelessWidget {
  final GasStation station;
  final bool isCheapest;

  const StationCard({required this.station, this.isCheapest = false, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isCheapest ? const Color(0xFFE8F4FD) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCheapest ? const Color(0xFF2196F3) : const Color(0xFFE0E0E0),
          width: isCheapest ? 1.5 : 1,
        ),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(station.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              Text('${station.distance.toStringAsFixed(1)} mi',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            ],
          ),
          const SizedBox(height: 4),
          Text(station.address, style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          const SizedBox(height: 12),
          Row(
            children: [
              PriceBadge(label: '87', price: station.fuelPrices.regular),
              const SizedBox(width: 8),
              PriceBadge(label: '89', price: station.fuelPrices.midgrade),
              const SizedBox(width: 8),
              PriceBadge(label: '91', price: station.fuelPrices.premium),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Updated ${_formatTime(station.lastUpdated)}',
            style: TextStyle(color: Colors.grey[400], fontSize: 11),
          ),
        ],
      ),
    );
  }
}
```

### Price Badge — `price_badge.dart`

```dart
class PriceBadge extends StatelessWidget {
  final String label;
  final double? price;

  const PriceBadge({required this.label, this.price, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: price != null ? const Color(0xFFF0F7FF) : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          const SizedBox(height: 2),
          Text(
            price != null ? '\$${price!.toStringAsFixed(2)}' : '--',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: price != null ? const Color(0xFF1565C0) : Colors.grey[400],
            ),
          ),
        ],
      ),
    );
  }
}
```

---

## 6. Geolocation Handling

### Permission Flow

```
App launch
  └─ Check if location services enabled
       ├─ No → Show "Enable Location" dialog with Settings deeplink
       └─ Yes → Check permission status
                 ├─ granted → fetch location
                 ├─ denied → request permission
                 │             ├─ granted → fetch location
                 │             └─ denied → show manual city input
                 └─ deniedForever → show Settings deeplink only
```

### Implementation Rules

- Never call `getCurrentPosition` more than once per 30 seconds
- Cache the last known position in the notifier; reuse it for filter/sort changes
- If position age < 5 minutes, use cached position (avoid repeated GPS drain)
- On Android, declare `ACCESS_FINE_LOCATION` in `AndroidManifest.xml`
- On iOS, add `NSLocationWhenInUseUsageDescription` in `Info.plist` — write a clear human-readable reason

### Fallback

If location is denied, show a text input: "Enter your city or ZIP code" and resolve it to lat/lng using a geocoding call on the backend before hitting the gas station endpoint.

---

## 7. Performance & Scalability

### Caching Strategy

```
Client-side:
  - Cache last successful response in Riverpod state
  - Persist to local storage (Hive or SharedPreferences) for cold-start display
  - Invalidate after 10 minutes or on manual refresh

Server-side:
  - Redis TTL: 600 seconds (10 minutes) per location bucket
  - Round lat/lng to 2 decimal places for cache key (~1.1km grid)
  - Keep stale cache (TTL: 1 hour) as fallback when external API fails
```

### Request Throttling

- Debounce map pan events — don't refetch until pan stops for 800ms
- Minimum 30-second interval between automatic background refreshes
- Explicit pull-to-refresh always works immediately

### Radius & Pagination

- Default radius: 5 miles
- Maximum radius: 25 miles (enforce in DTO and external API query)
- Maximum results per page: 50 (enforce in DTO)
- If external API returns >50 results, slice and sort server-side before responding

### External API Cost Control

- Cache aggressively — external APIs charge per call
- Track monthly call count; alert at 80% of quota
- For MVP, CollectAPI free tier handles ~100 calls/day; upgrade plan before beta launch

---

## 8. AI Agent Behavior Rules

### MUST

- Write every class, method, and DTO with a single responsibility
- Validate all external API responses before passing them to the normalization layer — never assume field names or value types
- Handle null and missing prices explicitly (`null`, never `0` or empty string)
- Log external API calls with response time, status code, and cache outcome
- Use dependency injection everywhere — no `new Provider()` inside service classes
- Write the provider interface before the concrete implementation
- Keep the Flutter UI layer dumb — no business logic in widgets, ever
- Return typed response objects, never raw `Map<String, dynamic>` from repositories
- Freeze all state models with `freezed` in Flutter

### MUST NOT

- Call external APIs from Flutter directly
- Hardcode API keys in source code — use environment variables (`.env` via `--dart-define` or `envied` package)
- Return `200 OK` with an error message in the body — use correct HTTP status codes
- Skip the cache layer to "simplify" the implementation
- Use `dynamic` types in Dart unless absolutely necessary and documented
- Swallow exceptions silently — every catch must log and either rethrow or return a typed error
- Mix map rendering logic with state management logic
- Fetch fresh data on every widget rebuild

---

## 9. UI/UX Standards

### Theme

```dart
// Use DashMateAI's existing theme
Primary:   Color(0xFF2196F3)  // Light blue
Secondary: Color(0xFF1565C0)  // Dark blue (prices, highlights)
Background: Colors.white
Surface:    Color(0xFFF5F9FF)
Error:      Color(0xFFD32F2F)
Text primary:   Color(0xFF1A1A2E)
Text secondary: Color(0xFF6B7280)
```

### Visual Rules

- Cheapest station card: blue border + light blue background tint
- Cheapest price badge: bold + slightly larger font
- Missing prices: show `--` in muted grey, never hide the badge entirely
- Distance: always show one decimal place (e.g., `1.2 mi`)
- Prices: always show two decimal places (e.g., `$3.29`)
- Last updated: use relative time for < 1 hour (e.g., "Updated 8 min ago"), absolute time beyond that
- Loading state: use shimmer skeleton cards, not a spinner
- Error state: show a message + retry button, never a blank screen

### Information Hierarchy (per card)

1. Station name (most prominent)
2. Fuel prices (second most prominent — this is why they're here)
3. Distance
4. Address
5. Last updated (smallest, grey)

---

## 10. Integration Instructions

### Backend Integration

1. Create `src/gas-station/` module inside the existing NestJS project
2. Import `GasStationModule` into `AppModule`
3. Register Redis cache in `AppModule` if not already present:
   ```typescript
   CacheModule.registerAsync({
     imports: [ConfigModule],
     useFactory: (config: ConfigService) => ({
       store: redisStore,
       host: config.get('REDIS_HOST'),
       port: config.get('REDIS_PORT'),
     }),
     inject: [ConfigService],
   })
   ```
4. Add `COLLECT_API_KEY` to `.env` and `ConfigService` schema
5. Add throttler to the module if not globally configured
6. Mount the new route — it will be available at `GET /api/gas-stations/nearby`

### Flutter Integration

1. Add the new screen under `lib/features/gas_stations/`
2. Register the route in your existing router:
   ```dart
   // If using GoRouter:
   GoRoute(
     path: '/gas-stations',
     builder: (context, state) => const GasStationsScreen(),
   )
   ```
3. Add a navigation entry point (bottom nav tab, home screen card, or drawer item — match existing app navigation pattern)
4. Add the `GasStationRepository` provider to the Riverpod provider scope — no changes to existing providers needed
5. Add `geolocator` permissions to `AndroidManifest.xml` and `Info.plist` if not already declared

### Environment Variables to Add

```bash
# Backend .env
COLLECT_API_KEY=your_key_here
REDIS_HOST=localhost
REDIS_PORT=6379

# Flutter (via --dart-define or .env via envied)
API_BASE_URL=https://api.dashmate.ai/v1
```

---

## 11. Future Improvements

These are planned, not current scope. Do not build them now. Do not add hooks or abstractions for them speculatively.

### Near-term
- **Favorite stations:** Save a station to a user profile. Backend: add `FavoriteStation` entity with user FK. Flutter: heart icon on card.
- **Price alerts:** Notify user when a saved station drops below a threshold. Requires backend job (cron) + push notification integration.
- **Station reviews:** Pull Google Places reviews for the selected station.

### Mid-term
- **AI price prediction:** Use historical price data (stored in DB over time) to predict tomorrow's prices per station. Flag "prices likely to rise" in the UI.
- **Route-aware suggestions:** When the user has an active route, show gas stations along the route sorted by price + detour cost.

### Long-term
- **Crowdsourced prices:** Let users report prices. Build a moderation layer. Weight fresh user-reports over API data.
- **Fleet mode:** Multi-vehicle tracking with fuel cost logging per fill-up.

---

## Quick Reference Checklist

Before marking any task as complete, verify:

**Backend**
- [ ] DTO validation covers all params with proper types and bounds
- [ ] External API errors are caught and return correct HTTP status
- [ ] Stale cache is served when external API is down
- [ ] Redis key is deterministic and collision-free
- [ ] Normalization handles null/missing prices with `null`, not `0`
- [ ] Retry logic is in place with exponential backoff
- [ ] Rate limiting is applied to the endpoint
- [ ] No API key is hardcoded in source

**Flutter**
- [ ] Location permission is requested with a clear rationale string
- [ ] Location denial shows a meaningful fallback (not a crash or blank screen)
- [ ] Loading state uses shimmer skeletons
- [ ] Error state shows a retry button
- [ ] Cheapest station is visually distinct
- [ ] Missing prices show `--`, not `$0.00` or empty
- [ ] No business logic inside widget `build` methods
- [ ] State models are `freezed`
- [ ] API key is not in source code

**Both**
- [ ] Works on slow 3G (test with network throttling)
- [ ] Works with no results returned (empty state handled)
- [ ] Works when all fuel prices are null for a station

---

*This document is the source of truth for this feature. When in doubt, re-read it before writing code.*
