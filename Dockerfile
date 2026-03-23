FROM quay.io/quarkus/ubi-quarkus-graalvmce-builder-image:jdk-25 AS native-build
WORKDIR /app

COPY gradle/ gradle/
COPY gradlew .
COPY build.gradle settings.gradle ./
USER root
RUN chmod +x ./gradlew

RUN ./gradlew --no-daemon --build-cache dependencies --info

COPY src/ src/
RUN ./gradlew --no-daemon --build-cache build \
    -x spotlessJavaApply -x spotlessJava \
    -Dquarkus.native.enabled=true \
    -Dquarkus.package.jar.enabled=false \
    -Dquarkus.native.remote-container-build=false \
    -Dquarkus.native.additional-build-args=-march=compatibility \
    --info
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
WORKDIR /work/
RUN ls 
RUN curl -f -s -o /dev/null -w "Status: %{http_code} for %{url_effective}\n"

RUN microdnf install -y glibc zlib libstdc++ && microdnf clean all

COPY --from=native-build /app/build/*-runner ./

RUN chmod +x ./*-runner

EXPOSE 8080
ENV APP_API_LIMIT=60
ENV APP_API_TIMEOUT=700
ENTRYPOINT ["./quarkus-scaling-demo-1.0.0-SNAPSHOT-runner"]