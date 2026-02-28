#!/usr/bin/env bash
# capture-credentials.sh
#
# Use this script ONLY when the fan does not appear in mosquitto_sub output
# after Step 5 — indicating the fan sends MQTT credentials that Mosquitto
# rejects (newer firmware).
#
# What it does:
#   1. Temporarily listens on port 8883 with TLS using openssl s_server.
#   2. Captures the raw MQTT CONNECT packet the fan sends on power-up.
#   3. Parses username + password from the binary packet.
#   4. Prints the credentials and shows how to add them to Mosquitto.
#
# Prerequisites:
#   - openssl (any modern version)
#   - python3
#   - Mosquitto must NOT be listening on port 8883 while this script runs.
#     Stop it first: docker compose stop mosquitto
#     Restart after: docker compose start mosquitto
#
# Usage:
#   cd /home/dgebbink/projects/duuxventilator
#   bash capture-credentials.sh

set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/certs" && pwd)"
CERT="${CERT_DIR}/collector3.cloudgarden.nl.crt"
KEY="${CERT_DIR}/collector3.cloudgarden.nl.key"
CAPTURE="/tmp/mqtt-capture-$$.bin"
PORT=8883
TIMEOUT=60

# ── Sanity checks ─────────────────────────────────────────────────────────────

if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
  echo "ERROR: Certificates not found in ${CERT_DIR}/"
  echo "       Run  bash certs/generate-certs.sh  first."
  exit 1
fi

if ss -tlnp "sport = :${PORT}" 2>/dev/null | grep -q ":${PORT}"; then
  echo "ERROR: Port ${PORT} is already in use (Mosquitto still running?)."
  echo "       Stop Mosquitto first:  docker compose stop mosquitto"
  exit 1
fi

# ── Capture ───────────────────────────────────────────────────────────────────

echo "┌─────────────────────────────────────────────────────────────────────────┐"
echo "│  DUUX Fan Credential Capture                                            │"
echo "└─────────────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Listening on TLS port ${PORT} for up to ${TIMEOUT} seconds."
echo "  → Power-cycle the fan NOW (unplug, wait 2 s, plug back in)."
echo ""

# openssl s_server terminates TLS and writes whatever the client sends to stdout.
# We capture that raw stream (which is the MQTT wire protocol, plaintext after TLS).
# -quiet suppresses the OpenSSL banner so only the MQTT bytes reach stdout.
timeout "${TIMEOUT}" \
  openssl s_server \
    -accept "${PORT}" \
    -cert   "${CERT}" \
    -key    "${KEY}"  \
    -tls1_2 \
    -quiet  \
    2>/dev/null \
  > "${CAPTURE}" || true   # timeout/disconnect exits non-zero; that's fine

CAPTURED=$(wc -c < "${CAPTURE}" 2>/dev/null || echo 0)
if [[ "$CAPTURED" -lt 4 ]]; then
  echo "ERROR: No data captured (${CAPTURED} bytes)."
  echo "       - Confirm DNS override is working: nslookup collector3.cloudgarden.nl"
  echo "       - Confirm port 443 on the Docker host forwards to ${PORT}."
  echo "       - Try again after a full power-cycle of the fan."
  rm -f "${CAPTURE}"
  exit 1
fi

echo "  Captured ${CAPTURED} bytes from fan. Parsing MQTT CONNECT packet..."
echo ""

# ── Parse MQTT CONNECT ────────────────────────────────────────────────────────

python3 - "${CAPTURE}" <<'PYEOF'
import sys, struct, os

path = sys.argv[1]
data = open(path, 'rb').read()

def err(msg):
    print("ERROR:", msg)
    print("  First 32 bytes (hex):", data[:32].hex())
    sys.exit(1)

if len(data) < 10:
    err("Packet too short ({} bytes) — not a valid MQTT CONNECT.".format(len(data)))

if data[0] != 0x10:
    err("First byte is 0x{:02x}, expected 0x10 (CONNECT). "
        "Fan may not have connected, or a different packet arrived first.".format(data[0]))

