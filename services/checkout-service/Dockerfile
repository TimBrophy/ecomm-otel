# --------------------------------------------------------------------------- #
# Stage 1 — build                                                             #
# --------------------------------------------------------------------------- #
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

# Copy POM first so Maven dependency resolution is cached as a separate layer.
# Re-running mvn dependency:go-offline only when pom.xml changes saves minutes
# on subsequent builds.
COPY pom.xml .
RUN mvn dependency:go-offline -q

COPY src ./src
RUN mvn package -DskipTests -q

# --------------------------------------------------------------------------- #
# Stage 2 — runtime                                                           #
# --------------------------------------------------------------------------- #
FROM eclipse-temurin:21-jre
WORKDIR /app

# Download the EDOT Java agent.
# The agent is attached via JAVA_TOOL_OPTIONS below; the application code itself
# has no SDK dependency — instrumentation is purely automatic.
RUN apt-get update && apt-get install -y --no-install-recommends curl && \
    curl -sfL https://repo1.maven.org/maven2/co/elastic/otel/elastic-otel-javaagent/1.11.0/elastic-otel-javaagent-1.11.0.jar \
         -o /elastic-otel-javaagent.jar && \
    apt-get remove -y curl && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/target/checkout-service-1.0.0.jar app.jar

# OTEL_SERVICE_NAME   — appears as service.name in every span/metric/log
# OTEL_EXPORTER_OTLP_PROTOCOL — use gRPC (collector must expose port 4317)
# OTEL_EXPORTER_OTLP_ENDPOINT — override at runtime to point at the EDOT collector
# JAVA_TOOL_OPTIONS   — JVM picks this up automatically; attaches the agent before
#                       Spring Boot's own class loading begins
ENV OTEL_SERVICE_NAME=checkout-service \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317 \
    JAVA_TOOL_OPTIONS="-javaagent:/elastic-otel-javaagent.jar"

EXPOSE 8082

ENTRYPOINT ["java", "-jar", "app.jar"]
