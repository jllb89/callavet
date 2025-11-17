import { Controller, Get, Header, Res } from '@nestjs/common';
import { Response } from 'express';
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

function resolveSpecPath(): string {
  // 1. Honor explicit env override first (so that a valid path isn't shadowed by missing candidates)
  if (process.env.OPENAPI_SPEC_PATH) {
    const envPath = process.env.OPENAPI_SPEC_PATH;
    if (existsSync(envPath)) return envPath;
  }

  // 2. Assemble candidate search locations. We include both dev (ts-node) and dist layouts.
  // We purposely repeat a couple resolutions because process.cwd() may be either the service dir or monorepo root
  const candidates: string[] = [];
  const cwd = process.cwd();
  // Derive potential monorepo root by climbing 2 levels (serviceDir/.. => services/.. => repo root)
  // Previous traversal used 3 levels which escaped the repo when running in services/gateway-api
  const maybeRoot = resolve(cwd, '../../');

  const pushUnique = (p: string) => { if (!candidates.includes(p)) candidates.push(p); };

  // canonical name variants we accept
  const names = ['openapi.yaml', 'openapi.yml', 'openapi.json'];
  for (const name of names) {
  // Two-level ascent to repo root from services/<svc>
  pushUnique(resolve(cwd, `../../docs/openapi/${name}`));
    pushUnique(resolve(__dirname, `../../../../docs/openapi/${name}`));
    pushUnique(resolve(__dirname, `../../public/${name}`));
    pushUnique(resolve(maybeRoot, `docs/openapi/${name}`));
    pushUnique(resolve(cwd, `docs/openapi/${name}`));
  }

  for (const p of candidates) {
    if (existsSync(p)) return p;
  }

  // 3. If still not found, emit a debug log with attempted paths for easier diagnosis
  // (Avoid leaking internal absolute paths unless in dev mode)
  const attempted = process.env.NODE_ENV === 'production' ? candidates.map(c => resolve(c).split('/').slice(-3).join('/')) : candidates;
  // Last resort: throw with helpful message
  throw new Error(`OpenAPI spec not found. Set OPENAPI_SPEC_PATH or ensure docs/openapi/openapi.yaml is available. Attempted: ${attempted.join(', ')}`);
}

function tryResolveAlt(name: string): string | null {
  // Allow explicit overrides via env vars
  if (name === 'openapi-chat-ws.yaml' && process.env.OPENAPI_CHAT_WS_SPEC_PATH && existsSync(process.env.OPENAPI_CHAT_WS_SPEC_PATH)) {
    return process.env.OPENAPI_CHAT_WS_SPEC_PATH;
  }
  if (name === 'openapi-webhooks.yaml' && process.env.OPENAPI_WEBHOOKS_SPEC_PATH && existsSync(process.env.OPENAPI_WEBHOOKS_SPEC_PATH)) {
    return process.env.OPENAPI_WEBHOOKS_SPEC_PATH;
  }
  const candidates = [
    resolve(process.cwd(), `../../../docs/openapi/${name}`),
    resolve(__dirname, `../../../../docs/openapi/${name}`),
    // If copied next to dist (covers dist/public and dist/src/public)
    resolve(__dirname, `../../public/${name}`),
    resolve(__dirname, `../../../public/${name}`),
    resolve(__dirname, `../public/${name}`),
    // Variants using cwd
    resolve(process.cwd(), `dist/public/${name}`),
    resolve(process.cwd(), `dist/src/public/${name}`),
    // If copied to app root public
    resolve(process.cwd(), `public/${name}`),
  ];
  for (const p of candidates) if (existsSync(p)) return p;
  return null;
}

@Controller()
export class DocsController {
  @Get('/openapi.yaml')
  @Header('content-type', 'text/yaml; charset=utf-8')
  getSpec() {
    const p = resolveSpecPath();
    return readFileSync(p, 'utf8');
  }

  @Get('/docs')
  @Header('content-type', 'text/html; charset=utf-8')
  getDocsHtml(@Res() res: Response) {
    // Lightweight Redoc hosting via CDN
    const html = `<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Call-a-Vet API Docs</title>
    <style>body { margin: 0; padding: 0; } redoc { height: 100vh; }</style>
  </head>
  <body>
    <redoc spec-url="/openapi.yaml"></redoc>
    <script src="https://cdn.jsdelivr.net/npm/redoc@next/bundles/redoc.standalone.js"></script>
  </body>
</html>`;
    res.status(200).send(html);
  }

  @Get('/openapi-chat-ws.yaml')
  @Header('content-type', 'text/yaml; charset=utf-8')
  getChatWsSpec(@Res() res: Response) {
    const p = tryResolveAlt('openapi-chat-ws.yaml');
    if (!p) return res.status(404).send('Spec not found');
    res.status(200).send(readFileSync(p, 'utf8'));
  }

  @Get('/openapi-webhooks.yaml')
  @Header('content-type', 'text/yaml; charset=utf-8')
  getWebhooksSpec(@Res() res: Response) {
    const p = tryResolveAlt('openapi-webhooks.yaml');
    if (!p) return res.status(404).send('Spec not found');
    res.status(200).send(readFileSync(p, 'utf8'));
  }

  @Get('/docs/chat')
  @Header('content-type', 'text/html; charset=utf-8')
  getChatDocs(@Res() res: Response) {
    const html = `<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Call-a-Vet Chat WS Docs</title>
    <style>body { margin: 0; padding: 0; } redoc { height: 100vh; }</style>
  </head>
  <body>
    <redoc spec-url="/openapi-chat-ws.yaml"></redoc>
    <script src="https://cdn.jsdelivr.net/npm/redoc@next/bundles/redoc.standalone.js"></script>
  </body>
</html>`;
    res.status(200).send(html);
  }

  @Get('/docs/webhooks')
  @Header('content-type', 'text/html; charset=utf-8')
  getWebhooksDocs(@Res() res: Response) {
    const html = `<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Call-a-Vet Webhooks Docs</title>
    <style>body { margin: 0; padding: 0; } redoc { height: 100vh; }</style>
  </head>
  <body>
    <redoc spec-url="/openapi-webhooks.yaml"></redoc>
    <script src="https://cdn.jsdelivr.net/npm/redoc@next/bundles/redoc.standalone.js"></script>
  </body>
</html>`;
    res.status(200).send(html);
  }
}
