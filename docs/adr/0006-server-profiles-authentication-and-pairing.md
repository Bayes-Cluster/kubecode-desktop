# ADR 0006: Server profiles, authentication, and pairing

## Status

Proposed

## Context

Apple clients need to connect to local machines, SSH hosts, remote Servers, and
Kubeflow deployments without duplicating workspace semantics or leaking bearer
credentials. The Runtime currently advertises a versioned API and bearer
authentication. Platform-specific ingress authentication is not yet a shared
Runtime contract.

## Decision

A non-secret `ServerProfile` stores display name, connection mode, endpoint or
SSH host reference, last-used metadata, and a Keychain credential reference.
Bearer values never enter preferences, SwiftData, logs, analytics, URLs, or QR
payloads intended for long-term storage.

Connection modes behave as follows:

- `local_managed` is macOS-only. The app generates an ephemeral token, sends it
  to the bundled Runtime over standard input, retains it in memory, and stops
  the Runtime it owns.
- `ssh_managed` is macOS-only. The app invokes the system `ssh` executable using
  a host from the user's SSH configuration. One SSH process owns the remote
  Runtime and receives an ephemeral token over standard input; a second process
  owns the loopback port forward after the Runtime reports its remote port.
- `https_attached` uses system TLS validation and a bearer credential stored in
  Keychain. Certificate validation cannot be disabled. iPhone and iPad expose
  only this mode.

The credential service is an injectable protocol boundary for deterministic
tests, but the production implementation remains Security.framework Keychain.
The HTTPS transport similarly accepts a test `URLSession`; production uses the
shared system session without a trust-challenge override. Native profile setup
requires a valid HTTPS host and a non-empty bearer before persistence. Tests
must cover the full profile flow from Keychain save through unauthenticated
discovery and a base-path-aware authenticated resource request, as well as
rejecting non-TLS endpoints before network I/O.

SSH integration tests replace only the system executable URL and the bounded
tunnel startup delay. Production defaults remain `/usr/bin/ssh` and 250 ms.
The test fixture must still exercise both Foundation `Process` instances,
ephemeral token stdin, readiness JSON, native `-L` argument construction,
loopback URL loading, protocol discovery, diagnostics, and process cleanup; a
mock that returns a prebuilt `RuntimeClient` does not satisfy this boundary.

All modes must complete discovery and protocol compatibility checks before
resource requests. Unsupported protocol versions fail with a copyable
diagnostic rather than attempting partial compatibility.

Mobile v1 uses manual HTTPS endpoint and token provisioning. A later pairing
increment adds a Runtime endpoint that issues a single-use, short-lived pairing
code. The macOS app displays a QR code containing only endpoint, pairing code,
Server identity fingerprint, and expiry. The mobile app redeems it over HTTPS
for a revocable device credential stored in Keychain. Long-lived bearer tokens
are never encoded directly in QR codes.

OIDC or Kubeflow ingress flows are not inferred from cookies or web pages.
Until discovery advertises a supported native authentication flow, an
HTTPS-attached endpoint must expose the bearer-compatible Runtime API. A future
OIDC flow requires a superseding authentication ADR.

## Consequences

Connection lifecycle differs by platform while resource clients remain shared.
The first mobile beta can ship without inventing a pairing protocol, and later
pairing does not weaken credential handling.

Some current Kubeflow ingresses will require configuration changes or remain
browser-only until native authentication is standardized.
