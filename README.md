# Weaviate + Keycloak Lab

A local lab for testing Weaviate OIDC authentication and RBAC with Keycloak 26, including a TLS variant that exercises both `AUTHENTICATION_OIDC_CERTIFICATE` and `INSECURE_SKIP_OIDC_TLS_VERIFY` with a self-signed certificate.

## Services

| Service   | URL                                    | Notes                        |
|-----------|----------------------------------------|------------------------------|
| Keycloak  | http://localhost:8081                  | Admin: `admin` / `admin`     |
| Keycloak  | https://host.docker.internal:8443      | TLS stack only               |
| Weaviate  | http://localhost:8080                  | gRPC: `localhost:50051`      |

> **Mac / Rancher Desktop** — add `127.0.0.1 host.docker.internal` to `/etc/hosts` so the Keycloak issuer URL resolves identically inside and outside Docker.

---

## Repository layout

```
.
├── docker-compose.yml          # Plain HTTP stack (Keycloak + Weaviate)
├── docker-compose-tls.yml      # HTTPS stack (self-signed cert)
├── certs/
│   └── generate.sh             # Generates CA + Keycloak server cert
└── run.ipynb                   # Interactive lab notebook
```

---

## Quick start — HTTP (plain)

```bash
# 1. Start Keycloak
docker compose up -d keycloak

# 2. Run the notebook to configure Keycloak and start Weaviate
#    Open run.ipynb and execute cells top-to-bottom.
```

---

## Quick start — HTTPS (self-signed certificate)

Two modes are available for trusting a self-signed Keycloak certificate:

