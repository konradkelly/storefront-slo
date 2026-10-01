FROM maven:3.9.16-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

FROM eclipse-temurin:21.0.12.1_1-jre
# Numeric UID so Kubernetes can verify runAsNonRoot without resolving a username.
RUN useradd --system --uid 10001 --no-create-home storefront
WORKDIR /app
COPY --from=build /src/target/storefront-api-0.1.0.jar app.jar
USER 10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
