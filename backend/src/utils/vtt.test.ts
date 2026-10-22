import { describe, expect, it } from "vitest";
import { parseVtt } from "./vtt.js";

const TEAMS_VTT = `WEBVTT

0f5e1c2a-1
00:00:01.000 --> 00:00:03.500
<v Ana López>Buenos días, empezamos con la daily.</v>

0f5e1c2a-2
00:00:03.500 --> 00:00:05.000
<v Ana López>Carlos, ¿cómo vas?</v>

0f5e1c2a-3
00:00:05.200 --> 00:01:02.000
<v Carlos Ruiz>Terminé el endpoint de pagos,
hoy sigo con los tests.</v>

NOTE comentario que se ignora
`;

describe("parseVtt", () => {
  it("extrae hablantes, tiempos y une cues consecutivos del mismo hablante", () => {
    const segs = parseVtt(TEAMS_VTT);
    expect(segs).toEqual([
      { startSec: 1, endSec: 5, speaker: "Ana López", text: "Buenos días, empezamos con la daily. Carlos, ¿cómo vas?" },
      { startSec: 5.2, endSec: 62, speaker: "Carlos Ruiz", text: "Terminé el endpoint de pagos, hoy sigo con los tests." },
    ]);
  });

  it("acepta cues sin hablante, horas y CRLF", () => {
    const segs = parseVtt("WEBVTT\r\n\r\n01:00:00.000 --> 01:00:02,000\r\nHola\r\n");
    expect(segs).toEqual([{ startSec: 3600, endSec: 3602, speaker: null, text: "Hola" }]);
  });

  it("devuelve vacío si no hay cues", () => {
    expect(parseVtt("WEBVTT\n\nNOTE nada")).toEqual([]);
  });
});
