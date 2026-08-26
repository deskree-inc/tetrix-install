# Tetrix edge static configuration — TEMPLATE. Rendered by
# scripts/render-traefik-tls.sh (called from scripts/setup.sh) to
# ${TETRIX_TRAEFIK_DIR}/traefik.yml, which is what compose bind-mounts.
#
# ONE template serves both TLS modes. There is no cloud-only Traefik file,
# because two edge configurations means the mode a developer tests is not the
# mode a tenant runs. The two `#@…@` markers below are the entire difference:
#
#   TETRIX_TLS_MODE=self_signed  both markers are removed. TLS comes from the
#                                dynamic tls.yml certificate block.
#   TETRIX_TLS_MODE=acme         the markers become the letsencrypt resolver and
#                                the entrypoint that uses it. Cloud only, and
#                                only for a *.tetrix.deskree.com host.
#
# The markers are separate on purpose: the resolver is a top-level key and the
# certResolver belongs INSIDE websecure. Appending one `entryPoints:` block to
# another would be a duplicate YAML key, and the last one wins — silently
# dropping :80/:443 and taking the edge down.
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
#@WEBSECURE_TLS@

providers:
  file:
    directory: /etc/traefik/dynamic
    watch: true

# No dashboard. A single-tenant VM has no operator UI at the edge, and an
# exposed dashboard is a complete inventory of every route on the box.
api:
  dashboard: false

# /ping on the traefik entrypoint, so `traefik healthcheck --ping` works. That
# is what both the compose healthcheck and health-gate.sh use — Traefik has no
# other self-probe that does not require the dashboard.
ping: {}

log:
  level: INFO
#@ACME_RESOLVER@
