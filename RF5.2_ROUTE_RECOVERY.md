# SH Lamp iOS 1.7.6 (18) — RF5.2 Route Recovery

This patch is based on RF5.1 and keeps the RF5 universal ordered command engine plus the RF5.1 remembered-brightness correction.

## Physical evidence that triggered this patch

The August 12 extended test showed the iPhone UI as **Offline** while the ESP simultaneously reported:

- router Wi-Fi connected,
- cloud authenticated, and later
- a local realtime WebSocket client connected.

The video also showed the route badge falling from Cloud/Bluetooth to Offline while the phone still had a valid network path.

## Root causes fixed

1. **RF2-era LAN health gate survived into RF5.** RF5 local WebSocket is protocol v3 with ordered mutations and semantic ACK, but `isWiFiHealthy()` still required an extra HTTP `/api/status` success before allowing LAN. A valid local realtime socket could therefore exist while the UI still said Offline.
2. **Cloud route incorrectly required the app WebSocket.** RF5 already has a REST fallback that waits for the ESP ACK, but `isCloudHealthy()` rejected Remote whenever the iPhone account WebSocket was rebinding. The fallback was present but unreachable.
3. **Route badges were not rebuilt on cloud socket status changes.** A successful reconnect could remain visually Offline until a later unrelated state event.
4. **No app-WebSocket authentication timeout.** A half-open socket could remain stuck in Authenticating after an iOS Wi-Fi/cellular change.
5. **Transient Wi-Fi attachment misses could erase a remembered local host too quickly.** RF5.2 adds a 12-second attachment grace and never lets an HTTP miss invalidate a currently healthy v3 realtime socket.

## RF5.2 behavior

- Validated local protocol-v3 realtime state is sufficient LAN proof.
- HTTP remains the fallback when realtime is absent.
- Remote is considered usable from the backend's online device state even while the app realtime WebSocket reconnects; discrete commands use RF5 REST + semantic ACK in that interval.
- Slider intermediate cloud frames remain live-WebSocket-only; the released final value is durable and REST-capable.
- Cloud routes are rebuilt immediately on socket state changes and reconciled via REST after network interface changes.
- App WebSocket auth must complete within 6 seconds or it reconnects.

No ESP control, battery, timer, ordered-sequence, or Render backend logic was changed for this patch.
