# RF5.2 iOS Release Notes

Version **1.7.6 (18)**.

RF5.2 is an iOS route-health/lifecycle correction derived from the August 12 physical video/log. It retains RF5 ordering and RF5.1 remembered-brightness fixes.

Key change: the app's old Phase-A assumption that local WebSocket was state-only was still gating Local Wi-Fi behind an additional HTTP proof. RF5 protocol v3 now has ordered LAN commands and semantic ACK, so a validated realtime socket is authoritative LAN reachability.

Remote also no longer depends exclusively on the iPhone's account WebSocket being authenticated at that instant. RF5's REST command path already waits for the ESP semantic ACK, so it is now reachable during WebSocket rebinds as long as Render's device state says the lamp is online.

No ESP control/battery logic or Render backend source changes are part of RF5.2.
