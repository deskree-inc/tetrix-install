http:
  middlewares:
    strip-identity:
      headers:
        customRequestHeaders:
          X-Tetrix-User-Id: ""
          X-Tetrix-Org-Id: ""
          X-Tetrix-Role: ""
          X-Tetrix-Platform-Role: ""
          X-Tetrix-Username: ""
          # Audit interim trusted headers (gateway ADR-0009 / architecture ADR-0013).
          X-Audit-User-Id: ""
          X-Audit-Org-Id: ""
          X-Audit-Role: ""
          X-Audit-Platform-Role: ""
    # ADR-0012 D3: Collectors API keeps client X-Tetrix-Org-Id (membership-validated
    # in-service). Do not blank/re-stamp Org-Id from the daemon session.
    strip-identity-collectors:
      headers:
        customRequestHeaders:
          X-Tetrix-User-Id: ""
          X-Tetrix-Role: ""
          X-Tetrix-Platform-Role: ""
          X-Tetrix-Username: ""
          X-Audit-User-Id: ""
          X-Audit-Org-Id: ""
          X-Audit-Role: ""
          X-Audit-Platform-Role: ""
    auth:
      forwardAuth:
        address: "http://gateway:4181/verify"
        trustForwardHeader: true
        authResponseHeaders:
          - X-Tetrix-User-Id
          - X-Tetrix-Org-Id
          - X-Tetrix-Role
          - X-Tetrix-Platform-Role
          - X-Tetrix-Username
          - X-Audit-User-Id
          - X-Audit-Org-Id
          - X-Audit-Role
          - X-Audit-Platform-Role
    auth-collectors:
      forwardAuth:
        address: "http://gateway:4181/verify"
        trustForwardHeader: true
        authResponseHeaders:
          - X-Tetrix-User-Id
          - X-Tetrix-Role
          - X-Tetrix-Platform-Role
          - X-Tetrix-Username
          - X-Audit-User-Id
          - X-Audit-Role
          - X-Audit-Platform-Role
    mcp-strip:
      stripPrefix:
        prefixes:
          - /mcp

  routers:
    # Path-based IdP (Helm twin) — never forwardAuth the IdP itself.
    keycloak:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/auth`)"
      entryPoints:
        - websecure
      priority: 230
      service: keycloak
      tls: {}

    # SPA static/boot assets — no forwardAuth (docs/PUBLIC_SPA_PATHS.md).
    # Cover both root-basename images (/) and /app-basename Keycloak images.
    frontend-static:
      rule: "Host(`${TETRIX_HOST}`) && (Path(`/theme-boot.js`) || Path(`/favicon.svg`) || Path(`/config.json`) || PathPrefix(`/assets/`) || PathPrefix(`/fonts/`) || PathPrefix(`/brand/`) || Path(`/app/theme-boot.js`) || Path(`/app/favicon.svg`) || Path(`/app/config.json`) || PathPrefix(`/app/assets/`) || PathPrefix(`/app/fonts/`) || PathPrefix(`/app/brand/`))"
      entryPoints:
        - websecure
      priority: 200
      service: frontend
      tls: {}

    # /app shell for images baked with VITE_BASE=/app/ (no strip — nginx serves /app/*).
    frontend-app:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/app`)"
      entryPoints:
        - websecure
      priority: 50
      middlewares:
        - strip-identity
        - auth
      service: frontend
      tls: {}

    # Root SPA catch-all (excludes API/MCP/PRM/IdP). Prefer root-basename frontend images.
    frontend:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/`) && !PathPrefix(`/api`) && !PathPrefix(`/hooks`) && !Path(`/mcp`) && !PathPrefix(`/mcp/`) && !PathPrefix(`/.well-known`) && !PathPrefix(`/auth`) && !PathPrefix(`/app`)"
      entryPoints:
        - websecure
      priority: 40
      middlewares:
        - strip-identity
        - auth
      service: frontend
      tls: {}

    # Legacy remote BFF still serves /api/* that are not collectors/admin (e.g. /api/config).
    remote-api:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/api`) && !PathPrefix(`/api/v1`) && !PathPrefix(`/api/licensing`) && !PathPrefix(`/api/audit`)"
      entryPoints:
        - websecure
      priority: 60
      middlewares:
        - strip-identity
        - auth
      service: remote-ui
      tls: {}

  services:
    keycloak:
      loadBalancer:
        servers:
          - url: "http://keycloak:8080"
    frontend:
      loadBalancer:
        servers:
          # Overridable for host-Vite local dev (frontend-local.sh sets FRONTEND_UPSTREAM).
          - url: "${FRONTEND_UPSTREAM}"
    remote-ui:
      loadBalancer:
        servers:
          - url: "http://remote:9091"
