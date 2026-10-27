# Optimized previews para OBS Studio (macOS)

Plugin de OBS Studio para macOS que sustituye las previsualizaciones de OBS y
de Vertical Canvas (Aitum) por previsualizaciones de solo lectura presentadas
por Core Animation, **sin que el hilo gráfico de OBS espere nunca al
compositor de macOS**. Así las previsualizaciones dejan de provocar pérdidas
de fotogramas de render.

- **Optimized Preview:** el lienzo principal (horizontal).
- **Optimized Aitum Vertical Preview:** el canvas «Aitum Vertical» de
  Vertical Canvas, o cualquier otro canvas que elijas.

Pueden ocupar el mismo hueco que la previsualización nativa o ir en docks
propios. Son solo para visualizar: no permiten seleccionar ni mover fuentes.
Vertical Canvas es opcional: sin él, la previsualización horizontal funciona
igual.

## Por qué

En macOS con el renderizador OpenGL, OBS presenta cada previsualización
dentro de su hilo gráfico (`render_displays()` → `device_present()`:
`glFlush`, cambio de contexto, `glBlitFramebuffer` y
`[NSOpenGLContext flushBuffer]`). Ese hilo tiene que entregar un fotograma
cada 16,67 ms (a 60 FPS). Cuando la presentación espera al compositor, el
fotograma llega tarde y OBS lo pierde. Con una carga de producción exigente
(emisión multipista, grabación, varias salidas), las previsualizaciones
nativas pueden causar varios puntos porcentuales de fotogramas perdidos; sin
ellas, ninguno.

## Cómo funciona

```
Hilo gráfico de OBS (nunca espera)            Hilo principal (Qt/AppKit)
──────────────────────────────────            ──────────────────────────
render_main_texture() de cada mezcla          CADisplayLink de la preview
 └ callback «rendered» del plugin              ├ lee la última IOSurface lista
    ├ ¿la mezcla es el lienzo principal         │  (cerrojo de unas instrucciones;
    │  o el canvas vertical?                   │   el hilo gráfico solo usa trylock)
    ├ shader propio: textura del lienzo ──►    └ CALayer.contents = IOSurface
    │  IOSurface libre de un anillo de 8           (Core Animation la compone
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
- No modifica OBS ni otros plugins. El renderizado usa solo API pública de
  OBS 33; la integración en el hueco de las previews nativas se apoya además
  en detalles de Qt (ver [Limitaciones](#limitaciones)).

## Requisitos

- macOS 14 o posterior, Apple Silicon.
- OBS Studio 33.0.0 o posterior, con el renderizador **OpenGL**. Con Metal,
  las previsualizaciones muestran un aviso y no dibujan nada.
- Opcional: Vertical Canvas (Aitum) 1.6.x para la previsualización vertical.
- Para compilar: Xcode 16 o posterior y CMake 3.28 o posterior.

## Compilar

```sh
cmake --preset macos
cmake --build --preset macos
```

La primera configuración descarga en `.deps/` las fuentes de OBS 33.0.0 y las
dependencias precompiladas de OBS (obs-deps y Qt 6 del 23/10/2026, las mismas
que usa OBS 33.0.0), y compila libobs y obs-frontend-api. Tarda unos minutos.

Resultado: `build_macos/RelWithDebInfo/obs-optimized-previews.plugin`
(arm64, firma ad hoc).

### Bancos de pruebas

Se compilan junto al plugin y usan las bibliotecas de `/Applications/OBS.app`
(libobs y OpenGL). Arrancan libobs sin interfaz y sin leer la configuración
ni los perfiles de OBS. **No los ejecutes con OBS emitiendo**: los tres
primeros añaden carga a la GPU.

| Ejecutable | Qué comprueba |
|---|---|
| `build_macos/RelWithDebInfo/op-render-test` | Orientación, color sRGB, tamaño, canvas vertical frente a un señuelo del mismo tamaño, `video_reset`, límite de FPS, retirada del canvas y coste por callback. |
| `build_macos/RelWithDebInfo/op-dock-test` | La previsualización real en una ventana Qt durante 8 s: display link, `IOSurfaceIsInUse`, desacople del dock, latencia y cadencia. |
| `build_macos/RelWithDebInfo/op-copy-probe` | Coste en el hilo gráfico de varias formas de copiar una textura. |
| `build_macos/RelWithDebInfo/op-integration-test` | Integración en el hueco de la preview nativa con una réplica de los widgets de OBS y Vertical Canvas, y sin Vertical Canvas instalado. No usa la GPU. |

## Instalar

Con OBS cerrado:

```sh
mkdir -p ~/Library/Application\ Support/obs-studio/plugins
ditto build_macos/RelWithDebInfo/obs-optimized-previews.plugin ~/Library/Application\ Support/obs-studio/plugins/obs-optimized-previews.plugin
```

## Desinstalar

Con OBS cerrado:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugins/obs-optimized-previews.plugin
```

Para borrar también sus opciones guardadas:

```sh
rm -rf ~/Library/Application\ Support/obs-studio/plugin_config/obs-optimized-previews
```

## Configurar

### En el lugar de la previsualización nativa (recomendado)

