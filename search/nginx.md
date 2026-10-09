# nginx (reverse proxy)

[← Back to search](README.md)

**Role:** HTTPS termination + API key check in front of inference engines. **License:** BSD-2-Clause (open source, free). See the "Maybe use nginx" decision in the project history; Caddy is the usual alternative.

## Benefits
- Single place for TLS, authentication, timeouts, rate limits and logs.
- Ubiquitous, packaged on Ubuntu/Debian, easy to install from the distribution packages.
- `auth_request` can delegate auth to a small service when per-key logic is needed.

## Weaknesses / must-know
- API key check is not built in: needs a `map` on the `Authorization` header (static keys), or `auth_request` / Lua for dynamic keys. Plain `auth_basic` is not an API key scheme.
- Required for LLM streaming: `proxy_buffering off`, `proxy_http_version 1.1`, and read timeouts raised (~600s) because the 60s default cuts long generations.
- Certificates: Let's Encrypt needs a public domain; otherwise a self-signed cert is needed (see [decision: certificates](../docs/decision-nginx-certificates.md)).

## Health check
- nginx starts in well under a second. The meaningful check is functional, not just "port open": validate with `nginx -t` before the reload, then request through the proxy and expect **401 without key** and **success with key**, which proves TLS and auth work. Estimated timeout: **30 s**.

## Sources
- [Ollama behind a reverse proxy (Caddy/Nginx)](https://www.glukhov.org/llm-hosting/ollama/ollama-behind-reverse-proxy/)
- [Reverse proxy Ollama with Nginx](https://azdigi.com/blog/kien-thuc-vps/reverse-proxy-ollama-with-nginx-access-ai-via-custom-domain-with-https/?lang=en)
