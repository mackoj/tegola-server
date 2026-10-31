# Build: the Swift image, a release build with the Swift runtime linked in statically.
FROM swift:6.4-noble AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY api api
COPY Sources Sources
RUN swift build -c release --static-swift-stdlib --product tegola-server \
  && cp "$(swift build -c release --show-bin-path)/tegola-server" /tegola-server

# Run: a slim Ubuntu with CA certificates and nothing else, as an unprivileged user (DECISIONS D-10).
FROM ubuntu:noble
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin tegola
COPY --from=build /tegola-server /usr/local/bin/tegola-server
USER 10001:10001
# In a container the server listens on all interfaces of its own network namespace; only the reverse proxy reaches
# it. TEGOLA_APP_ID has no default: the server refuses to start without it.
ENV TEGOLA_HOST=0.0.0.0 TEGOLA_PORT=8080 TEGOLA_ENVIRONMENT=production TEGOLA_TRUSTED_PROXY_HOPS=1
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/tegola-server"]
