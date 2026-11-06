FROM maven:3.9.16-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# Ubuntu 24.04 (noble), pinned explicitly. The default tag moved to Ubuntu 26.04, whose base image adds Canonical's
# pebble service manager: a Go binary this app never runs, built with a Go version that has open HIGH CVEs
# (2026-10-12), which fails the release gate. Same JRE either way.
FROM eclipse-temurin:21.0.12.1_1-jre-noble
# CVE-2026-109518 (HIGH) fails the release gate: the base image has apt 2.8.3, and the fix is 2.8.4ubuntu0.1. This does
# nothing once the base image has the fix, and can go then.
RUN apt-get update   && apt-get install --yes --no-install-recommends --only-upgrade apt libapt-pkg6.0t64   && rm -rf /var/lib/apt/lists/*
# Numeric UID so Kubernetes can verify runAsNonRoot without resolving a username.
RUN useradd --system --uid 10001 --no-create-home storefront
WORKDIR /app
COPY --from=build /src/target/storefront-api-0.1.0.jar app.jar
USER 10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
