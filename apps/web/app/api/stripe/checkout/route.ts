import { NextResponse } from 'next/server';

export async function POST(){
	// TODO: integrate Stripe checkout session creation
	return NextResponse.json({ message: 'Stripe checkout not implemented' }, { status: 501 });
}
