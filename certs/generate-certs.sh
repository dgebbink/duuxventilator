#!/usr/bin/env bash
# Generates a self-signed TLS certificate for intercepting DUUX fan cloud traffic.
# The fan connects to collector3.cloudgarden.nl:443 and does NOT validate the certificate
# chain — any valid (non-expired) certificate with the right hostname will be accepted.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="collector3.cloudgarden.nl"

echo "Generating self-signed TLS certificate for ${DOMAIN}..."

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${CERT_DIR}/${DOMAIN}.key" \
  -out    "${CERT_DIR}/${DOMAIN}.crt" \
  -days   3650 \
  -subj   "/CN=${DOMAIN}" \
  -addext "subjectAltName=DNS:${DOMAIN},DNS:collector.cloudgarden.nl"

chmod 600 "${CERT_DIR}/${DOMAIN}.key"
chmod 644 "${CERT_DIR}/${DOMAIN}.crt"

echo ""
echo "Done. Files written:"
echo "  ${CERT_DIR}/${DOMAIN}.key  (private key  — keep secret)"
echo "  ${CERT_DIR}/${DOMAIN}.crt  (certificate  — mount into Mosquitto)"
echo ""
echo "Next step: copy these files to your Mosquitto Docker host and mount them"
echo "into the container (see ../docker-compose-additions.yml)."
