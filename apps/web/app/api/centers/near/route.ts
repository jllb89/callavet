import { NextResponse } from 'next/server';

export async function GET() {
	// TODO: implement location-based center lookup
	return NextResponse.json({ message: 'Not implemented' }, { status: 501 });
}
