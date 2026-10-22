import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { MongoMemoryServer } from "mongodb-memory-server";
import mongoose from "mongoose";
import type { Server } from "node:http";

const TOKEN = "t".repeat(40);
let mongo: MongoMemoryServer;
let server: Server;
let base: string;

beforeAll(async () => {
  mongo = await MongoMemoryServer.create();
  process.env.MONGO_URL = mongo.getUri("asistent_ia_test");
  process.env.API_TOKEN = TOKEN;
  const { connectMongo } = await import("./db.js");
  const { createApp } = await import("./app.js");
  await connectMongo();
  server = createApp().listen(0);
  const addr = server.address();
  base = `http://127.0.0.1:${typeof addr === "object" && addr ? addr.port : 0}`;
}, 120_000);

afterAll(async () => {
  server?.close();
  await mongoose.disconnect();
  await mongo?.stop();
});

const auth = { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" };

describe("api", () => {
  it("health responde ok con Mongo conectado", async () => {
    const r = await fetch(`${base}/health`);
    expect(r.status).toBe(200);
  });

  it("rechaza sin token", async () => {
    expect((await fetch(`${base}/api/projects`)).status).toBe(401);
  });

  it("crea, lista y actualiza proyectos", async () => {
    const created = await fetch(`${base}/api/projects`, {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ name: "Portal clientes", context: "React + Node" }),
    }).then((r) => r.json());
    expect(created.name).toBe("Portal clientes");

    const patched = await fetch(`${base}/api/projects/${created._id}`, {
      method: "PATCH",
      headers: auth,
      body: JSON.stringify({ description: "v2" }),
    }).then((r) => r.json());
    expect(patched.description).toBe("v2");
    expect(patched.name).toBe("Portal clientes");

    const list = await fetch(`${base}/api/projects`, { headers: auth }).then((r) => r.json());
    expect(list).toHaveLength(1);
  });

  it("valida datos inválidos con 400", async () => {
    const r = await fetch(`${base}/api/projects`, { method: "POST", headers: auth, body: "{}" });
    expect(r.status).toBe(400);
    expect((await fetch(`${base}/api/projects/no-es-un-id`, { headers: auth })).status).toBe(400);
  });
});
