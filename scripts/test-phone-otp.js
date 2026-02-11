/**
 * End-to-end Phone OTP test (staging):
 * 1) Requests OTP
 * 2) Prompts for the code
 * 3) Verifies and obtains session
 * 4) Calls Gateway /me with the bearer token
 *
 * Required env vars (source .env.staging, then set the missing ones):
 * - SUPABASE_URL
 * - SUPABASE_ANON_KEY
 * - GATEWAY_URL (will be used as API_BASE_URL)
 * - TEST_PHONE_NUMBER (E.164, e.g., +15555550123)
 */

import readline from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import { createClient } from '@supabase/supabase-js';

async function main() {
  const url = process.env.SUPABASE_URL;
  const anonKey = process.env.SUPABASE_ANON_KEY;
  const apiBase = process.env.API_BASE_URL || process.env.GATEWAY_URL;
  const phone = process.env.TEST_PHONE_NUMBER;

  if (!url || !anonKey || !apiBase || !phone) {
    throw new Error('Missing env: SUPABASE_URL, SUPABASE_ANON_KEY, API_BASE_URL/GATEWAY_URL, TEST_PHONE_NUMBER');
  }

  const supabase = createClient(url, anonKey);
  console.log(`Requesting OTP for ${phone}...`);
  const { error: sendErr } = await supabase.auth.signInWithOtp({ phone });
  if (sendErr) throw sendErr;
  console.log('OTP sent. Check your phone.');

  const rl = readline.createInterface({ input, output });
  const token = (await rl.question('Enter the 6-digit code: ')).trim();
  rl.close();

  console.log('Verifying OTP...');
  const { data, error: verifyErr } = await supabase.auth.verifyOtp({
    phone,
    token,
    type: 'sms',
  });
  if (verifyErr) throw verifyErr;

  const accessToken = data.session?.access_token;
  if (!accessToken) throw new Error('No access token returned');

  console.log('Calling /me with bearer token...');
  const resp = await fetch(`${apiBase}/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const body = await resp.json().catch(() => ({}));
  console.log('Status:', resp.status);
  console.log('Body:', JSON.stringify(body, null, 2));
}

main().catch((err) => {
  console.error('Test failed:', err);
  process.exit(1);
});
