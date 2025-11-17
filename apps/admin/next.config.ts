import type { NextConfig } from "next";
import path from "path";
import dotenv from "dotenv";

// Load root .env first, then local app .env files so app-specific values can override
dotenv.config({ path: path.resolve(__dirname, "../../.env") });
dotenv.config();

const nextConfig: NextConfig = {
  /* config options here */
  env: {
    // Expose safe client envs. Prefer NEXT_PUBLIC_* if provided; fall back to server-side names where safe.
    NEXT_PUBLIC_SUPABASE_URL:
      process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL || "",
    NEXT_PUBLIC_SUPABASE_ANON_KEY:
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || process.env.SUPABASE_ANON_KEY || "",
    NEXT_PUBLIC_GATEWAY_URL: process.env.NEXT_PUBLIC_GATEWAY_URL || "",
  },
};

export default nextConfig;
