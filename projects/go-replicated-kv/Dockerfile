# Build a static binary with the standard library only, then copy it into
# a distroless image that has no shell and runs as a non-root user.
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/kvnode ./cmd/kvnode \
 && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/kvnode /kvnode
# A named volume mounted here takes this ownership, so the non-root user
# can write the WAL.
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
ENV KV_DATA_DIR=/data \
    KV_LISTEN=:8080 \
    KV_PEER_LISTEN=:7070 \
    KV_ADMIN_LISTEN=:6060
EXPOSE 8080 7070 6060
HEALTHCHECK --interval=5s --timeout=3s --retries=3 CMD ["/kvnode", "-probe", "http://127.0.0.1:8080/healthz"]
ENTRYPOINT ["/kvnode"]
