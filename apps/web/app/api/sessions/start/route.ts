import { NextResponse } from 'next/server';
import { GATEWAY } from '../../../../lib/env';

export async function POST(req: Request){
	const body = await req.json().catch(()=>({}));
	const r = await fetch(`${GATEWAY}/sessions/start`, {
		method: 'POST',
		headers: { 'content-type':'application/json' },
		body: JSON.stringify(body)
	});
	const data = await r.json().catch(()=>({}));
	return NextResponse.json(data, { status: r.status });
}
