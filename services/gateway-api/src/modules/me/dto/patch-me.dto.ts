import { IsOptional, IsString, MaxLength, Matches } from 'class-validator';

// Simple IANA timezone regex (City/Region); loosened to allow underscores and dashes
const TZ_REGEX = /^(?:[A-Za-z]+(?:_[A-Za-z]+)?\/[A-Za-z0-9_\-]+)$/;
export class PatchMeDto {
  @IsOptional()
  @IsString()
  @MaxLength(120)
  name?: string;

  @IsOptional()
  @IsString()
  @Matches(TZ_REGEX, { message: 'timezone must look like Region/City (e.g. America/Mexico_City)' })
  timezone?: string;
}
