import mongoose from "mongoose";
import { config } from "./config.js";

export async function connectMongo(): Promise<typeof mongoose> {
  const conn = await mongoose.connect(config.MONGO_URL);
  console.log(`[mongo] conectado a ${conn.connection.name}`);
  return conn;
}
