# Keycloak + Weaviate Lab

## Services

| Service   | Host URL                        | Notes                        |
|-----------|---------------------------------|------------------------------|
| Keycloak  | http://localhost:8081           | Admin: admin / admin         |
| Weaviate  | http://localhost:8080           | gRPC: localhost:50051        |

Keycloak is accessible as `host.docker.internal:8081` from both the host and inside Docker containers (required so the JWT issuer URL matches on both sides).

## Known Gotchas (Keycloak 26)

1. **"Account is not fully set up"** — Keycloak 26 marks `firstName`, `lastName`, and `email` as required for the `user` role in the User Profile. Users without these fields cannot log in via ROPC. Fix: remove `required` from those attributes via the admin API or UI (Realm settings → User profile).

2. **`expected audience "weaviate" got ["account"]`** — Keycloak does not include the client ID in the `aud` claim by default. Fix: add an Audience mapper to the client (`oidc-audience-mapper`, `included.client.audience=weaviate`).

3. **Groups not appearing in JWT** — Keycloak does not emit group memberships by default. Fix: add a Group Membership mapper (`oidc-group-membership-mapper`, `claim.name=groups`, `full.path=true`). With `full.path=true`, groups appear as `/SpecialCollections` (with leading slash) — this is what must be used in Weaviate role assignments.

4. **Issuer URL mismatch** — Tokens issued via `localhost:8081` will have `iss: http://localhost:8081/...` but Weaviate expects the issuer set in `AUTHENTICATION_OIDC_ISSUER`. Fix: set `KC_HOSTNAME_URL=http://host.docker.internal:8081` in Keycloak so the issuer is always consistent.

---

## Troubleshooting Commands

All commands assume Keycloak is on `localhost:8081` and the realm is `weaviate`.

### Get an admin token

```bash
ADMIN_TOKEN=$(curl -s -X POST "http://localhost:8081/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

### Get a user token and inspect claims

```bash
curl -s -X POST "http://localhost:8081/realms/weaviate/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=weaviate&username=<USERNAME>&password=<PASSWORD>" \
  | python3 -c "
import sys, json, base64
r = json.load(sys.stdin)
if 'access_token' in r:
    payload = r['access_token'].split('.')[1]
    payload += '=' * (4 - len(payload) % 4)
    claims = json.loads(base64.b64decode(payload))
    print('preferred_username:', claims.get('preferred_username'))
    print('groups:', claims.get('groups'))
    print('aud:', claims.get('aud'))
    print('iss:', claims.get('iss'))
else:
    print('ERROR:', r.get('error'), '-', r.get('error_description'))
"
```

### Inspect a user account (required actions, enabled state)

```bash
curl -s "http://localhost:8081/admin/realms/weaviate/users?username=<USERNAME>" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -m json.tool
```

### Check user credentials

```bash
USER_ID="<UUID>"
curl -s "http://localhost:8081/admin/realms/weaviate/users/$USER_ID/credentials" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "import sys,json; [print('type:', c['type'], '| temporary:', c.get('temporary')) for c in json.load(sys.stdin)]"
```

### Check client configuration

```bash
curl -s "http://localhost:8081/admin/realms/weaviate/clients?clientId=weaviate" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "
import sys, json
c = json.load(sys.stdin)[0]
print('directAccessGrantsEnabled:', c.get('directAccessGrantsEnabled'))
print('publicClient:', c.get('publicClient'))
print('enabled:', c.get('enabled'))
"
```

### List protocol mappers on the client

```bash
CLIENT_UUID=$(curl -s "http://localhost:8081/admin/realms/weaviate/clients?clientId=weaviate" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

curl -s "http://localhost:8081/admin/realms/weaviate/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "
import sys, json
for m in json.load(sys.stdin):
    print(m['name'], '-', m['protocolMapper'])
"
```

### Check User Profile required attributes

```bash
curl -s "http://localhost:8081/admin/realms/weaviate/users/profile" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "
import sys, json
for a in json.load(sys.stdin).get('attributes', []):
    print(a['name'], '| required:', a.get('required'))
"
```

### Fix "Account is not fully set up" (set firstName/lastName on a user)

```bash
USER_ID="<UUID>"
curl -s -X PUT "http://localhost:8081/admin/realms/weaviate/users/$USER_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"firstName": "First", "lastName": "Last"}' \
  -w "\nHTTP status: %{http_code}\n"
```

### Add Audience mapper (fixes aud claim)

```bash
CLIENT_UUID="<UUID>"
curl -s -X POST "http://localhost:8081/admin/realms/weaviate/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "weaviate-audience",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-audience-mapper",
    "config": {
      "included.client.audience": "weaviate",
      "id.token.claim": "false",
      "access.token.claim": "true"
    }
  }' -w "\nHTTP status: %{http_code}\n"
```

### Add Group Membership mapper (fixes missing groups claim)

```bash
CLIENT_UUID="<UUID>"
curl -s -X POST "http://localhost:8081/admin/realms/weaviate/clients/$CLIENT_UUID/protocol-mappers/models" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "weaviate-groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
      "claim.name": "groups",
      "full.path": "true",
      "id.token.claim": "false",
      "access.token.claim": "true",
      "userinfo.token.claim": "false"
    }
  }' -w "\nHTTP status: %{http_code}\n"
```

### Check realm default required actions and email verification

```bash
curl -s "http://localhost:8081/admin/realms/weaviate" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  | python3 -c "
import sys, json
r = json.load(sys.stdin)
print('defaultRequiredActions:', r.get('defaultRequiredActions'))
print('verifyEmail:', r.get('verifyEmail'))
"
```

### List groups in realm

```bash
curl -s "http://localhost:8081/admin/realms/weaviate/groups" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | python3 -m json.tool
```

### Add a user to a group

```bash
USER_ID="<USER_UUID>"
GROUP_ID="<GROUP_UUID>"
curl -s -X PUT "http://localhost:8081/admin/realms/weaviate/users/$USER_ID/groups/$GROUP_ID" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -w "\nHTTP status: %{http_code}\n"
```
