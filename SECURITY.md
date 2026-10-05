# Security Policy

## Scope

MoniView is a local macOS app. It requests camera and microphone access to read a USB (UVC) capture card, and it does not send data over the network. A diagnostics snapshot is written to `~/Library/Logs/MoniView/diagnostics.json` on the local machine only.

## Reporting

Report suspected vulnerabilities through GitHub private vulnerability reporting:
https://github.com/roanpy/MoniView/security/advisories/new

That route opens a private advisory visible only to you and the maintainer, so do not open a public issue for a suspected vulnerability. If the private reporting entry point is not yet available on the repository, use the contact options on the [maintainer's GitHub profile](https://github.com/roanpy) instead. Enabling GitHub private vulnerability reporting is a repository setting the maintainer must turn on.

Do not include capture card serial numbers, device identifiers, private file paths, or full diagnostic logs in a report. Share only what is needed to reproduce the problem, and redact the rest.

## Supported versions

MoniView is an early preview with no long-term support window. Fixes are applied to the current development line.
