FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -q
COPY src ./src
RUN mvn package -DskipTests -q

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && \
    curl -sfL https://repo1.maven.org/maven2/co/elastic/otel/elastic-otel-javaagent/1.11.0/elastic-otel-javaagent-1.11.0.jar \
         -o /elastic-otel-javaagent.jar && \
    apt-get remove -y curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/order-service-1.0.0.jar app.jar
ENV OTEL_SERVICE_NAME=order-service \
    OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
    JAVA_TOOL_OPTIONS="-javaagent:/elastic-otel-javaagent.jar"
EXPOSE 8083
ENTRYPOINT ["java", "-jar", "app.jar"]
