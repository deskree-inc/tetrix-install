http:
  routers:
    # ADR-0012 D3: retain SPA X-Tetrix-Org-Id on Collectors API (membership-validated
    # in-pod). Hooks keep the full strip-identity → auth chain.
    collectors-api:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/api/v1`)"
      entryPoints:
        - websecure
      middlewares:
        - strip-identity-collectors
        - auth-collectors
      service: collectors-api
      tls: {}
    # helm#448: /api/v1/internal/* (POST /api/v1/internal/infra-events, the shared-secret
    # sink for the Kubernetes infra-events watcher) is in-cluster only. Rewritten to a path
    # collectors-api does not serve, so the edge gets a plain 404. Priority beats the
    # /api/v1 router above (file-provider default priority = rule length). Twin of the helm
    # IngressRoute <fullname>-collectors-internal-deny.
    collectors-internal-deny:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/api/v1/internal`)"
      entryPoints:
        - websecure
      middlewares:
        - collectors-internal-deny
      service: collectors-api
      priority: 10000
      tls: {}
    collectors-hooks:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/hooks`)"
      entryPoints:
        - websecure
      middlewares:
        - strip-identity
        - auth
      service: collectors-api
      tls: {}
    # RFC 9728 PRM discovery — must reach collectors-mcp (gateway policy allowlists
    # the path; middlewares retained per ADR-0007 / helm#49).
    collectors-prm:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/.well-known/oauth-protected-resource`)"
      entryPoints:
        - websecure
      middlewares:
        - strip-identity
        - auth
      service: collectors-mcp
      priority: 100
      tls: {}
    # /mcp is an OAuth 2.x resource server (collectors-mcp validates the Keycloak bearer +
    # graph:read scope itself), so it must NOT sit behind the daemon-token forwardAuth ('auth')
    # — that rejects OAuth bearers as non-dat_ tokens and swallows the RFC 9728 challenge.
    # Only strip-identity (X-Tetrix-* anti-spoofing) remains. Mirrors the helm ingress
    # (tetrixaidb.gateway.mcpMiddlewareNames). ADR-0007 topology.
    collectors-mcp-exact:
      rule: "Host(`${TETRIX_HOST}`) && Path(`/mcp`)"
      entryPoints:
        - websecure
      middlewares:
        - strip-identity
      service: collectors-mcp
      priority: 100
      tls: {}
    collectors-mcp-prefix:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/mcp/`)"
      entryPoints:
        - websecure
      middlewares:
        - strip-identity
        - mcp-strip
      service: collectors-mcp
      priority: 100
      tls: {}

  middlewares:
    collectors-internal-deny:
      replacePath:
        path: /__tetrix/not-routed

  services:
    collectors-api:
      loadBalancer:
        servers:
          - url: "http://collectors-api:8080"
    collectors-mcp:
      loadBalancer:
        servers:
          - url: "http://collectors-mcp:8090"
