# LiteLLM proxy

[← Back to search](README.md)

**Role:** candidate replacement/complement for [nginx](nginx.md): OpenAI-compatible gateway with real API key management. **License:** MIT (core); enterprise edition adds SSO, audit logs, support.

## Benefits
- Virtual keys scoped to models, budgets, rate limits and logging in the open-source edition.
- Single endpoint in front of Ollama, vLLM and others; usage data could feed the CloudStack "is it used?" TODO.

## Weaknesses / must-know
- Virtual keys need a database (Postgres); Redis for caching/rate-limit sync. Heavier than nginx.
- Python service to package in the snap. Native TLS is possible (`--ssl_keyfile_path` / `--ssl_certfile_path`), though docs usually put TLS on a load balancer.
- Without a database there are no virtual keys: only the single master key works. Enterprise edition lists SSO/SAML, audit logs, multi-team management and guardrails; the public docs do not state the exact open-source/enterprise split.

## Sources
- [LiteLLM virtual keys](https://blog.elest.io/litellm-stop-burning-money-on-llm-apis-virtual-keys-cost-tracking-and-guardrails/)
- [LiteLLM proxy setup](https://techsy.io/blog/litellm-proxy-setup-guide)
