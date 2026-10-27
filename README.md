# Non-Blocking Previews para OBS Studio (macOS)

Plugin de OBS Studio para macOS que sustituye las previsualizaciones de OBS y
de Vertical Canvas por dos docks propios, **sin que el hilo gráfico de OBS
espere nunca al compositor de macOS**. Con ellos ya no se pierden fotogramas
de render por culpa de las previsualizaciones.

- **Previsualización (sin bloqueo):** el lienzo principal (horizontal).
- **Previsualización vertical (sin bloqueo):** el canvas «Aitum Vertical» de
  Vertical Canvas, o cualquier otro canvas que elijas.

Son solo para visualizar: no permiten seleccionar ni mover fuentes.

## Por qué

En macOS con el renderizador OpenGL, OBS presenta cada previsualización
dentro de su hilo gráfico (`render_displays()` → `device_present()`:
`glFlush`, cambio de contexto, `glBlitFramebuffer` y
`[NSOpenGLContext flushBuffer]`). Ese hilo tiene que entregar un fotograma
cada 16,67 ms. Cuando la presentación espera al compositor, OBS pierde
fotogramas.

## Cómo funciona

```
Hilo gráfico de OBS (nunca espera)            Hilo principal (Qt/AppKit)
──────────────────────────────────            ──────────────────────────
render_main_texture() de cada mezcla          CADisplayLink del dock
 └ callback «rendered» del plugin              ├ lee la última IOSurface lista
    ├ ¿la mezcla es el lienzo principal         │  (cerrojo de unas instrucciones;
    │  o el canvas vertical?                   │   el hilo gráfico solo usa trylock)
    ├ shader propio: textura del lienzo ──►    └ CALayer.contents = IOSurface
    │  IOSurface libre de un anillo de 5           (Core Animation la compone
    ├ glFenceSync                                    fuera de OBS)
    └ fences anteriores con timeout 0:
       la más reciente terminada se publica
```

- Cada previsualización se dibuja **una vez por fotograma**, en el callback de
  su propia mezcla (el render target actual es su textura), justo después de
  componerse. No se vuelve a renderizar ninguna escena.
- El escalado es una sola pasada de un shader mínimo directamente sobre la
  IOSurface, con filtrado bilineal en espacio lineal y 4 muestras cuando se
  reduce a la mitad o más. Las texturas de IOSurface de libobs no admiten ser
  render target, así que el plugin usa FBOs propios con llamadas GL directas,
  guardando y restaurando todo el estado que toca. En las mediciones, esta vía
  costó tres veces menos que `glBlitFramebuffer` o que dibujar con libobs en
  una textura intermedia (`tests/copy-probe.mm`).
- Una superficie solo se reutiliza si su fence ya terminó, no es la publicada
  ni la mostrada, y `IOSurfaceIsInUse()` indica que WindowServer ya no la
  compone. Si no hay ninguna libre, se omite ese fotograma de la preview, nunca
  el de OBS.
- La textura del canvas vertical se identifica sin heurísticas de tamaño,
  porque Source Record y las mezclas multipista pueden crear otras iguales.
  Al enlazar una textura para dibujar, libobs-opengl siempre fija
  `GL_TEXTURE_SRGB_DECODE_EXT` en ella. El plugin marca el candidato, dibuja el
  canvas con la API pública `obs_render_canvas_texture_src_color_only()` en un
  objetivo de 2×2 y comprueba si la marca cambió. Se repite cada 5 s y tras
  cada `video_reset` del canvas.
- La referencia fuerte al canvas vertical la tiene siempre el hilo principal.
  Liberarla en el hilo gráfico, dentro del callback de render, interbloquearía
  `mixes_mutex`.
- Solo se usa API pública de OBS 33. No se modifica OBS ni otros plugins.

## Requisitos

- macOS 14 o posterior, Apple Silicon.
- OBS Studio 33.0.0 o posterior, con el renderizador **OpenGL**. Con Metal,
  los docks muestran un aviso y no dibujan nada.
- Para compilar: Xcode 16 o posterior y CMake 3.28 o posterior.

## Compilar

```sh
cmake --preset macos
cmake --build --preset macos
```

La primera configuración descarga en `.deps/` las fuentes de OBS 33.0.0 y las
dependencias precompiladas de OBS (obs-deps y Qt 6 del 23/10/2026, las mismas
que usa OBS 33.0.0), y compila libobs y obs-frontend-api. Tarda unos minutos.

Resultado: `build_macos/RelWithDebInfo/obs-nonblocking-previews.plugin`
(arm64, firma ad hoc).

### Bancos de pruebas

Se compilan junto al plugin y usan las bibliotecas de `/Applications/OBS.app`
(libobs y OpenGL). Arrancan libobs sin interfaz y sin leer tu configuración
ni tus perfiles. **No los ejecutes con OBS emitiendo**: añaden carga a la GPU.

