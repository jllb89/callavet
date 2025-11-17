// Basic middleware placeholder to satisfy Next.js build until proxy migration.
// TODO: Replace with /proxy routes per Next 16 migration guide.
import { NextResponse, NextRequest } from 'next/server';

export function middleware(_req: NextRequest) {
	// Add future auth / logging here.
	return NextResponse.next();
}

// Optionally limit matcher if needed:
// export const config = { matcher: ['/((?!_next|static).*)'] };
