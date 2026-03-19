#!/usr/bin/env bash
# Generates a self-signed CA + Keycloak server certificate for local TLS testing.
# Output files (all in the same directory as this script):
#   ca.pem         — CA certificate (trust anchor; pass to AUTHENTICATION_OIDC_CERTIFICATE)
#   ca-key.pem     — CA private key (keep secret, not needed by Weaviate)
#   server.pem     — Keycloak server certificate (signed by the CA)
#   server-key.pem — Keycloak server private key
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Generating CA key and self-signed certificate..."
openssl genrsa -out "$DIR/ca-key.pem" 4096 2>/dev/null
openssl req -new -x509 -days 3650 \
    -key "$DIR/ca-key.pem" \
    -out "$DIR/ca.pem" \
    -subj "/CN=Weaviate Lab CA/O=Weaviate Lab" \
    2>/dev/null
echo "    ca.pem created"

echo "==> Generating server key..."
openssl genrsa -out "$DIR/server-key.pem" 2048 2>/dev/null
echo "    server-key.pem created"

echo "==> Writing OpenSSL SAN config..."
cat > "$DIR/server-ext.cnf" <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[req_distinguished_name]
CN = host.docker.internal

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = host.docker.internal
DNS.2 = localhost
IP.1  = 127.0.0.1
EOF

echo "==> Generating server CSR..."
openssl req -new \
    -key "$DIR/server-key.pem" \
    -out "$DIR/server.csr" \
    -config "$DIR/server-ext.cnf" \
    2>/dev/null

echo "==> Signing server certificate with CA..."
openssl x509 -req -days 3650 \
    -in "$DIR/server.csr" \
    -CA "$DIR/ca.pem" \
    -CAkey "$DIR/ca-key.pem" \
    -CAcreateserial \
    -out "$DIR/server.pem" \
    -extensions v3_req \
    -extfile "$DIR/server-ext.cnf" \
    2>/dev/null
echo "    server.pem created"

# Clean up intermediary files
rm -f "$DIR/server.csr" "$DIR/server-ext.cnf" "$DIR/ca.srl"

echo ""
echo "Done. Certificates generated in: $DIR"
echo ""
echo "  ca.pem         — CA cert  → AUTHENTICATION_OIDC_CERTIFICATE"
echo "  server.pem     — Keycloak server cert (signed by CA)"
echo "  server-key.pem — Keycloak server private key"
echo ""
echo "Verify SAN:"
openssl x509 -in "$DIR/server.pem" -noout -text 2>/dev/null \
    | grep -A1 "Subject Alternative Name" || true
