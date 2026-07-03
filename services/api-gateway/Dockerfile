FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY . .
ENV OTEL_SERVICE_NAME=api-gateway \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    NODE_OPTIONS="--require ./tracing.js"
EXPOSE 8080
CMD ["node", "index.js"]
