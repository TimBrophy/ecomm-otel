FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y librdkafka-dev gcc && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir setuptools && \
    pip install --no-cache-dir -r requirements.txt
COPY . .
ENV OTEL_SERVICE_NAME=notification-service \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_PYTHON_LOG_CORRELATION=true
EXPOSE 8084
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8084"]
