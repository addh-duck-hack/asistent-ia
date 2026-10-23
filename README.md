# asistent-ia
Asistente para reuniones en Mac: graba y transcribe reuniones localmente, importa
chats de Teams y genera con Claude un análisis por proyecto (resumen, decisiones,
action items, riesgos y bloqueos).

## Estructura
- `apps/mac/` — app SwiftUI (proyecto Xcode generado con XcodeGen desde `project.yml`)
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

### App Mac
Requiere Xcode y XcodeGen (`brew install xcodegen`).
```bash
cd apps/mac
scripts/build-app.sh --install   # compila Release y la instala en /Applications
scripts/build-app.sh --dmg       # además genera dist/AsistentIA.dmg
xcodegen generate && open AsistentIA.xcodeproj   # para desarrollar en Xcode (⌘R, ⌘U)
```
La firma se configura en `apps/mac/Config/Signing.xcconfig` (ad-hoc por defecto;
con un Team ID de Apple Development los permisos de micrófono no se piden en cada build).
En **Ajustes** (⌘,) pon la URL del backend y el `API_TOKEN`; el token se guarda en el llavero.

## Despliegue (servidor con Nginx Proxy Manager)
1. `git clone` y `cp backend/.env.example backend/.env` (llenar valores).
2. `docker compose up -d --build`
3. En NPM: Proxy Host `asistant.duck-hack.cloud` → `http://asistent-ia.backend:5000`,
   SSL Let's Encrypt + Force SSL, y en Advanced:
   `client_max_body_size 50m; proxy_read_timeout 300s;`
4. Verificar: `curl https://asistant.duck-hack.cloud/health` → `{"ok":true}`

Prueba real de Claude (sin tocar Mongo):
`docker compose exec worker node dist/scripts/smokeAnalyze.js [quick|standard|deep]`

Comparar modelos y costos con tus últimas sesiones (no guarda nada, ~1–2 USD):
`docker compose exec -T worker node dist/scripts/compareProfiles.js --last 3 > comparacion.md`

Modelo y effort de cada nivel de análisis: variables `ANALYSIS_*` en `backend/.env`.

Actualizar: `git pull && docker compose up -d --build`. Un cambio solo en
`backend/.env` se aplica con `docker compose up -d`.
