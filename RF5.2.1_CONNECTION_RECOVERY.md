# RF5.2.1 Connection Recovery — Root Cause and Fix

The August 12 physical screenshots/log show a route-supervisor deadlock distinct from the ESP's separate Cloud instability:

- iPhone remained on the same Wi-Fi as the ESP.
- ESP continued to report Wi-Fi connected and a valid local IP.
- Bluetooth radio was enabled on the iPhone.
- The app still showed the lamp Offline.

The RF5.2 source audit found two recovery gaps:

1. After repeated local probe failures, `localHost` could still be erased. Polling only considers records that have a host, so this could remove the very address needed to recover.
2. BLE recovery depended heavily on a finite scan/onAppear cycle. A known CoreBluetooth UUID was not used for direct reconnect, and a pending connection had no bounded setup timeout.

RF5.2.1 makes LAN and BLE recovery self-healing and independent from Cloud. It does not alter the RF5 command ordering engine.
