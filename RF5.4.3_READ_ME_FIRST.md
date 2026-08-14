# SH Lamp iOS 1.8.4 build 26 — RF5.4.3-R3.1 Physical Connection Recovery

This R3 exists specifically for the physical Cloud failure reproduced after RF5.4.2:

- UI OFF could revert to ON when the durable Cloud mutation failed and an older authoritative state later reconciled.
- During Cloud brightness dragging, the ESP could be left on the last intermediate live value (for example 29%) if the finger-release durable value (for example 51%) failed to reach/ACK.

R3 keeps the RF5 ordered sequence/value unchanged but permits up to two controlled transport recovery deliveries using fresh command IDs (`-R1`, `-R2`). This makes retry safe:

- if the first delivery never reached the ESP, the retry can apply;
- if the first delivery applied but only the ACK was lost, the same sequence is `DUPLICATE` and cannot physically execute twice;
- if the user issues a newer OFF/brightness intent, the app field generation cancels the old retry, and the ESP sequence gate rejects any leaked older retry as stale.

The existing same-ID WS/REST hedge is still used inside each delivery attempt. Intermediate slider traffic remains ephemeral/latest-only; the finger-release value remains a durable ordered `setOutputState`.


## RF5.4.3-R3.1 physical recovery
- A validated Local WS now proves LAN health even if iOS selects cellular as the default internet path.
- A dedicated `NWPathMonitor(requiredInterfaceType: .wifi)` drives LAN discovery/recovery independently of the default Cloud path.
- R3 durable final-command fresh-ID/same-sequence recovery is retained unchanged.
