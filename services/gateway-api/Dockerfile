# Simple Dockerfile for Gateway API
FROM node:20-alpine AS base
WORKDIR /app
RUN corepack enable
COPY package.json tsconfig.json ./
COPY src ./src
RUN corepack prepare pnpm@9.12.0 --activate && pnpm install && pnpm build

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
ENV NODE_OPTIONS=--dns-result-order=ipv4first
COPY --from=base /app/package.json ./
COPY --from=base /app/dist ./dist
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate && pnpm install --prod
EXPOSE 4000
CMD ["node","dist/main.js"]
