# Observability Stack — Runbook

Guia prático para subir e operar o stack de observabilidade em produção.  
O stack é composto por Jaeger, Prometheus, Loki, OTEL Collector e Nginx rodando como serviços systemd via Docker.

---

## Pré-requisitos

Na VM de produção, verifique se os seguintes itens estão disponíveis:

```bash
docker --version    # Docker Engine (não Docker Desktop)
openssl version
curl --version
systemctl --version
```

Se o Docker não estiver instalado:
```bash
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker
```

> O script `setup.sh` checará esses pré-requisitos automaticamente e falhará com erro claro se algum estiver faltando.

---

## Setup inicial (primeira vez)

### 1. Copie o diretório `production/` para a VM

```bash
scp -r production/ user@<vm-ip>:~/observability
```

Ou clone o repositório diretamente na VM:
```bash
git clone <repo-url>
cd observability-dev
```

### 2. Execute o script de setup

```bash
sudo ./production/scripts/setup.sh
```

O script é interativo e vai pedir credenciais para cada serviço separadamente:

```
  OTEL Collector  (apps send telemetry here)
    Username [otel-collector]: <enter ou seu usuário>
    Password (min 8 chars): ••••••••
    Confirm password: ••••••••

  Prometheus       (metrics query)
    Username [otel-prometheus]: <enter ou seu usuário>
    Password (min 8 chars): ••••••••

  Loki             (log query)
    Username [otel-loki]: <enter ou seu usuário>
    Password (min 8 chars): ••••••••

  Jaeger           (trace UI)
    Username [otel-jaeger]: <enter ou seu usuário>
    Password (min 8 chars): ••••••••
```

> Pressione ENTER para aceitar o username padrão de cada serviço.

### 3. O que o script faz (em ordem)

| Etapa | O que acontece |
|---|---|
| Pré-requisitos | Verifica `docker`, `openssl`, `curl`, `systemctl` e que o daemon do Docker está rodando |
| Credenciais | Solicita usuário/senha para cada serviço e gera hashes (bcrypt para Collector e Prometheus, APR1 para Nginx) |
| Rede Docker | Cria a rede `observability-net` (bridge isolada para comunicação interna) |
| Diretórios | Cria `/opt/observability/configs/` e `/opt/observability/data/` com as permissões corretas |
| Pull de imagens | Baixa as versões fixas de cada imagem |
| Configs | Escreve os arquivos de config em `/opt/observability/configs/` com as credenciais injetadas |
| Systemd | Copia os `.service` files para `/etc/systemd/system/` e faz `daemon-reload` |
| Inicialização | Habilita e sobe os serviços na ordem correta (backends → nginx → collector) |
| Health checks | Aguarda cada serviço ficar saudável (até 60s por serviço) |
| Resumo | Imprime endpoints, credenciais e variáveis de ambiente prontas para copiar |

### 4. Saída esperada ao final

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Observability Stack — Production Ready
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Service        URL                              Credentials
  ─────────────────────────────────────────────────────────────
  Jaeger         http://10.0.0.1:16686            otel-jaeger / ••••••••
  Prometheus     http://10.0.0.1:9090             otel-prometheus / ••••••••
  Loki           http://10.0.0.1:3100             otel-loki / ••••••••
  OTEL gRPC      10.0.0.1:14317                   otel-collector / ••••••••
  OTEL HTTP      http://10.0.0.1:14318            otel-collector / ••••••••

  App environment variables (.env):
    OTEL_EXPORTER_OTLP_ENDPOINT=http://10.0.0.1:14317
    OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=http://10.0.0.1:14318
    OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <token-base64>

  All credentials saved to: /opt/observability/configs/.credentials
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Copie as variáveis de ambiente do bloco `App environment variables` para o `.env` da aplicação.

---

## Verificar status dos serviços

```bash
./production/scripts/status.sh
```

Saída esperada (todos verdes):
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Observability Stack — Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  otel-jaeger            active
  otel-prometheus        active
  otel-loki              active
  otel-collector         active
  otel-nginx             active

  Health checks:
  Jaeger UI              healthy
  Prometheus             healthy
  Loki                   healthy
  OTEL Collector         healthy
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Gerenciar serviços individualmente

```bash
# Ver status de um serviço específico
systemctl status otel-collector

# Reiniciar
systemctl restart otel-collector

# Parar / iniciar
systemctl stop otel-loki
systemctl start otel-loki

# Ver logs em tempo real
journalctl -u otel-collector -f
journalctl -u otel-jaeger -f
journalctl -u otel-prometheus -f
journalctl -u otel-loki -f
journalctl -u otel-nginx -f

# Últimas 100 linhas + follow
journalctl -u otel-collector -n 100 -f
```

