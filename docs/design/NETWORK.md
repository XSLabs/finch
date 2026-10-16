# Network.framework

Date: 2026-10-15

## What this covers

Finch's Network.framework Swift API lives in `userland/Network`. Swift code provides the
public types and callbacks. A small Objective-C file provides the C path-monitor entry
points and DNS-SD calls. TCP and UDP traffic uses Darwin sockets. Bonjour uses Finch's
`libsystem_dnssd`, and client TLS uses Finch's Secure Transport in Security.framework.

The overlay fills the Network symbols missing from three local apps. Their missing import
counts were 99 for cmux, 156 for Gemini, and 38 for Claude Usage. After the build, each
count is zero.

## Working behavior

- Endpoints include IPv4, IPv6, names, host and port pairs, Unix socket paths, URLs, and
  Bonjour services. Bonjour service endpoints resolve through DNS-SD. URL endpoints use
  explicit ports, or the usual HTTP, HTTPS, WS, and WSS ports.
- `NWConnection` opens TCP or UDP sockets. It reports state changes, sends and receives
  data, exposes the current path, and supports callback and async send/receive calls.
  TCP options map to socket options where Darwin provides them.
- `NWListener` accepts TCP connections. It can advertise a Bonjour service and report
  service registration changes. A finite `newConnectionLimit` counts down as connections
  arrive and pauses accepting when it reaches zero.
- `NWBrowser` browses Bonjour services. Its TXT-record mode resolves service records and
  reports TXT data. `NWPathMonitor` reads live interface addresses, reports changes, and
  also works as an async sequence.
- A UDP `NWConnectionGroup` can send and receive unicast traffic or join one multicast
  group. It can extract a peer connection and put that peer back into group handling.
- `NWParameters.acceptLocalOnly` checks accepted peer addresses against the local
  interface subnets. `requiredLocalEndpoint`, local endpoint reuse, service class, and TCP
  socket options are applied to sockets.

## Limits

- Application-service discovery and its encrypted local-device connection require an
  Apple service that Finch does not provide. Those connections and browse requests fail
  with `EOPNOTSUPP`.
- TLS client connections use Secure Transport's default certificate and host-name checks.
  TLS listeners, DTLS, and custom `sec_protocol_options_t` settings are not connected to
  the Secure Transport path.
- Interface routing rules, expensive or constrained path rules, multipath, and explicit
  proxy configurations are not applied. A connection or listener that requests one of
  these unsupported rules fails with `EOPNOTSUPP`. Direct sockets do not apply system
  proxy settings.
- Multicast groups with more than one member, a source filter, or unicast rejection fail
  with `EOPNOTSUPP`. One unfiltered multicast group is supported.
- Path snapshots report interfaces and IP support. They do not yet report Low Data Mode,
  gateways, or detailed reasons for an unsatisfied path. `isConstrained` is false,
  `gateways` is empty, and `supportsDNS` follows the current path status.
- Establishment reports do not include DNS or TLS timing. Data reports count application
  bytes; packet, retransmission, and timing counters that Finch cannot read are zero.

## Check

Build the framework and its comparison program, then compare the output with Apple's:

```sh
TMPDIR="$PWD/build/tmp" userland/Network/build.sh
TMPDIR="$PWD/build/tmp" make -C userland/tests ../../build/userland/finch-network-test
TMPDIR="$PWD/build/tmp" tools/host-tests.sh network-test swift-overlay-test cfnetwork-test urlsession-test
```

The Network test checks endpoint and parameter values, callback and async path monitoring,
a TCP listener and connection, a second TCP send after a complete message, and a UDP echo.
All four comparison tests passed on 2026-10-15.
