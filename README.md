# DUUX Ventilator — Local MQTT via Home Assistant to Apple Home

Intercepts the DUUX Whisper Flex fan's cloud MQTT connection and redirects it to a local Mosquitto broker, making the fan controllable via Home Assistant and Apple Home — without any cloud dependency.

## How it works

```
Fan ──MQTTS:443──► Mosquitto (local) ──► Home Assistant ──► Apple Home
         ▲
    DNS override
  collector3.cloudgarden.nl → 192.168.2.27
```

1. The fan connects to `collector3.cloudgarden.nl:443` over MQTTS
2. A local DNS override points that hostname to the Mosquitto host
3. Mosquitto presents a self-signed TLS cert (the fan does not verify the chain)
4. All MQTT traffic is now local — no cloud involved

## Hardware

- **Fan:** DUUX Whisper Flex (firmware 14.3.10)
- **Broker host:** Raspberry Pi running Docker (192.168.2.27, macvlan)
- **Home Assistant:** 192.168.2.26

## MQTT Topics

| Topic | Direction | Content |
|-------|-----------|---------|
| `sensor/e0:5a:1b:76:ef:60/in` | Fan → broker | JSON state (power, speed, mode, …) |
| `sensor/e0:5a:1b:76:ef:60/command` | Broker → fan | Plaintext command, e.g. `tune set power 1` |
| `sensor/e0:5a:1b:76:ef:60/online` | Fan → broker | `{"online":true,"connectionType":"mqtt"}` |

State payload example:
```json
{"sub":{"Tune":[{"uid":"dune79w7bsu6dg3e","id":1,"power":0,"mode":0,"speed":8,"swing":0,"tilt":0,"timer":0}]}}
```

- `power`: `0` = off, `1` = on
- `speed`: `1–26` (Whisper Flex 1 range)

## Setup

### 1. Generate TLS certificate

```bash
bash certs/generate-certs.sh
```

Generates a self-signed cert for `collector3.cloudgarden.nl`.

### 2. Start Mosquitto

Merge `docker-compose-additions.yml` into your existing compose stack:

```bash
docker compose -f docker-compose.yml -f docker-compose-additions.yml up -d mosquitto
```

### 3. DNS override

Point `collector3.cloudgarden.nl` (and `collector.cloudgarden.nl`) to your Mosquitto host (192.168.2.27) in your local DNS (e.g. Pi-hole).

### 4. Verify

Power-cycle the fan, then:

```bash
mosquitto_sub -h 192.168.2.27 -p 1883 -t 'sensor/#' -v
```

You should see the `online` and `in` topics appear within ~30 seconds.

### 5. Home Assistant

Copy `homeassistant/fan.yaml` to `<ha-config>/mqtt/fan.yaml` and ensure your `configuration.yaml` includes:

```yaml
mqtt:
  fan: !include_dir_merge_list mqtt/
```

Restart Home Assistant. The fan appears as a fan entity (`fan.duux_whisper_flex`) with on/off and speed (percentage) control.

### 6. Apple Home

Enable the built-in **HomeKit Bridge** integration in Home Assistant (Settings → Integrations), add the fan entity, and scan the QR code in the Apple Home app.

## Files

| File | Purpose |
|------|---------|
| `certs/generate-certs.sh` | Generates self-signed TLS cert |
| `mosquitto/duux-fan-tls.conf` | Mosquitto TLS listener config |
| `docker-compose-additions.yml` | Compose override for port 443 and volumes |
| `capture-credentials.sh` | Debug helper: captures raw MQTT CONNECT packet |
| `homeassistant/fan.yaml` | MQTT fan entity for Home Assistant |
| `homeassistant/configuration.yaml` | HA config snippet |
