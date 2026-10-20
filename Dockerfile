# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS flutter-sdk
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git unzip xz-utils zip libglu1-mesa libglib2.0-0 libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
ARG FLUTTER_REVISION=d3abd00e69a89a615e13969c02832ef1e0119639
RUN git init /opt/flutter && git -C /opt/flutter remote add origin https://github.com/flutter/flutter.git \
    && git -C /opt/flutter fetch --depth 1 origin "$FLUTTER_REVISION" \
    && git -C /opt/flutter checkout --detach FETCH_HEAD
ENV PATH=/opt/flutter/bin:$PATH CI=true
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /src/frontend
COPY frontend/pubspec.yaml frontend/pubspec.lock ./
COPY frontend/packages/rrule ./packages/rrule
RUN flutter pub get --enforce-lockfile
COPY frontend/ ./

FROM flutter-sdk AS frontend-test
RUN flutter analyze && flutter test

FROM flutter-sdk AS frontend-build
RUN flutter build web --release --no-pub --no-web-resources-cdn

FROM golang:1.27.3-bookworm AS backend-source
WORKDIR /src/backend
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./

FROM backend-source AS backend-test
RUN go test -race ./... && go vet ./...

FROM backend-source AS backend-build
RUN CGO_ENABLED=0 go build -tags timetzdata -trimpath -ldflags='-s -w' -o /out/spacetime .

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
WORKDIR /app
COPY --from=backend-build /out/spacetime /app/spacetime
COPY --from=frontend-build /src/frontend/build/web /app/web
ENV ADDR=0.0.0.0:8080 DATA_FILE=/data/spacetime.db STATIC_DIR=/app/web COOKIE_SECURE=1
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/app/spacetime"]
