# Multi-stage build for the Spring Boot demo app
FROM maven:3.9.9-eclipse-temurin-17 AS sources
WORKDIR /workspace
COPY pom.xml .
COPY src ./src

# Tests run in Docker with: docker compose run --build --rm test
FROM sources AS test
CMD ["mvn", "-B", "test"]

FROM sources AS build
RUN mvn -q -DskipTests package

FROM eclipse-temurin:17-jre AS runtime
WORKDIR /app
COPY --from=build /workspace/target/demo-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]

# Faulty canary: every 2nd /hello-world request returns HTTP 500.
FROM runtime AS bad
ENV APP_VERSION=v2 FAILURE_EVERY=2

# Healthy default (also used by infra/scripts when --target is omitted).
FROM runtime AS good
ENV APP_VERSION=v1 FAILURE_EVERY=0
