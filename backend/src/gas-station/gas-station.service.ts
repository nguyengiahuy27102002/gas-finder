import {
  Injectable,
  Logger,
  ServiceUnavailableException,
  BadRequestException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import axios from 'axios';
import { NearbyQueryDto } from './dto/nearby-query.dto';

// ─── Types ────────────────────────────────────────────────────────────────────

interface GooglePlace {
  place_id: string;
  name: string;
  vicinity: string;
  rating?: number;
  user_ratings_total?: number;
  geometry: { location: { lat: number; lng: number } };
  photos?: Array<{ photo_reference: string }>;
  opening_hours?: { open_now: boolean };
  business_status?: string;
  icon?: string;
}

interface GoogleNearbyResponse {
  status: string;
  results: GooglePlace[];
  error_message?: string;
}

export interface GasStationResult {
  id: string;
  name: string;
  address: string;
  distance: number; // miles, rounded to 2 decimal places
  distanceUnit: string;
  rating: number | null;
  reviewCount: number;
  isOpenNow: boolean | null;
  location: { lat: number; lng: number };
  logoUrl: string | null;     // Google Place photo URL (ready to use in Flutter)
  brand: string;              // Normalized brand name e.g. "Shell", "BP"
  brandColor: string;         // Hex color for brand (fallback when no logo)
  fuelPrices: {
    regular: number | null;
    midgrade: number | null;
    premium: number | null;
  };
  lastUpdated: string;
}

// ─── Brand color map ─────────────────────────────────────────────────────────
// Used in Flutter as a fallback when the Place photo fails to load.

const BRAND_COLORS: Record<string, string> = {
  chevron:    '#0077C8',
  shell:      '#DD1D21',
  bp:         '#007A33',
  marathon:   '#003087',
  mobil:      '#E31837',
  exxon:      '#E31837',
  sunoco:     '#0061A1',
  speedway:   '#CC0000',
  wawa:       '#E31837',
  kwiktrip:   '#D22630',
  citgo:      '#003DA5',
  valero:     '#003DA5',
  phillips66: '#C8102E',
  '76':       '#E36F1E',
  casey:      '#E41E26',
  default:    '#2196F3',
};

function getBrandColor(name: string): string {
  const lower = name.toLowerCase();
  for (const [brand, color] of Object.entries(BRAND_COLORS)) {
    if (lower.includes(brand)) return color;
  }
  return BRAND_COLORS.default;
}

function normalizeBrandName(name: string): string {
  // Strip suffixes like "#123", "& Food Mart", etc.
  return name
    .replace(/#\d+/g, '')
    .replace(/\s+(gas|station|fuel|&.*)/gi, '')
    .trim();
}

// ─── Haversine distance ───────────────────────────────────────────────────────

function haversineDistanceMiles(
  lat1: number, lng1: number,
  lat2: number, lng2: number,
): number {
  const R = 3958.8; // Earth radius in miles
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ─── Mock fuel prices ─────────────────────────────────────────────────────────
// TODO: Replace with a real gas price API (CollectAPI, GasBuddy, etc.)
// The values below are seeded by place_id so they're stable per station.

function mockFuelPrices(placeId: string): {
  regular: number;
  midgrade: number;
  premium: number;
} {
  // Deterministic pseudo-random from place_id characters
  const seed = placeId
    .split('')
    .reduce((acc, ch) => acc + ch.charCodeAt(0), 0);

  const base = 3.09 + (seed % 60) / 100; // $3.09 – $3.68
  return {
    regular:  Math.round(base * 100) / 100,
    midgrade: Math.round((base + 0.20) * 100) / 100,
    premium:  Math.round((base + 0.40) * 100) / 100,
  };
}

// ─── Service ─────────────────────────────────────────────────────────────────

@Injectable()
export class GasStationService {
  private readonly logger = new Logger(GasStationService.name);
  private readonly apiKey: string;
  private readonly placesBaseUrl =
    'https://maps.googleapis.com/maps/api/place';

  constructor(private readonly config: ConfigService) {
    this.apiKey = this.config.get<string>('GOOGLE_PLACES_API_KEY') ?? '';
    if (!this.apiKey) {
      this.logger.warn(
        'GOOGLE_PLACES_API_KEY is not set — all requests will fail. Add it to your .env file.',
      );
    }
  }

  async getNearbyStations(query: NearbyQueryDto): Promise<{
    stations: GasStationResult[];
    meta: object;
  }> {
    if (!this.apiKey) {
      throw new ServiceUnavailableException(
        'Google Places API key is not configured. Set GOOGLE_PLACES_API_KEY in your .env file.',
      );
    }

    const radiusMeters = Math.round(query.radius * 1609.34); // miles → meters

    this.logger.log(
      `Fetching gas stations near (${query.lat}, ${query.lng}) within ${query.radius} mi`,
    );

    let places: GooglePlace[];
    try {
      places = await this.fetchFromGooglePlaces(query.lat, query.lng, radiusMeters);
    } catch (err) {
      this.logger.error(`Google Places API error: ${err.message}`);
      throw new ServiceUnavailableException(
        'Failed to fetch gas stations. Please try again.',
      );
    }

    const stations: GasStationResult[] = places
      .filter((p) => p.business_status !== 'CLOSED_PERMANENTLY')
      .map((place) => {
        const { lat, lng } = place.geometry.location;
        const distance = haversineDistanceMiles(query.lat, query.lng, lat, lng);
        const brand = normalizeBrandName(place.name);
        const prices = mockFuelPrices(place.place_id);

        return {
          id: place.place_id,
          name: place.name,
          address: place.vicinity ?? '',
          distance: Math.round(distance * 100) / 100,
          distanceUnit: 'miles',
          rating: place.rating ?? null,
          reviewCount: place.user_ratings_total ?? 0,
          isOpenNow: place.opening_hours?.open_now ?? null,
          location: { lat, lng },
          logoUrl: place.photos?.[0]
            ? this.buildPhotoUrl(place.photos[0].photo_reference)
            : null,
          brand,
          brandColor: getBrandColor(place.name),
          fuelPrices: {
            regular:  prices.regular,
            midgrade: prices.midgrade,
            premium:  prices.premium,
          },
          lastUpdated: new Date().toISOString(),
        };
      })
      .sort((a, b) => a.distance - b.distance); // closest first

    return {
      stations,
      meta: {
        total: stations.length,
        center: { lat: query.lat, lng: query.lng },
        radiusMiles: query.radius,
        fetchedAt: new Date().toISOString(),
      },
    };
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  private async fetchFromGooglePlaces(
    lat: number,
    lng: number,
    radiusMeters: number,
  ): Promise<GooglePlace[]> {
    const url = `${this.placesBaseUrl}/nearbysearch/json`;
    const params = {
      location: `${lat},${lng}`,
      radius: radiusMeters,
      type: 'gas_station',
      key: this.apiKey,
    };

    const response = await axios.get<GoogleNearbyResponse>(url, {
      params,
      timeout: 8000,
    });

    const { status, results, error_message } = response.data;

    if (status === 'REQUEST_DENIED') {
      throw new Error(`Google API denied: ${error_message}`);
    }
    if (status === 'OVER_QUERY_LIMIT') {
      throw new Error('Google API quota exceeded');
    }
    if (status === 'ZERO_RESULTS') {
      return [];
    }
    if (status !== 'OK') {
      throw new Error(`Google API returned status: ${status}`);
    }

    return results;
  }

  /**
   * Builds a ready-to-use Google Places photo URL.
   * Flutter can load this directly in Image.network() or CachedNetworkImage.
   */
  private buildPhotoUrl(photoReference: string): string {
    return (
      `${this.placesBaseUrl}/photo` +
      `?maxwidth=200` +
      `&photoreference=${photoReference}` +
      `&key=${this.apiKey}`
    );
  }
}
