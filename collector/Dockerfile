FROM docker.elastic.co/elastic-agent/elastic-agent:9.0.0
# Run as otelcol mode — EDOT ships the OTel collector binary
USER root
COPY otel-collector.yaml /etc/otel/otel-collector.yaml
ENV ELASTIC_AGENT_OTEL=true
EXPOSE 4317 4318 13133
CMD ["otelcol", "--config=/etc/otel/otel-collector.yaml"]
