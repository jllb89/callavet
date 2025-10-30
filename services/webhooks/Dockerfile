# Simple Dockerfile for Webhooks service
FROM node:20-alpine AS base
WORKDIR /app
RUN corepack enable
COPY package.json tsconfig.json ./
COPY src ./src
RUN corepack prepare pnpm@9.12.0 --activate && pnpm install && pnpm build

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=base /app/package.json ./
COPY --from=base /app/dist ./dist
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate && pnpm install --prod
EXPOSE 4200
CMD ["node","dist/index.js"]
