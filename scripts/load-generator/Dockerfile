FROM node:24-bookworm-slim AS builder
WORKDIR /loadgen
COPY package.json ./
RUN npm install --ignore-scripts --no-audit --no-fund
COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

FROM builder AS test
CMD ["node", "--test", "dist/load.test.js"]

FROM node:24-bookworm-slim
WORKDIR /loadgen
COPY --from=builder --chown=node:node /loadgen/package.json ./
COPY --from=builder --chown=node:node /loadgen/dist/load.js ./dist/load.js
USER node
CMD ["node", "dist/load.js"]
