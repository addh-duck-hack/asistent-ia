import { timingSafeEqual } from "node:crypto";
import type { NextFunction, Request, Response } from "express";
import { config } from "../config.js";

// Un solo usuario por ahora: la app Mac manda `Authorization: Bearer <API_TOKEN>`.
const expected = Buffer.from(config.API_TOKEN);

export function requireToken(req: Request, res: Response, next: NextFunction) {
  const header = req.headers.authorization ?? "";
  const token = Buffer.from(header.startsWith("Bearer ") ? header.slice(7) : "");
  if (token.length !== expected.length || !timingSafeEqual(token, expected)) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  next();
}
