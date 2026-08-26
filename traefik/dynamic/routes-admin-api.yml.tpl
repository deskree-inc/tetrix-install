# admin-api / licensing routes (tetrix-admin-api). Rendered by scripts/setup.sh.
# SPA calls /api/licensing/*; admin-api mounts those handlers under /v1/* (Helm twin:
# tetrixaidb-rewrite-licensing replacePathRegex).
http:
  middlewares:
    # Helm twin: tetrixaidb-rewrite-licensing — SPA /api/licensing/* → admin-api /v1/*.
    rewrite-licensing:
      replacePathRegex:
        regex: "^/api/licensing/(.*)"
        replacement: "/v1/$1"

  routers:
    admin-api-licensing:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/api/licensing`)"
      entryPoints:
        - websecure
      priority: 90
      middlewares:
        - strip-identity
        - auth
        - rewrite-licensing
      service: admin-api
      tls: {}

    # serveAdminRoutes=true (Helm default): /api/admin → admin-api. /api/config stays on remote.
    admin-api-admin:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/api/admin`)"
      entryPoints:
        - websecure
      priority: 90
      middlewares:
        - strip-identity
        - auth
      service: admin-api
      tls: {}

    # GET /system/health edge OVERRIDE — the compose twin of Helm's
    # templates/ingress-system-health.yaml (ADR-0010, gateway#37, chart#210/#211,
    # this repo's #248). WITHOUT it the prefix route below wins and the SPA's
    # System-health card renders admin-api's PARTIAL aggregate: two rows
    # (admin-api + licensing) and no `version` field at all, instead of the
    # verifier's full nine-row one. #245 mirrored the gateway's health REGISTRY
    # into compose but not this route, so the registry was configured and
    # nothing here ever called it.
    #
    # Priority must be strictly above admin-api-system's 90 or Path() never
    # beats PathPrefix(`/system/`). 95 matches Helm's
    # ingress.systemHealth.routePriority default, where a _helpers.tpl `fail`
    # enforces the same relationship; here the two numbers are literals in one
    # file, and scripts/assert-system-health-override.sh asserts the ordering.
    #
    # Both slash forms, because Path() is exact (helm-chart#211 review): without
    # `/system/health/` the trailing-slash request would fall through to the
    # prefix rule and answer from a different backend than its sibling.
    #
    # EVERY other /system/* path (e.g. /system/smtp, /system/embedding) keeps
    # falling through to admin-api below — those are live SPA surfaces.
    #
    # Unlike Helm this is not staged behind an enable flag. That flag exists for
    # the multi-pod rollout race (repin the gateway, roll it out, THEN flip the
    # route); compose ships this file and the gateway image pin in the same
    # commit onto one node, so there is no window to stage. The pin is the
    # precondition: the handler exists only from sha-866bc35 (see this repo's
    # docker-compose.yml gateway image comment).
    system-health:
      rule: "Host(`${TETRIX_HOST}`) && (Path(`/system/health`) || Path(`/system/health/`))"
      entryPoints:
        - websecure
      priority: 95
      middlewares:
        - strip-identity
        - auth
      service: gateway-verifier
      tls: {}

    admin-api-system:
      rule: "Host(`${TETRIX_HOST}`) && PathPrefix(`/system/`)"
      entryPoints:
        - websecure
      priority: 90
      middlewares:
        - strip-identity
        - auth
      service: admin-api
      tls: {}

  services:
    admin-api:
      loadBalancer:
        servers:
          - url: "http://admin-api:8000"
    # The verifier's own port (the same 4181 the `auth` forwardAuth middleware
    # in routes.yml.tpl already talks to) — its third role beside verify and
    # licensing-gate is serving this aggregate.
    gateway-verifier:
      loadBalancer:
        servers:
          - url: "http://gateway:4181"
