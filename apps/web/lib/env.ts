// Re-export env helpers from src for legacy alias resolution ("@/lib/env")
export const GATEWAY = process.env.GATEWAY_URL || 'http://localhost:3001';
