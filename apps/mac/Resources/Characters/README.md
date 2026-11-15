# Personajes de Asistent IA

Cada personaje es una carpeta con uno o varios archivos `.usdz` (todos con el **mismo
esqueleto**) y, opcionalmente, un `character.json`. Se importa desde
**Ajustes → Personaje → Importar carpeta…** o copiando la carpeta aquí.

## Estados

`idle` (tranquilo), `listening` (grabando), `thinking` (transcribiendo o analizando),
`talking` (aviso), `happy` (sesión creada, análisis listo), `sad` (error),
`alert` (micrófono, grabación interrumpida), `sleeping` (10 min sin actividad).

Si la carpeta no trae `character.json`, se genera uno mapeando los archivos por nombre:
`idle.usdz`, `listening.usdz`, `think.usdz`, `talk.usdz`, `happy.usdz` (o `jump`, `dance`),
`sad.usdz`, `wave.usdz` (o `alert`), `sleep.usdz`. Los estados que falten usan otro
(`happy` → `talking` → `idle`, etc.).

## Reacciones y más animaciones

Además de los estados, el personaje puede hacer **gestos sueltos**: al hacerle clic en la
cabeza, el cuerpo o los pies (`head`, `body`, `feet`), al azar cada cierto tiempo (`random`),
al aparecer (`greet`), al despertar (`wake`) y mientras se arrastra (`drag`).

Todo se configura en la app, sin editar archivos: **Ajustes → Personaje → Animaciones del
personaje…** (o menú del personaje → **Animaciones…**). Ahí se importan más `.usdz`, se
asignan a un estado o a una reacción, se prueban y se ajusta velocidad, recorte, zonas de
clic e intervalo de los gestos al azar. Cada estado o reacción admite varias animaciones.

En `character.json` queda así (opcional):

```json
"reactions": { "head": ["pat.usdz", { "file": "dizzy.usdz", "speed": 1.5 }], "feet": "kick.usdz",
               "random": ["stretch.usdz", "yawn.usdz"], "greet": "wave.usdz", "drag": "hang.usdz" },
"behavior": { "randomEnabled": true, "randomEvery": [45, 120], "headZone": 0.22, "feetZone": 0.2 }
```

## character.json

```json
{ "format": 1, "id": "robi", "name": "Robi",
  "base": "robi.usdz",
  "clips": { "idle": ["idle.usdz", "idle2.usdz"], "listening": "listen.usdz",
             "thinking": { "file": "think.usdz", "start": 0, "end": 2.5 },
             "talking": "talk.usdz", "happy": "jump.usdz", "sad": "sad.usdz",
             "alert": "wave.usdz", "sleeping": "sleep.usdz" },
  "scale": 1.0,
  "fallbacks": { "listening": "idle", "happy": "talking" } }
```

- `base`: modelo con el esqueleto (si falta, se usa el primer clip).
- Un clip puede ser un archivo entero o un recorte en segundos de uno solo.
- La app encuadra sola cada personaje para que llene el cuadro. `scale` es un zoom sobre ese encuadre (1.2 acerca, 0.9 aleja).
- `aspect` (opcional) es la proporción del cuadro en pantalla, ancho ÷ alto, entre 0.4 y 1.2. Sin ella vale 0.55 (humanoide de pie); súbela si las animaciones se cortan a los lados. También se cambia en Ajustes → Personaje → Proporción.
- `camera` (opcional, `{ "distance": 3, "height": 0.8 }`) reemplaza el encuadre automático; normalmente no hace falta.

## Por qué un archivo por estado

RealityKit (lo que usa la app) solo carga USD/USDZ y no lista de forma fiable varias
animaciones esqueléticas dentro de un mismo archivo. Un `.usdz` por animación, todos con el
mismo esqueleto, funciona siempre.

## De dónde sacar personajes

| Fuente | Entrega | Cómo llevarlo a USDZ |
|---|---|---|
| Unity Asset Store | `.unitypackage` (tar.gz con FBX y texturas) | Extraer con `unitypackage_extractor` o abrir en Unity → FBX → Blender |
| Fab (Epic / Unreal) | FBX, glTF, OBJ, USD/USDZ desde "Fab in Launcher" | Elegir USD o glTF; `.uasset` antiguos → Unreal Editor → Export FBX |
| Blender Market / BlenderKit | `.blend` | Exportar USDZ directo |
| CGTrader / TurboSquid | FBX, glTF, a veces USDZ | Preferir glTF o USDZ |
| Mixamo (gratis) | FBX rigeado + animaciones con el mismo esqueleto | Un FBX por animación → Blender |

## Convertir con Blender (gratis)

1. `File → Import` el FBX / glTF / OBJ del personaje.
2. Por cada estado: asigna la acción (o el clip de Mixamo), fija el rango de frames y
   `File → Export → Universal Scene Description` con extensión `.usdz`, opciones
   **Animation** ✓, **Only Deform Bones** ✓, **Convert Orientation** Y-up,
   texturas ≤ 1024 (*USDZ Texture Downsampling*).
3. Comprueba cada archivo con `usdchecker archivo.usdz` (macOS 26 trae las Apple USD Tools).
4. Pon los `.usdz` en una carpeta e impórtala desde Ajustes.

Alternativas: Reality Converter (beta 6; glTF/OBJ/USD, no FBX) o apps de conversión del
App Store. Revisa la licencia de cada tienda antes de usar un modelo.
