# Public Cloudflare Tunnel deployment

The running deployment uses these hosts:

| Host | Service |
|---|---|
| https://llm.cookeebit.cloud/ui/ | LiteLLM administration and playground |
| https://llm-api.cookeebit.cloud/v1 | OpenAI-compatible API |
| https://llm-infra.cookeebit.cloud | Portainer |

The dedicated `qlc-llm` tunnel connects to Nginx on the private Docker network.
No additional inbound host ports are opened. Nginx routes by hostname, preserves
streaming and WebSocket traffic, and rate limits login attempts. The API hostname
allows only model discovery, chat/completions, completions and responses paths;
management routes are available through the authenticated UI hostname. API
requests still require a scoped LiteLLM virtual key.

## Reproduce with your own tunnel

Create a locally managed Cloudflare Tunnel and route the three hostnames to it
using Cloudflare's dashboard or CLI. Check existing DNS records before changing
them. Adapt `compose.public.yaml` and `nginx.conf` for different domains. Place
the tunnel credentials JSON at `docker/.runtime/cloudflared/tunnel.json` and
create `docker/.runtime/cloudflared/config.yml`:

```yaml
tunnel: YOUR_TUNNEL_UUID
credentials-file: /etc/cloudflared/tunnel.json
metrics: 0.0.0.0:2000
ingress:
  - hostname: llm.cookeebit.cloud
    service: http://edge:8080
  - hostname: llm-api.cookeebit.cloud
    service: http://edge:8080
  - hostname: llm-infra.cookeebit.cloud
    service: http://edge:8080
  - service: http_status:404
```

Keep the directory mode 700 and both files mode 600. The runtime connector mounts
only these files, not the Cloudflare account origin certificate. Keep tunnel
credentials and account certificates out of Git.

After the base setup, add these values to the private `docker/.env`:

```dotenv
COMPOSE_FILE=compose.yaml:compose.public.yaml
PUBLIC_API_BASE_URL=https://llm-api.cookeebit.cloud/v1
PUBLIC_UI_URL=https://llm.cookeebit.cloud/ui/
PUBLIC_INFRA_URL=https://llm-infra.cookeebit.cloud
```

From the repository root:

```bash
docker compose --project-directory docker config --quiet
docker compose --project-directory docker up -d --build --wait --wait-timeout 300
python3 docker/bootstrap.py
```

Do not pass only `-f docker/compose.yaml` for this deployment: an explicit file
selection replaces `COMPOSE_FILE` and omits the public services and HTTPS settings.
Bootstrap saves public URLs and credentials to the private access file documented
in [README.md](README.md). Log in with that database admin account; environment
username/password login is disabled. Portainer retains its own account.

Use streaming for interactive generation. Nginx allows 1,800-second upstream
requests, but Cloudflare edge limits still apply to connections without response
data; maximum-context idle prefill has not been validated through this tunnel.

References: [Cloudflare locally managed tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/local-management/),
[LiteLLM UI](https://docs.litellm.ai/docs/proxy/ui).
