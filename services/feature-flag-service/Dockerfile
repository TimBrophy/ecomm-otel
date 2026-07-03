FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY . .
ENV OTEL_SERVICE_NAME=feature-flag-service \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    NODE_OPTIONS="--require ./tracing.js"
EXPOSE 8090
CMD ["node", "index.js"]
