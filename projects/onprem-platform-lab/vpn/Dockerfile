# Minimal WireGuard gateway
FROM alpine:3.20
RUN apk add --no-cache wireguard-tools iptables iproute2 curl iputils
COPY --chmod=755 start.sh /start.sh
CMD ["/start.sh"]
