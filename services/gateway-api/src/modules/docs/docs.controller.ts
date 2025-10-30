import { Controller, Get, Header, Res } from '@nestjs/common';
import { Response } from 'express';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';

function resolveSpecPath(): string {
  // Try a few likely locations both in dev (ts) and prod (dist)
  const candidates = [
    // Monorepo root relative from service dir (dev)
    resolve(process.cwd(), '../../../docs/openapi/openapi.yaml'),
    // From compiled dist directory
    resolve(__dirname, '../../../../docs/openapi/openapi.yaml'),
    // If copied as an asset alongside dist
    resolve(__dirname, '../../public/openapi.yaml'),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  // Fallback: try env-provided
  if (process.env.OPENAPI_SPEC_PATH && existsSync(process.env.OPENAPI_SPEC_PATH)) {
    return process.env.OPENAPI_SPEC_PATH;
  }
  // Last resort: throw with helpful message
  throw new Error('OpenAPI spec not found. Set OPENAPI_SPEC_PATH or ensure docs/openapi/openapi.yaml is available.');
}

function tryResolveAlt(name: string): string | null {
  const candidates = [
    resolve(process.cwd(), `../../../docs/openapi/${name}`),
    resolve(__dirname, `../../../../docs/openapi/${name}`),
    resolve(__dirname, `../../public/${name}`),
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
