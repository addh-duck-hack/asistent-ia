# asistent-ia
Asistente para reuniones en Mac: graba y transcribe reuniones localmente, importa
chats de Teams y genera con Claude un análisis por proyecto (resumen, decisiones,
action items, riesgos y bloqueos).

## Estructura
- `apps/mac/` — app SwiftUI (pendiente, Fase 1–2)
- `backend/` — API Express + Mongoose + worker Agenda (TypeScript)
- `packages/schema/` — esquema zod del análisis, compartido

## Desarrollo local
```bash
npm install
cp backend/.env.example backend/.env   # llenar MONGO_URL y API_TOKEN
npm run build --workspace=@asistent-ia/schema
npm run dev --workspace=backend         # API en :5000
npm run dev:worker --workspace=backend  # worker
npm test --workspace=backend            # tests (Mongo en memoria)
```

## Despliegue (servidor con Nginx Proxy Manager)
1. `git clone` y `cp backend/.env.example backend/.env` (llenar valores).
2. `docker compose up -d --build`
3. En NPM: Proxy Host `asistant.duck-hack.cloud` → `http://asistent-ia.backend:5000`,
   SSL Let's Encrypt + Force SSL, y en Advanced:
   `client_max_body_size 50m; proxy_read_timeout 300s;`
4. Verificar: `curl https://asistant.duck-hack.cloud/health` → `{"ok":true}`

Actualizar: `git pull && docker compose up -d --build`. Un cambio solo en
`backend/.env` se aplica con `docker compose up -d`.
