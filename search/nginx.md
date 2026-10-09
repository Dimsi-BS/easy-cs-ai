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

## Observed behaviour (nginx.sh, unit tests only, not run on a VM yet)
- The distribution package is used (`apt`), its service is the proxy. The script writes `conf.d/easy-cs-ai.conf` (server block), `easy-cs-ai/api-key.conf` (the `map`, mode 0600, holds the key) and one `easy-cs-ai/upstreams/<name>.conf` per upstream; the main file includes the others, and nothing of the distribution's configuration is edited.
- The templates go through `envsubst`, which would erase the nginx variables (`$host`…): they are written `${DOLLAR}host`, with `DOLLAR='$'` exported.
- The key is checked with a `map` on `Authorization: Bearer <key>`; every path, the health path `/easy-cs-ai/health` included, answers 401 without it. The key is generated (or given with `--api-key-file`, stdin or `EASY_CS_AI_NGINX_API_KEY`) and limited to `A-Za-z0-9._~-`, so it is safe inside the nginx file.
- An upstream `<name>` is served under `/<name>/` (the prefix is stripped) and `add-upstream` prints `https://<server-name>[:port]/<name>/v1`.
- The health probe pins the self-signed certificate with `--cacert` (verification is never disabled) and passes the key through curl's config on stdin.
- `uninstall` removes the configuration and reloads nginx; the package and the service stay.

## Sources
- [Ollama behind a reverse proxy (Caddy/Nginx)](https://www.glukhov.org/llm-hosting/ollama/ollama-behind-reverse-proxy/)
- [Reverse proxy Ollama with Nginx](https://azdigi.com/blog/kien-thuc-vps/reverse-proxy-ollama-with-nginx-access-ai-via-custom-domain-with-https/?lang=en)