> Todos os serviços têm `Restart=always` — se um container cair, o systemd reinicia automaticamente.

---

## Conectar as aplicações

As credenciais ficam salvas em `/opt/observability/configs/.credentials` (somente root).
Para consultá-las:
```bash
sudo cat /opt/observability/configs/.credentials
```

### Variáveis de ambiente para NestJS (`apps/my-app/.env`)

```env
NODE_ENV=production
OTEL_SERVICE_NAME=my-nestjs-app
OTEL_EXPORTER_OTLP_ENDPOINT=http://<vm-ip>:14317
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=http://<vm-ip>:14318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64-do-collector>
LOKI_HOST=http://<vm-ip>:3100
PORT=3000
```

### Variáveis de ambiente para Rails (`apps/rails-application/.env`)

```env
OTEL_SERVICE_NAME=hike-tracker
OTEL_EXPORTER_OTLP_ENDPOINT=http://<vm-ip>:14318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64-do-collector>
LOKI_URL=http://<vm-ip>:3100
LOKI_USERNAME=<loki-user>
LOKI_PASSWORD=<loki-pass>
```

> O NestJS e o Rails usam mecanismos diferentes para autenticar no Loki.  
> NestJS usa o header `Authorization` via Winston transport.  
> Rails usa `LOKI_USERNAME` / `LOKI_PASSWORD` no async logger em `lib/loki/`.

### Gerar o token Base64 manualmente

```bash
echo -n "otel-collector:sua-senha" | base64
```

Cole o resultado no campo `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <aqui>`.

---

## Portas expostas

| Serviço | Porta | Autenticação |
|---|---|---|
| OTEL Collector (gRPC) | `14317` | Basic Auth — credenciais do collector |
| OTEL Collector (HTTP) | `14318` | Basic Auth — credenciais do collector |
| Jaeger UI | `16686` | Basic Auth via Nginx — credenciais do jaeger |
| Prometheus | `9090` | Basic Auth nativa — credenciais do prometheus |
| Loki | `3100` | Basic Auth via Nginx — credenciais do loki |
| OTEL Health | `13133` | Sem autenticação (interno) |

---

## Operações do dia a dia

### Rotacionar credenciais

```bash
sudo ./production/scripts/setup.sh --rotate-credentials
```

Solicita novas senhas para todos os serviços, regenera os hashes e reinicia `otel-collector`, `otel-prometheus` e `otel-nginx` automaticamente.  
Jaeger e Loki não precisam reiniciar (a autenticação fica no Nginx).

Após rotacionar, atualize o `.env` das aplicações com o novo token Base64.

### Recarregar config do Prometheus sem restart

```bash
curl -u <prometheus-user>:<prometheus-pass> -X POST http://localhost:9090/-/reload
```

### Desinstalar

```bash
sudo ./production/scripts/uninstall.sh
```

Remove serviços, containers, configs e a rede Docker.  
**Os dados em `/opt/observability/data/` são preservados.**  
Para remover os dados também:
```bash
sudo rm -rf /opt/observability/data/
```

---

## Simulação local (antes de fazer deploy)

Para testar o stack de produção na sua máquina antes de subir na VM:

```bash
cd production

# Subir
docker compose -f docker-compose.prod.yml up -d

# Ver logs
docker compose -f docker-compose.prod.yml logs -f

# Parar
docker compose -f docker-compose.prod.yml down

# Resetar tudo (remove volumes)
docker compose -f docker-compose.prod.yml down -v
```

Credenciais padrão da simulação: usuário `otel` / senha `observability123`.

> Nunca use essas credenciais em um servidor real.

---

## Troubleshooting

### `otel-collector` não sobe

O collector depende do Jaeger, Loki e Prometheus. Verifique se os backends subiram:
```bash
systemctl status otel-jaeger otel-loki otel-prometheus
journalctl -u otel-collector -n 50
```

### Aplicação recebe `401 Unauthorized` no OTEL Collector

Credenciais erradas ou token Base64 incorreto. Teste:
```bash
curl -v -u <collector-user>:<collector-pass> http://<vm-ip>:14318/
# Esperado: HTTP 405 (o endpoint existe mas rejeita GET — isso é correto)
# Se retornar 401: senha errada
# Se recusar conexão: cheque firewall
```

### Loki retorna `401`

O app está buscando o Loki diretamente na porta `3100`, que está atrás do Nginx.
Verifique se as credenciais do Loki (não do collector) estão configuradas corretamente.

### Serviço fica em `activating` por muito tempo

```bash
journalctl -u otel-<nome> -n 30
docker ps -a | grep otel
```

Pode ser problema de pull de imagem ou porta já em uso:
```bash
sudo ss -tlnp | grep <porta>
```

### Ver credenciais salvas

```bash
sudo cat /opt/observability/configs/.credentials
```