Clic derecho sobre la previsualización de OBS o sobre la de Vertical Canvas
→ **Usar previsualización optimizada (solo lectura)**. El plugin desactiva
esa preview nativa y pone la suya en el mismo hueco. Para volver a la nativa,
clic derecho sobre la del plugin y desmarca la misma opción.

- La de OBS se desactiva con `obs_frontend_set_preview_enabled()`, y la de
  Vertical Canvas con sus atajos «Mostrar/Ocultar previsualización» (los
  mismos que se pueden lanzar desde obs-websocket).
- La elección se guarda y se reaplica al abrir OBS.
- En modo estudio no está disponible para la horizontal: OBS no permite
  desactivar su previsualización en ese modo. Si estaba activa, la nativa
  reaparece mientras dure el modo estudio.
- Si reactivas la nativa por otra vía (un atajo, por ejemplo), la del plugin
  deja de verse y de dibujar, pero la preferencia se conserva y se reaplica la
  próxima vez que abras OBS.

### Cambio automático (Herramientas → Previsualizaciones optimizadas…)

Cuatro casillas, todas desactivadas por defecto:

- Cambiar a la previsualización optimizada al iniciar la retransmisión.
- Cambiar a la previsualización optimizada al iniciar la grabación.
- Volver a la previsualización nativa al terminar la retransmisión.
- Volver a la previsualización nativa al terminar la grabación.

Se aplican a las dos previsualizaciones. Solo se vuelve a la nativa cuando no
queda ninguna retransmisión ni grabación de OBS en curso, para no reintroducir
pérdidas de fotogramas en la que siga activa. Las salidas propias de Vertical
Canvas (su retransmisión y grabación) no activan estos cambios.

### En docks propios

**Docks → Optimized Preview** y **Docks → Optimized Aitum Vertical Preview**
(en español, «Previsualización optimizada» y «Previsualización vertical de
Aitum optimizada»). Úsalos si prefieres otra disposición o si la integración
deja de funcionar con una versión futura de OBS o de Vertical Canvas. En ese
caso, desactiva a mano la preview de OBS (clic derecho → desmarca
**Habilitar previsualización**) y la de Vertical Canvas. Mientras una
previsualización está integrada, su dock muestra un aviso.

### Opciones de cada previsualización

Clic derecho sobre una previsualización del plugin:

- **Usar previsualización optimizada (solo lectura):** ver arriba.
- **Límite de fotogramas:** igual que OBS, 60, 30 o 20 FPS.
- **Canvas** (solo en la vertical): elige el canvas que se muestra.

Todas las opciones se guardan en
`~/Library/Application Support/obs-studio/plugin_config/obs-optimized-previews/settings.json`.

Una previsualización oculta (dock cerrado o en una pestaña no visible) no
dibuja nada; pasados 10 s, libera sus superficies.

## Medir

En el log de OBS:

- En el perfil al cerrar OBS: `op_rendered_callback` (todo el trabajo del
  plugin al terminar cada mezcla), `op_poll` (comprobación de fences al
  empezar cada mezcla), y dentro de ellas `op_preview_main`,
  `op_preview_vertical`, `op_verify_vertical_texture` y
  `op_recreate_surfaces`. Con las previews nativas apagadas,
  `render_displays` debería quedar prácticamente a cero.
- Al cerrar OBS, dos líneas por previsualización:
  - fotogramas publicados, fotogramas sin superficie libre y latencia media y
    máxima desde la composición hasta Core Animation;
  - fotogramas entregados a Core Animation, fotogramas sustituidos antes de
    mostrarse (llegaron dos entre dos refrescos de pantalla) y huecos de más de
    1,5 fotogramas entre imágenes nuevas.

Si notas saltos, esas cifras dicen si son descartes del plugin. A 60 FPS en
una pantalla de 144 Hz cada fotograma dura 2 o 3 refrescos alternos
(144/60 = 2,4), y ese ritmo irregular también afecta a la preview nativa.
A 120 Hz cada fotograma dura exactamente 2 refrescos.

Resultados del banco de pruebas en un Mac con Apple M4 Max (lienzo
2560×1440 y canvas vertical de 1080×1920, sin carga de OBS):

| Medida | Valor |
|---|---:|
| Coste por callback, mediana | 20–25 µs |
| Coste por callback, p99 | 0,17–0,47 ms |
| Latencia hasta Core Animation, media | 19–22 ms |

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
- La integración en el hueco nativo depende de detalles internos de Qt
  (nombres y clases de widgets de OBS 33 y Vertical Canvas 1.6.x, y de cómo
  abren sus menús contextuales), no de API pública. Si una actualización los
  cambia, la opción no aparece en el menú nativo y las previews del plugin
  siguen en sus docks.
- OBS tiene una carrera interna al cambiar la resolución de un canvas
  (`obs_canvas_reset_video()` pone `canvas->mix` a NULL fuera del mutex).
  El plugin evita leer la mezcla en cada fotograma, pero la verificación
  ocasional usa la misma API que la preview de Vertical Canvas.

## Licencia

GPL-2.0 o posterior (como OBS Studio). Basado en
[obs-plugintemplate](https://github.com/obsproject/obs-plugintemplate).
