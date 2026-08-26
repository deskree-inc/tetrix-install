# Audit logs panel read path (ADR-0013 / gateway ADR-0009). Rendered by scripts/setup.sh.
# PathPrefix(/api/audit) → strip-identity → forwardAuth → rewrite-api-audit → audit-logs:8090
http:
  middlewares:
    rewrite-api-audit:
      replacePathRegex:
        regex: "^/api/audit(.*)"
        replacement: "/v1$1"

  routers:
    audit-logs:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/api/audit`)"
      entryPoints:
        - websecure
      priority: 100
      middlewares:
        - strip-identity
        - auth
        - rewrite-api-audit
      service: audit-logs
      tls: {}

  services:
    audit-logs:
      loadBalancer:
        servers:
          - url: "http://audit-logs:8090"
