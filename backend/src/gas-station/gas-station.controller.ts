import { Controller, Get, Query, HttpCode, HttpStatus } from '@nestjs/common';
import { GasStationService } from './gas-station.service';
import { NearbyQueryDto } from './dto/nearby-query.dto';

@Controller('gas-stations')
export class GasStationController {
  constructor(private readonly service: GasStationService) {}

  /**
   * GET /api/gas-stations/nearby?lat=25.77&lng=-80.19&radius=5
   *
   * Returns all gas stations near the provided coordinates,
   * sorted by distance (closest first).
   */
  @Get('nearby')
  @HttpCode(HttpStatus.OK)
  async getNearby(@Query() query: NearbyQueryDto) {
    return this.service.getNearbyStations(query);
  }

  /**
   * GET /api/gas-stations/health
   * Quick liveness check — useful during dev to confirm the server is up.
   */
  @Get('health')
  health() {
    return { status: 'ok', timestamp: new Date().toISOString() };
  }
}
