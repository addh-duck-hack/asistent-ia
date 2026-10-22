# Imagen base: Node.js 22 LTS (igual que Duck-Hack.cloud).
FROM node:22

WORKDIR /app

# El build context es la RAÍZ del repo (ver docker-compose.yml:
# build.context=. / build.dockerfile=backend/Dockerfile): el backend consume
# @asistent-ia/schema (packages/schema) vía npm workspaces.
#
# Copiar manifiestos primero para aprovechar el caché de Docker (solo se
# reinstala si cambian dependencias, no en cada cambio de código).
COPY package.json package-lock.json ./
COPY backend/package.json ./backend/package.json
COPY packages/schema/package.json ./packages/schema/package.json

# --ignore-scripts: ninguna dependencia necesaria para compilar o correr usa
# scripts de instalación; el único relevante es el postinstall de
# mongodb-memory-server (devDependency de tests), que descarga un binario de
# MongoDB de cientos de MB y deja el build colgado en este paso.
RUN npm ci --ignore-scripts --workspace=backend --workspace=@asistent-ia/schema --include-workspace-root

# Código fuente y compilación TypeScript -> dist/ (schema primero: el backend
# importa sus tipos ya compilados).
COPY packages ./packages
COPY backend ./backend
RUN npm run build --workspace=@asistent-ia/schema \
 && npm run build --workspace=backend \
 && npm prune --omit=dev

# Usuario no root para ejecutar la aplicación.
RUN useradd -m appuser
USER appuser

EXPOSE 5000

WORKDIR /app/backend

# docker-compose.yml sobreescribe el comando para el worker (dist/worker.js).
CMD ["node", "dist/server.js"]
