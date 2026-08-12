# RF5 iOS Release Notes

## Main correction

RF4 prevented many stale asynchronous fallback tasks, but transport arrival order could still matter in edge cases. RF5 makes a user mutation an ordered intent rather than a transport-specific action.

For output control, the intent contains the complete desired state. This prevents an older brightness frame, ON, OFF, BLE fallback, LAN retry, or delayed Cloud delivery from reconstructing the wrong hidden/visible brightness when packets arrive in a different order.

## Important RF5 iOS changes

1. Persistent controller identity + session + monotonically increasing intent sequence.
2. Crash-safe sequence leasing increased to 4096 values.
3. One output generation shared by power and brightness.
4. Same command identity is reused across Wi-Fi/BLE/Cloud fallback.
5. Ordered BLE command/ACK contract.
6. Ordered LAN WebSocket ACK with exact command-ID HTTP fallback.
7. Cloud realtime and REST fallback verify ESP semantic ACK.
8. Wrong-lamp Cloud ACKs are rejected by matching lamp/device context.
9. Focused-lamp BLE ownership.
10. Bounded round-robin local polling for many lamps.
11. Wi-Fi/cellular path change forces Cloud WebSocket rebind.
12. RF4 Cloud→LAN ordering protections remain in the route-selection layer.

## Version

- Marketing version: 1.7.4
- Build: 16
