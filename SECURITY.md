# Security

Talaria is an early development preview. Security fixes target the latest code on `main`; older snapshots do not have separate support branches.

Please report suspected vulnerabilities privately through [GitHub's vulnerability reporting form](https://github.com/howhowdg/talaria/security/advisories/new). Include affected versions, reproduction steps, expected behavior and impact. Use synthetic data and redact all gateway tokens, provider keys, private conversations and personal file paths. Do not attach live credentials or publish exploit details in a public issue.

Ordinary bugs and feature requests belong in the repository's Issues tab.

## Current boundaries

Talaria stores remembered gateway tokens and Basic sign-in sessions in device-only Keychain. Passwords are used only to sign in and are not saved. Session cookies are scoped to the connection, gateway origin and path; redirects are denied. Model-provider credentials stay with the Hermes host. Remote endpoints require HTTPS except for HTTP to Tailscale's 100.64.0.0/10 address range; loopback HTTP is also supported. The iOS client connects to a host and does not run the agent runtime on the phone.

Mac SSH connections use the system SSH client with strict host-key checking and an app-owned loopback forward. By default, Talaria starts and stops its own separate, loopback-only Hermes gateway on the remote host; Advanced can connect to an existing gateway instead. Talaria does not enroll new host keys or stop gateways it did not start. Saved SSH destinations exclude the temporary local port.

Use one active native sending client per session during this preview. Complete replay-gap recovery, multi-client request settlement and attachment leases are still on the roadmap. The app does not automatically resend a prompt whose delivery is uncertain.

The bundled integration fixture uses synthetic inference and disposable credentials. Its loopback network guard is a Python test aid, not an operating-system sandbox. See [preview status](docs/status.md) for current capabilities and limitations.
