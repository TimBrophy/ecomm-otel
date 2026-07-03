FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build
RUN npm prune --omit=dev
ENV OTEL_SERVICE_NAME=storefront \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    NODE_OPTIONS="--require ./tracing.js"
EXPOSE 3000
CMD ["node", "index.js"]
