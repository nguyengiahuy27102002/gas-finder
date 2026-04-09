import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { GasStationModule } from './gas-station/gas-station.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      envFilePath: '.env',
    }),
    GasStationModule,
  ],
})
export class AppModule {}
