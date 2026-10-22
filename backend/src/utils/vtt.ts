// Convierte un .vtt (por ejemplo, la transcripción que exporta Teams) en
// segmentos. Teams marca al hablante con <v Nombre>texto</v>.

export interface ParsedSegment {
  startSec: number;
  endSec: number;
  speaker: string | null;
  text: string;
}

const TIMING = /^(\d{1,2}:)?(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+(\d{1,2}:)?(\d{2}):(\d{2})[.,](\d{3})/;

function toSec(h: string | undefined, m: string, s: string, ms: string): number {
  return (h ? Number(h.slice(0, -1)) : 0) * 3600 + Number(m) * 60 + Number(s) + Number(ms) / 1000;
}

export function parseVtt(content: string): ParsedSegment[] {
  const segments: ParsedSegment[] = [];
  const blocks = content.replace(/\r\n?/g, "\n").split(/\n{2,}/);

  for (const block of blocks) {
    const lines = block.split("\n").map((l) => l.trim()).filter(Boolean);
    const timingIdx = lines.findIndex((l) => TIMING.test(l));
    if (timingIdx === -1) continue; // WEBVTT, NOTE, STYLE, etc.

    const m = lines[timingIdx]!.match(TIMING)!;
    const raw = lines.slice(timingIdx + 1).join(" ");
    const voice = raw.match(/<v(?:\.[^\s>]+)?\s+([^>]+)>/);
    const text = raw.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
    if (!text) continue;

    const seg: ParsedSegment = {
      startSec: toSec(m[1], m[2]!, m[3]!, m[4]!),
      endSec: toSec(m[5], m[6]!, m[7]!, m[8]!),
      speaker: voice ? voice[1]!.trim() : null,
      text,
    };

    // Teams parte una misma intervención en muchos cues cortos: se unen los
    // consecutivos del mismo hablante para ahorrar tokens.
    const prev = segments.at(-1);
    if (prev && prev.speaker === seg.speaker) {
      prev.text += ` ${seg.text}`;
      prev.endSec = seg.endSec;
    } else {
      segments.push(seg);
    }
  }
  return segments;
}