| Ejecutable | Qué comprueba |
|---|---|
| `build_macos/RelWithDebInfo/nbp-render-test` | Orientación, color sRGB, tamaño, canvas vertical frente a un señuelo del mismo tamaño, `video_reset`, límite de FPS, retirada del canvas y coste por callback. |
| `build_macos/RelWithDebInfo/nbp-dock-test` | El dock real en una ventana Qt durante 8 s: display link, `IOSurfaceIsInUse`, desacople del dock y latencia. |
| `build_macos/RelWithDebInfo/nbp-copy-probe` | Coste en el hilo gráfico de varias formas de copiar una textura. |

## Instalar

Con OBS cerrado:

```sh
mkdir -p ~/Library/Application\ Support/obs-studio/plugins
ditto build_macos/RelWithDebInfo/obs-nonblocking-previews.plugin ~/Library/Application\ Support/obs-studio/plugins/obs-nonblocking-previews.plugin
```

## Desinstalar

Con OBS cerrado:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugins/obs-nonblocking-previews.plugin
```

Para borrar también sus opciones guardadas:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugin_config/obs-nonblocking-previews
```

## Configurar

1. Abre los docks en **Docks → Previsualización (sin bloqueo)** y **Docks →
   Previsualización vertical (sin bloqueo)**, y colócalos donde estaban las
   previsualizaciones de OBS.
2. Desactiva la previsualización de OBS: clic derecho sobre ella →
   desmarca **Habilitar previsualización**.
3. Desactiva la previsualización de Vertical Canvas en su dock.

Opciones (clic derecho sobre cada dock):

- **Límite de fotogramas:** igual que OBS, 60, 30 o 20 FPS por preview.
- **Canvas** (solo en el dock vertical): elige el canvas que se muestra.

Las opciones se guardan en
`~/Library/Application Support/obs-studio/plugin_config/obs-nonblocking-previews/settings.json`
(`main_fps`, `vertical_fps`, `vertical_canvas_name` y, opcionalmente,
`vertical_canvas_uuid`; si hay UUID tiene prioridad sobre el nombre).

Un dock oculto (cerrado o en una pestaña no visible) no dibuja nada. Pasados
10 s, libera sus superficies.

## Medir

En el log de OBS:

- En el perfil al cerrar OBS: `nbp_rendered_callback` (todo el trabajo del
  plugin al terminar cada mezcla), `nbp_poll` (comprobación de fences al
  empezar cada mezcla), y dentro de ellas `nbp_preview_main`,
  `nbp_preview_vertical`, `nbp_verify_vertical_texture` y
  `nbp_recreate_surfaces`. Con las previews de OBS apagadas,
  `render_displays` debería quedar prácticamente a cero.
- Al cerrar OBS, una línea por preview: fotogramas publicados, fotogramas sin
  superficie libre y latencia media y máxima desde la composición hasta
  Core Animation.

Resultados del banco de pruebas en el Mac Studio M4 Max (lienzo 2560×1440 y
canvas vertical de 1080×1920, sin carga de OBS):

| Medida | Valor |
|---|---:|
| Coste por callback, mediana | 20–25 µs |
| Coste por callback, p99 | 0,17–0,47 ms |
| Latencia hasta Core Animation, media | 19 ms |

## Limitaciones

- Solo el renderizador OpenGL. Con Metal, las previews no se dibujan.
- SDR: con un lienzo HDR (Rec. 2100), la imagen no se adapta con tonemapping
  como en la preview de OBS.
- Solo visualización: no se pueden seleccionar ni mover fuentes, ni hay
  guías, zonas seguras o modo estudio.
- El escalado es bilineal (con 4 muestras al reducir a la mitad o más), igual
  que la previsualización de OBS.
- La identificación del canvas vertical se basa en un comportamiento de
  libobs-opengl (el parámetro sRGB que fija al enlazar texturas), no en una
  función documentada. Si una versión futura lo cambia, la preview vertical
  dejará de dibujarse y el log mostrará «no se identifica la textura del
  canvas vertical». OBS no se verá afectado.
- Latencia: la imagen sale aproximadamente 1–1,5 fotogramas detrás de la
  composición, más el refresco del monitor.
- OBS tiene una carrera interna al cambiar la resolución de un canvas
  (`obs_canvas_reset_video()` pone `canvas->mix` a NULL fuera del mutex).
  El plugin evita leer la mezcla en cada fotograma, pero la verificación
  ocasional usa la misma API que la preview de Vertical Canvas.

## Licencia

GPL-2.0 o posterior (como OBS Studio). Basado en
[obs-plugintemplate](https://github.com/obsproject/obs-plugintemplate).
