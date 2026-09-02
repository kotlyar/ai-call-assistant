# Security policy

## Supported version

Security fixes are applied to the latest published Callya release and the
current `main` branch.

## Reporting a vulnerability

Please do not disclose suspected vulnerabilities in a public issue. Use
[GitHub's private vulnerability reporting](https://github.com/kotlyar/ai-call-assistant/security/advisories/new)
and include:

- the affected platform and Callya version;
- clear reproduction steps;
- the expected and observed impact;
- logs or a minimal proof of concept with all secrets and personal call data
  removed.

You should receive an acknowledgement within seven days. A fix timeline will
depend on severity and reproducibility. Please allow time for a patch before
public disclosure.

## Scope notes

Callya sends audio, transcript text, and selected context to the OpenAI Platform
when cloud processing is enabled. API keys and local call data must never be
included in public reports. macOS and Windows capture-exclusion APIs are
best-effort privacy aids, not a security boundary.
