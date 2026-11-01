# syntax=docker/dockerfile:1
# The production image (DECISIONS D-10, D-16). Build: `docker build -t tegola-server .`
# Behind a TLS-intercepting proxy (some CI or cloud sandboxes), pass its CA as a build secret; it is used only to fetch
# the Swift packages and never reaches the image:
#   docker build --secret id=proxy_ca,src=/path/to/ca.pem --build-arg HTTPS_PROXY=… -t tegola-server .

# Build: the Swift image, a release build with the Swift runtime linked in statically.
FROM swift:6.4-noble@sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0 AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN --mount=type=secret,id=proxy_ca,required=false \
  if [ -s /run/secrets/proxy_ca ]; then \
    export GIT_SSL_CAINFO=/run/secrets/proxy_ca SSL_CERT_FILE=/run/secrets/proxy_ca; \
  fi; \
  swift package resolve
COPY api api
COPY Sources Sources
# The manifest declares the test targets too; their sources stay in this stage.
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib --product tegola-server \
  && cp "$(swift build -c release --show-bin-path)/tegola-server" /tegola-server

# Run: a slim Ubuntu with CA certificates (for the lookup sources, M3) and nothing else, as an unprivileged user.
FROM ubuntu:noble@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin tegola
COPY --from=build /tegola-server /usr/local/bin/tegola-server
USER 10001:10001
# In a container the server listens on all interfaces of its own network namespace; only the reverse proxy reaches
# it. TEGOLA_APP_ID has no default: the server refuses to start without it. One proxy (Caddy) appends the client's
# address to X-Forwarded-For; docker-compose.yml sets that. The image itself trusts no X-Forwarded-For, so run on its
# own it can't be told a client's address by the client (D-19).
ENV TEGOLA_HOST=0.0.0.0 TEGOLA_PORT=8080 TEGOLA_ENVIRONMENT=production TEGOLA_TRUSTED_PROXY_HOPS=0
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/tegola-server"]
