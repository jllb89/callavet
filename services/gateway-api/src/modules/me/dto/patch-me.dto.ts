import { IsEmail, IsIn, IsOptional, IsString, Length, Matches, MaxLength } from 'class-validator';

// Simple IANA timezone regex (City/Region); loosened to allow underscores and dashes
const TZ_REGEX = /^(?:[A-Za-z]+(?:_[A-Za-z]+)?\/[A-Za-z0-9_\-]+)$/;
export class PatchMeDto {
  @IsOptional()
  @IsString()
  @MaxLength(120)
  name?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  full_name?: string;

  @IsOptional()
  @IsEmail()
  @MaxLength(255)
  email?: string;

  @IsOptional()
  @IsString()
  @Length(2, 2)
  @Matches(/^[A-Za-z]{2}$/, { message: 'country must be a 2-letter ISO code' })
  country?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  state?: string;

  @IsOptional()
  @IsString()
  @Matches(TZ_REGEX, { message: 'timezone must look like Region/City (e.g. America/Mexico_City)' })
  timezone?: string;

  @IsOptional()
  @IsString()
  @IsIn(['owner', 'caballerango', 'veterinarian', 'trainer', 'ranch_responsible'], {
    message: 'customer_type must be one of: owner, caballerango, veterinarian, trainer, ranch_responsible',
  })
  customer_type?: string;
}