# --- Decode variable-length remaining-length field ---
pos = 1
remaining_len = 0
multiplier = 1
for _ in range(4):
    if pos >= len(data):
        err("Truncated remaining-length field.")
    byte = data[pos]; pos += 1
    remaining_len += (byte & 0x7F) * multiplier
    multiplier *= 128
    if not (byte & 0x80):
        break

# --- Variable header ---
if pos + 2 > len(data):
    err("Truncated protocol-name length.")
proto_name_len = struct.unpack_from('>H', data, pos)[0]; pos += 2
proto_name = data[pos:pos + proto_name_len].decode('utf-8', errors='replace'); pos += proto_name_len

if pos >= len(data):
    err("Truncated after protocol name.")
proto_level = data[pos]; pos += 1

if pos >= len(data):
    err("Truncated at connect-flags.")
connect_flags = data[pos]; pos += 1

username_flag = bool(connect_flags & 0x80)
password_flag = bool(connect_flags & 0x40)
will_retain   = bool(connect_flags & 0x20)
will_qos      = (connect_flags >> 3) & 0x03
will_flag     = bool(connect_flags & 0x04)
clean_session = bool(connect_flags & 0x02)

keep_alive = struct.unpack_from('>H', data, pos)[0]; pos += 2

# --- Payload ---
def read_str(d, p, label):
    if p + 2 > len(d):
        err("Truncated reading length of {}.".format(label))
    length = struct.unpack_from('>H', d, p)[0]; p += 2
    if p + length > len(d):
        err("Truncated reading value of {} ({} bytes).".format(label, length))
    value = d[p:p + length].decode('utf-8', errors='replace'); p += length
    return value, p

def read_bytes(d, p, label):
    if p + 2 > len(d):
        err("Truncated reading length of {}.".format(label))
    length = struct.unpack_from('>H', d, p)[0]; p += 2
    if p + length > len(d):
        err("Truncated reading value of {} ({} bytes).".format(label, length))
    value = d[p:p + length]; p += length
    return value, p

client_id, pos = read_str(data, pos, 'Client ID')

if will_flag:
    _, pos = read_str(data, pos, 'Will Topic')
    _, pos = read_bytes(data, pos, 'Will Message')

username = ''
password = ''

if username_flag:
    username, pos = read_str(data, pos, 'Username')
if password_flag:
    raw_pw, pos = read_bytes(data, pos, 'Password')
    try:
        password = raw_pw.decode('utf-8')
    except UnicodeDecodeError:
        password = raw_pw.hex()

# --- Report ---
print("┌─ MQTT CONNECT Packet ───────────────────────────────────────────────────┐")
print("│  Protocol   : {} v{}".format(proto_name, proto_level).ljust(74) + "│")
print("│  Client ID  : {}".format(client_id).ljust(74) + "│")
print("│  Clean Sess : {}".format(clean_session).ljust(74) + "│")
print("│  Keep-Alive : {} s".format(keep_alive).ljust(74) + "│")
print("│  Username   : {}".format(username if username_flag else '(none — anonymous)').ljust(74) + "│")
print("│  Password   : {}".format(password if password_flag else '(none)').ljust(74) + "│")
print("└─────────────────────────────────────────────────────────────────────────┘")

if not username_flag:
    print()
    print("  Fan uses anonymous auth → no credentials needed.")
    print("  If Mosquitto still rejects the connection, check 'allow_anonymous true'")
    print("  in mosquitto/duux-fan-tls.conf and restart the container.")
    sys.exit(0)

print()
print("  Next steps — add credentials to Mosquitto:")
print()
print("  Option A  (Mosquitto built-in password file)")
print("  Note: mosquitto_passwd rejects usernames containing colons.")
print("  If the username below contains ':', use Option B instead.")
print()
print("    docker exec -it mosquitto mosquitto_passwd -b /mosquitto/passwd \\")
print("      '{}' '{}'".format(username, password))
print("    # Then add to mosquitto/duux-fan-tls.conf:")
print("    #   password_file /mosquitto/passwd")
print("    #   allow_anonymous false")
print()
print("  Option B  (EMQX or Mosquitto auth plugin — needed for colon usernames)")
print("    See: https://emqx.io  or  https://github.com/iegomez/mosquitto-go-auth")
PYEOF

rm -f "${CAPTURE}"
