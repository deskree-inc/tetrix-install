# Tetrix dynamic TLS — TEMPLATE. Rendered by scripts/render-traefik-tls.sh to
# ${TETRIX_TRAEFIK_DIR}/dynamic/tls.yml.
#
# self_signed  the certificate block below, exactly as local development has
#              always had it (setup.sh generates certs/cert.pem + key.pem).
# acme         no certificate path at all — Traefik's letsencrypt resolver owns
#              the certificate and stores it in /acme/acme.json. A leftover
#              certFile here would be served in preference to the ACME cert and
#              every browser would see the self-signed one.
#
# The ACME branch still renders a real (non-empty) document: the file provider
# watches this directory, and a file that parses to null is a configuration
# error rather than "no TLS overrides".
#@TLS_BLOCK@
