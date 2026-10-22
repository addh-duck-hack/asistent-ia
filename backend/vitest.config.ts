import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Valores de relleno para que config.ts no falle al importarse; las
    // pruebas con Mongo en memoria los reemplazan antes de importar la app.
    env: {
      MONGO_URL: "mongodb://127.0.0.1:1/unused",
      API_TOKEN: "t".repeat(40),
    },
  },
});