| Mode | Env var | Image requirement |
|------|---------|-------------------|
| **A** | `AUTHENTICATION_OIDC_CERTIFICATE=<PEM>` | Any stable release |
| **B** | `INSECURE_SKIP_OIDC_TLS_VERIFY=true` | Preview build from [PR #10813](https://github.com/weaviate/weaviate/pull/10813) |

`docker-compose-tls.yml` defaults to **Mode B**. To switch to Mode A, comment out `INSECURE_SKIP_OIDC_TLS_VERIFY` and uncomment `AUTHENTICATION_OIDC_CERTIFICATE` in the compose file.

This section walks through **Mode A** (`AUTHENTICATION_OIDC_CERTIFICATE`), which works with any stable Weaviate release.

### 1. Generate certificates

```bash
mkdir -p certs
bash certs/generate.sh
```

Output files in `certs/`:

| File            | Purpose                                              |
|-----------------|------------------------------------------------------|
| `ca.pem`        | CA certificate — passed to `AUTHENTICATION_OIDC_CERTIFICATE` |
| `server.pem`    | Keycloak TLS certificate (signed by the CA)          |
| `server-key.pem`| Keycloak TLS private key                             |

The server cert has SANs for `host.docker.internal`, `localhost`, and `127.0.0.1`.

### 2. Start the TLS stack

The CA PEM must be injected so docker-compose can substitute `${AUTHENTICATION_OIDC_CERTIFICATE}`. This keeps the cert in sync every time Step 1 regenerates it:

```bash
export AUTHENTICATION_OIDC_CERTIFICATE=$(cat certs/ca.pem)
docker compose -f docker-compose-tls.yml --project-name weaviate-tls up -d
```

> When running via the notebook, the Step 2 cell handles the env injection automatically — no manual export needed.

Weaviate starts with:
- `AUTHENTICATION_OIDC_ISSUER=https://host.docker.internal:8443/realms/weaviate`
- `AUTHENTICATION_OIDC_CERTIFICATE=<inline CA PEM>`

### 3. Run the TLS notebook cells

Open `run.ipynb` and scroll to the **"TLS / Self-Signed Certificate Test"** section. Execute the cells in order:

| Step | What it does |
|------|--------------|
| 1    | Generates certs (same as the shell command above) |
| 2    | Tears down any previous TLS stack and starts a fresh one |
| 3    | Polls until Keycloak HTTPS and Weaviate are healthy |
| 4    | Configures Keycloak realm, client, mappers, users, and groups (idempotent) |
| 5    | Creates RBAC roles and collections via the Weaviate API key |
| 6    | **Negative test** — confirms the cert is not trusted without the CA |
| 7    | Fetches an OIDC token over HTTPS → passes it to Weaviate as a Bearer token |
| 8    | Asserts RBAC still scopes `newuser` to `Special*` collections only |
| 9    | Confirms Mode B (`INSECURE_SKIP_OIDC_TLS_VERIFY=true`) is active on the running container |
| 10   | Tears down the TLS stack |

### 4. Tear down

```bash
docker compose -f docker-compose-tls.yml --project-name weaviate-tls down -v
```

---

## How `AUTHENTICATION_OIDC_CERTIFICATE` works

Weaviate's OIDC middleware accepts three formats for the env var value:

| Format          | Example                              |
|-----------------|--------------------------------------|
| HTTPS URL       | `https://internal.ca/ca.pem`         |
| S3 URI          | `s3://my-bucket/ca.pem`              |
| Inline PEM      | `-----BEGIN CERTIFICATE-----\n...`  |

The inline PEM format is what this lab uses. Weaviate builds a custom `http.Client` with the CA loaded into a `x509.CertPool` (min TLS 1.2), which it uses for all requests to the OIDC issuer (discovery, JWKS, etc.).

---

## `INSECURE_SKIP_OIDC_TLS_VERIFY` — Mode B

[weaviate#10813](https://github.com/weaviate/weaviate/pull/10813) adds `INSECURE_SKIP_OIDC_TLS_VERIFY=true` as an alternative to `AUTHENTICATION_OIDC_CERTIFICATE`. When set, Weaviate skips TLS certificate verification for all requests to the OIDC issuer (discovery, JWKS, token introspection).

**This env var requires the preview image from that PR:**
```
semitechnologies/weaviate:preview-implements-insecure-skip-oidc-tls-verify-d0626f9.arm64
```

Once the PR merges, the feature ships in a stable release and any image will work.

### How it differs from Mode A

```
Mode A — AUTHENTICATION_OIDC_CERTIFICATE
  Weaviate builds a custom http.Client with the CA loaded into a x509.CertPool.
  Keycloak's certificate is verified against that CA. Secure.

Mode B — INSECURE_SKIP_OIDC_TLS_VERIFY
  Weaviate sets InsecureSkipVerify=true on the TLS config.
  No certificate verification at all. Simple, but vulnerable to MITM.
```

### When to use Mode B

- Local dev / CI environments where managing and rotating a CA cert is impractical
- Testing Weaviate OIDC flows behind an internal proxy with a corp cert
- When you cannot (or do not want to) rebuild the container to inject a CA PEM

**Do not use Mode B in production.**

### Switching between modes in `docker-compose-tls.yml`

```yaml
# Mode A (stable releases) — inject CA via env before running compose:
#   export AUTHENTICATION_OIDC_CERTIFICATE=$(cat certs/ca.pem)
# - AUTHENTICATION_OIDC_CERTIFICATE

# Mode B (preview image only):
- INSECURE_SKIP_OIDC_TLS_VERIFY=true
```

---

## Known Keycloak 26 gotchas

1. **"Account is not fully set up"** — `firstName`, `lastName`, and `email` are required by default in the User Profile. The notebook removes these requirements automatically.

2. **`expected audience "weaviate" got ["account"]`** — Keycloak doesn't include the client ID in `aud` by default. The notebook adds an `oidc-audience-mapper`.

3. **Groups not in JWT** — Add an `oidc-group-membership-mapper` with `full.path=true`. Groups appear as `/SpecialCollections` (with a leading slash) — use that exact string in Weaviate role assignments.

4. **Issuer URL mismatch** — `KC_HOSTNAME_URL` must match `AUTHENTICATION_OIDC_ISSUER` exactly, including scheme (`http` vs `https`) and port.

---

## Users and credentials

| User         | Password  | Role          | Group               |
|--------------|-----------|---------------|---------------------|
| `admin-user` | `test`    | RBAC root     | —                   |
| `newuser`    | `newuser` | —             | `/SpecialCollections` |

API key: `root-user-key` (maps to `admin-user`).

`newuser` can read `Special*` collections only, via the `special-collections-role` assigned to the `/SpecialCollections` group.
