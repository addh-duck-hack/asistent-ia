import type { Types } from "mongoose";
import { ActionItemModel, PersonModel } from "../models/index.js";

export function normalize(s: string): string {
  return s.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase().trim();
}

interface PersonLike {
  _id: Types.ObjectId | string;
  name: string;
  aliases?: string[] | null;
}

/** Formas con las que se puede nombrar a una persona: nombre, primer nombre y alias. */
export function personKeys(p: Pick<PersonLike, "name" | "aliases">): string[] {
  const keys = [p.name, p.name.split(/\s+/)[0] ?? "", ...(p.aliases ?? [])];
  return [...new Set(keys.map(normalize).filter(Boolean))];
}

/** Alias limpios: sin vacíos, sin repetir y sin repetir el nombre. */
export function cleanAliases(name: string, aliases: string[] | undefined): string[] {
  const seen = new Set([normalize(name)]);
  const out: string[] = [];
  for (const a of aliases ?? []) {
    const t = a.trim();
    if (!t || seen.has(normalize(t))) continue;
    seen.add(normalize(t));
    out.push(t);
  }
  return out;
}

/**
 * Mapea el responsable que escribió Claude ("Tavo", "Octavio") a una persona
 * activa por nombre, primer nombre o alias. Si hay ambigüedad o no hay
 * coincidencia, queda sin ownerId.
 */
export async function buildOwnerResolver() {
  const people = await PersonModel.find({ active: { $ne: false } }).lean();
  const index = new Map<string, string[]>();
  for (const p of people) {
    for (const k of personKeys(p)) index.set(k, [...new Set([...(index.get(k) ?? []), String(p._id)])]);
  }
  return (owner: string | null | undefined) => {
    if (!owner) return undefined;
    const ids = index.get(normalize(owner));
    return ids?.length === 1 ? ids[0] : undefined;
  };
}

/**
 * Busca otra persona activa que ya use alguno de estos nombres o alias como
 * alias propio o nombre, para que "Tavo" nunca sea ambiguo. Devuelve el
 * texto en conflicto y el nombre de la otra persona.
 */
export async function findAliasConflict(
  name: string,
  aliases: string[],
  excludeId?: string,
): Promise<{ alias: string; person: string } | null> {
  const mine = new Map([...aliases, name].map((a) => [normalize(a), a]));
  const others = await PersonModel.find({ active: { $ne: false }, ...(excludeId ? { _id: { $ne: excludeId } } : {}) }).lean();
  for (const o of others) {
    // Solo nombre completo y alias: compartir primer nombre (dos "Ana") es normal.
    for (const k of [o.name, ...(o.aliases ?? [])].map(normalize)) {
      const hit = mine.get(k);
      if (hit) return { alias: hit, person: o.name };
    }
  }
  return null;
}

/**
 * Liga a esta persona los pendientes sin ownerId cuyo owner (texto escrito por
 * Claude) coincide con su nombre o alias, siempre que la coincidencia sea única
 * entre las personas activas. Devuelve cuántos se ligaron.
 */
export async function linkOwnerItems(personId: string): Promise<number> {
  const resolve = await buildOwnerResolver();
  const candidates = await ActionItemModel.find({ ownerId: null, owner: { $nin: [null, ""] } }).select({ owner: 1 }).lean();
  const ids = candidates.filter((i) => resolve(i.owner) === personId).map((i) => i._id);
  if (ids.length === 0) return 0;
  await ActionItemModel.updateMany({ _id: { $in: ids } }, { $set: { ownerId: personId } });
  return ids.length;
}

/** Texto para el prompt: "Octavio Ramírez (también: Tavo, Octa)". */
export function formatMember(m: { name: string; aliases?: string[] | null }): string {
  return m.aliases?.length ? `${m.name} (también: ${m.aliases.join(", ")})` : m.name;
}
