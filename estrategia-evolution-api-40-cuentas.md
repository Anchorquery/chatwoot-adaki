# Estrategia: 40 cuentas WhatsApp con Evolution API + Chatwoot

**Fecha:** 2026-06-09
**Objetivo:** Conectar 40 números WhatsApp (40 entidades independientes) a Chatwoot mediante Evolution API, de forma estable y escalable.

---

## 1. Resumen ejecutivo

40 números WhatsApp = 40 **instances** en Evolution API = 40 **inboxes** en Chatwoot.

**Decisión central:** NO usar un solo proceso Evolution para las 40 instancias. El límite real es el **heap de Node.js por proceso** (no la RAM del servidor). Un caso documentado crasheó a 79 instancias / ~4 GB en un servidor de 64 GB.

**Arquitectura elegida:** shardear en **2-3 contenedores Evolution** (15-20 instancias c/u), con PostgreSQL + Redis compartidos y reverse proxy al frente.

**Motor:** Baileys (gratis, no oficial) en fase inicial. Evaluar migración a WhatsApp Cloud API oficial para producción crítica.

---

## 2. Límites reales de Evolution API (investigado)

| Aspecto | Realidad |
|---|---|
| Límite hardcoded | **No existe.** Puramente resource-bound. |
| Cuello de botella real | Heap de Node.js en **un solo proceso** (`waInstances` registry) |
| Crash documentado | 79 instancias → ~4 GB RAM → crash, en server de 64 GB ([Issue #1419](https://github.com/EvolutionAPI/evolution-api/issues/1419)) |
| Rango cómodo | **20-40 instancias sanas** por proceso |
| Zona problema | 40-80 instancias (OOM, restart loops) |
| RAM por instancia | ~40-60 MB promedio, **muy dependiente del estado** |

**Hallazgo crítico:** una instancia en estado `connecting`/caída consume **mucho más** que una conectada y sana. El fallo es por **estado roto, no por volumen de mensajes**. 10 instancias atascadas en reconexión pueden tumbar el proceso completo.

---

## 3. Arquitectura objetivo

```
                    ┌──────────────────────┐
                    │   Reverse Proxy      │
                    │  (nginx / Traefik)   │
                    │  + rate limiting     │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                 │
      ┌───────▼──────┐  ┌──────▼───────┐  ┌──────▼───────┐
      │ Evolution #1 │  │ Evolution #2 │  │ Evolution #3 │
      │ 15-20 inst.  │  │ 15-20 inst.  │  │  (opcional)  │
      │ 8GB / 2vCPU  │  │ 8GB / 2vCPU  │  │  reserva     │
      └───────┬──────┘  └──────┬───────┘  └──────┬───────┘
              │                │                 │
              └────────────────┼─────────────────┘
                               │
          ┌────────────────────┼────────────────────┐
          │                    │                     │
   ┌──────▼──────┐      ┌──────▼──────┐       ┌──────▼──────┐
   │ PostgreSQL  │      │    Redis    │       │  Chatwoot   │
   │ (compartido)│      │ (compartido)│       │ (Rails+SK)  │
   └─────────────┘      └─────────────┘       └─────────────┘
```

**Reparto de 40 instancias:**
- Evolution #1: instancias 1-20
- Evolution #2: instancias 21-40
- (Evolution #3: reserva / crecimiento futuro)

**Importante:** las instancias son "sticky" al proceso que posee su WebSocket. El proxy enruta por nombre de instancia, no balancea mágicamente.

---

## 4. Stack de software

### Evolution API (×2-3 contenedores)
- Node.js (imagen oficial Evolution ≥ **v2.3.7**)
- Conexión a PostgreSQL y Redis compartidos

### Chatwoot
- Rails + Sidekiq (workers)
- PostgreSQL + Redis (pueden ser los mismos, bases separadas)
- Storage externo (S3/compatible) para media

### Infraestructura compartida
- **PostgreSQL** — pool tuneado para conexiones agregadas
- **Redis** — cache + sesiones + persistencia de instancias
- **Reverse proxy** — nginx/Traefik/Kong con rate limiting

---

## 5. Sizing recomendado

### Opción A — Todo en un VPS potente
| Componente | Recursos |
|---|---|
| Evolution #1 | 8 GB / 2 vCPU |
| Evolution #2 | 8 GB / 2 vCPU |
| Chatwoot | 4-8 GB / 4 vCPU |
| PostgreSQL | 4-8 GB / 4 vCPU |
| Redis | 2 GB |
| **Total** | **~32 GB / 12 vCPU / 100+ GB SSD** |

### Opción B — Separado (producción / mucho volumen)
- VPS Evolution (×2 contenedores): 16 GB / 4 vCPU
- VPS Chatwoot + DB: 16 GB / 4 vCPU
- Mismo datacenter (latencia webhook crítica)

### Presupuesto por contenedor Evolution
- **~4 GB RAM / 2 vCPU por cada 15-20 instancias** (punto de partida)
- Hard `mem_limit` por contenedor
- Supervisor que reinicie en OOM

### Costo orientativo
- VPS único 32 GB (Hetzner/Contabo): ~$60-100/mes
- Setup separado: ~$100-160/mes
- Storage media externo: aparte según volumen

---

## 6. Configuración crítica

### Versiones
- ✅ **Usar ≥ v2.3.7** (arregla loop QR y pérdida de instancias)
- ❌ **Evitar v2.1.0–v2.2.0** (loop reconexión infinito)
- ❌ **Evitar v2.3.0** (instancias viejas devuelven 401)

### Parámetros clave
- `EVENT_EMITTER_MAX_LISTENERS` — subir (default 50) para suprimir warnings de memory leak
- `ulimit -n` alto (file descriptors, muchos sockets)
- Pool de conexiones PostgreSQL tuneado para carga agregada + bursts de reconexión
- `CACHE_REDIS_SAVE_INSTANCES` activo para persistencia

### Eventos
- Centralizar vía RabbitMQ/SQS/NATS en modo **global** (una cola por tipo de evento, NO por instancia)
- Reduce fan-out y desacopla consumidores

---

## 7. Fallos conocidos y mitigación

| Fallo | Cuándo aparece | Mitigación |
|---|---|---|
| OOM por acumulación memoria | Instancias `connecting` | Reapear instancias muertas, supervisor restart-on-OOM |
| Loop QR/reconexión infinito | v2.1.0–v2.2.0 | Usar ≥ v2.3.7 |
| CPU spike (webhook storm) | Volumen alto | Rate limit en proxy |
| Restart loops con proxy | ~70 instancias + proxy | Shardear, menos instancias/proceso |
| Desync tras reboot | Post-reinicio | Monitor de estado + healthchecks |
| Pérdida instancias (401) | v2.3.0 | Evitar esa versión |

**Regla de oro:** monitorear estado de conexión de cada instancia y **eliminar/cuarentenar** las atascadas en `connecting` en vez de dejarlas en loop. Son la causa principal de OOM.

---

## 8. Riesgos de negocio

- **Baneo WhatsApp:** Baileys = no oficial = riesgo de baneo, especialmente con spam/bulk. 40 números no oficiales = riesgo agregado.
- **Sin rate limiter nativo:** Evolution NO trae rate limiting ni cola de envío. Cada instancia envía independiente. **Añadir rate limit en capa de proxy/gateway** obligatorio para bulk.
- **Fragilidad de protocolo:** Baileys se rompe cuando Meta cambia el protocolo WhatsApp Web, hasta que la comunidad parchea.
- **Media crece rápido:** imágenes/audio/video. Usar storage externo (S3) en Chatwoot desde día 1. 100+ GB previsto.

---

## 9. Plan de implementación por fases

### Fase 1 — Piloto (1-2 semanas)
- 1 contenedor Evolution + Chatwoot + Postgres + Redis (docker-compose)
- Conectar 5 números de prueba
- Validar integración Evolution → Chatwoot (webhooks)
- Medir RAM/CPU real por instancia en tu carga

### Fase 2 — Escala parcial (semana 3-4)
- Añadir 2º contenedor Evolution
- Reverse proxy con enrutamiento por instancia + rate limit
- Subir a 20 números repartidos
- Monitoreo (Grafana/Prometheus o similar) de memoria por contenedor

### Fase 3 — Producción 40 (mes 2)
- Completar 40 instancias (20 por contenedor)
- Storage media externo configurado
- Supervisor restart-on-OOM
- Alertas en estado `connecting` persistente
- Backups Postgres automatizados

### Fase 4 — Evaluación oficial (continuo)
- Evaluar migración a WhatsApp Cloud API para números críticos
- Cloud API = sin socket pesado por número = cuello de botella desaparece

---

## 10. Recomendación final

| Decisión | Recomendado |
|---|---|
| 40 instancias en 1 proceso | ❌ No |
| Sharding 2-3 contenedores | ✅ Sí |
| Versión Evolution | ≥ v2.3.7 |
| Motor inicial | Baileys (piloto) |
| Motor producción crítica | Evaluar Cloud API oficial |
| Storage media | Externo (S3) desde día 1 |
| Rate limiting | En reverse proxy, obligatorio |
| Monitoreo memoria | Por contenedor, con alertas |

**40 números son viables**, pero NO en un solo proceso. Reparte la carga, reapea instancias muertas agresivamente, mantén versión actualizada.

---

## Fuentes

- [Issue #1419 — Crash a 79 instancias / 4 GB](https://github.com/EvolutionAPI/evolution-api/issues/1419)
- [Issue #1687 — Pérdida de instancias v2.3.0 (401)](https://github.com/EvolutionAPI/evolution-api/issues/1687)
- [Issue #2538 — Sin rate limiter/cola en bulk](https://github.com/evolution-foundation/evolution-api/issues/2538)
- [PR #2365 — Fix loop QR reconexión](https://github.com/EvolutionAPI/evolution-api/pull/2365)
- [DeepWiki — Arquitectura Evolution API](https://deepwiki.com/EvolutionAPI/evolution-api/1.1-installation-and-deployment)
- [Docs Evolution API — Requisitos RAM](https://doc.evolution-api.com/v1/en/install/nvm)
- [Docs Evolution API — Integración RabbitMQ](https://doc.evolution-api.com/v2/en/integrations/rabbitmq)
