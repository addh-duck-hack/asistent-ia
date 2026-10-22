import { Agenda } from "agenda";
import { MongoBackend } from "@agendajs/mongo-backend";
import { config } from "../config.js";

// Cola de jobs sobre la misma Mongo (colección `jobs`). El API solo encola;
// el worker define y procesa.
export const agenda = new Agenda({
  backend: new MongoBackend({ address: config.MONGO_URL, collection: "jobs" }),
  processEvery: "10 seconds",
  maxConcurrency: 4,
});
