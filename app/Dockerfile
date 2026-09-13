# Multi-stage build for the Spring Boot demo app
FROM maven:3.9.9-eclipse-temurin-17 AS build
WORKDIR /workspace
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package

FROM eclipse-temurin:17-jre
WORKDIR /app
# 0 = good; bad image is built with --build-arg DEMO_DELAY_MS=1500
ARG DEMO_DELAY_MS=0
ENV DEMO_DELAY_MS=${DEMO_DELAY_MS}
COPY --from=build /workspace/target/demo-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
