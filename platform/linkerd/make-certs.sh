#!/usr/bin/env bash
# Linkerd certificates (mTLS track). Run on the server, from the repo root:
#   platform/linkerd/make-certs.sh                  new trust anchor (root CA, 10 years) + issuer (1 year)
#   platform/linkerd/make-certs.sh rotate-issuer    new issuer signed by the existing root (yearly; root key needed)
# Writes platform/linkerd/trust-anchor.yaml (public) and platform/linkerd/sealed-identity-issuer.yaml (sealed).
# The root private key stays in ~/linkerd-ca: move it to the password manager, then delete it from the server.
set -euo pipefail
umask 077
CA=~/linkerd-ca; OUT=platform/linkerd
mkdir -p "$CA"; cd "$CA"
printf '[req]\ndistinguished_name=dn\n[dn]\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > root.cnf
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > issuer.ext

if [[ "${1:-}" != rotate-issuer ]]; then
  [[ -e ca.key ]] && { echo "$CA/ca.key exists: use rotate-issuer, or move it away first"; exit 1; }
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -subj "/CN=root.linkerd.cluster.local" \
    -extensions v3 -config root.cnf -out ca.crt
fi
[[ -e ca.key ]] || { echo "rotate-issuer needs the root key back in $CA/ca.key (from the password manager)"; exit 1; }

openssl ecparam -name prime256v1 -genkey -noout -out issuer.key
openssl req -new -key issuer.key -subj "/CN=identity.linkerd.cluster.local" -out issuer.csr
openssl x509 -req -in issuer.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -sha256 -extfile issuer.ext -out issuer.crt
openssl verify -CAfile ca.crt issuer.crt
cd - >/dev/null

{ echo "# Linkerd trust anchor (root CA certificate, public). Made by make-certs.sh; the private key is offline."
  echo "identityTrustAnchorsPEM: |"; sed 's/^/  /' "$CA/ca.crt"; } > "$OUT/trust-anchor.yaml"

kubectl -n linkerd create secret generic linkerd-identity-issuer --type=kubernetes.io/tls \
  --from-file=tls.crt="$CA/issuer.crt" --from-file=tls.key="$CA/issuer.key" --from-file=ca.crt="$CA/ca.crt" \
  --dry-run=client -o yaml | kubeseal --format yaml > "$OUT/sealed-identity-issuer.yaml"
rm -f "$CA/issuer.key" "$CA/issuer.csr"        # the cluster has it now (sealed); no second copy

echo; openssl x509 -in "$CA/ca.crt" -noout -subject -enddate
openssl x509 -in "$CA/issuer.crt" -noout -subject -enddate
echo; echo "Next: save $CA/ca.key in the password manager, then: shred -u $CA/ca.key"
