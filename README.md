# Guía: app Java en Weston → GStreamer → MediaMTX → navegador (con control remoto)

Esta guía resume todo lo que hemos montado, cómo configurarlo, cómo usarlo y cómo depurarlo.

> **Estado honesto del proyecto:** los scripts se han comprobado solo a nivel de sintaxis.
> Lo que has probado tú y funciona: el vídeo con `glxgears` (con tirones), el arranque de
> MediaMTX y Weston, y la conexión del WebSocket de entrada tras esperar. Lo que **aún no está
> confirmado** es que el ratón y el teclado lleguen a la app. Ver la sección
> [Limitaciones y puntos abiertos](#limitaciones-y-puntos-abiertos).

---

## 1. Qué hace

1. **Weston** actúa como compositor ("manager") y renderiza con la **GPU** (`--renderer=gl`).
2. La salida de Weston se expone como un nodo de vídeo de **PipeWire**.
3. **GStreamer** lee ese nodo, lo codifica en H.264 y lo publica por RTSP en **MediaMTX**.
4. Desde el navegador se ve el vídeo por **WebRTC**.
5. Un **servidor de entrada** recibe ratón y teclado desde la página web y los inyecta
   en el Xwayland de Weston (solo ahí, sin tocar tu escritorio Plasma).

```
 App Java ─► Xwayland ─► Weston (GPU, backend PipeWire)
                              │
                       nodo PipeWire (vídeo)
                              │
                        GStreamer (pipewiresrc → H.264)
                              │ RTSP :8554
                          MediaMTX ──WebRTC :8889──► Navegador (remote.html)
                                                          │ ratón/teclado
                                                          ▼ WebSocket :8090
                                              input-server.py ─► XTEST ─► Xwayland
```

**Por qué se abandonó Xvfb:** Xvfb solo ofrece renderizado por software (llvmpipe), así que
una app 3D iría lenta. Por eso la versión final usa Weston con renderer GL sobre la GPU.

---

## 2. Archivos

Deben estar **en la misma carpeta** (salvo `viewer.html`, que es independiente):

| Archivo | Para qué sirve |
|---|---|
| `weston-gpu-mediamtx.sh` | Script principal: arranca todo |
| `input-server.py` | Recibe eventos del navegador y los inyecta en X. También sirve `remote.html` |
| `remote.html` | Interfaz web: vídeo + control de ratón/teclado |
| `viewer.html` | Solo visor del vídeo (sin control) |
| `weston-to-mediamtx.sh` | Primera versión con Xvfb (obsoleta, sin GPU 3D) |

---

## 3. Requisitos

### Arch Linux

```bash
sudo pacman -S weston xorg-xwayland pipewire wireplumber jq \
  gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly \
  gst-plugin-pipewire python-xlib python-aiohttp
# MediaMTX: binario desde https://github.com/bluenviron/mediamtx/releases (debe estar en el PATH)
```

### Debian / Ubuntu

```bash
sudo apt install weston xwayland pipewire jq \
  gstreamer1.0-tools gstreamer1.0-plugins-{base,good,bad,ugly} gstreamer1.0-pipewire \
  gstreamer1.0-rtsp python3-xlib python3-aiohttp
```

### Otros requisitos

- **Weston ≥ 12**, compilado con el backend PipeWire y el renderer GL. Comprueba con
  `weston --help | grep -i backend`. Los nombres de las opciones pueden variar entre versiones.
- **Java 11 o superior** (`java -version`).
- Acceso a la GPU: tu usuario en el grupo `render` / `video`.
- `kiosk-shell.so` (Weston 9 o superior) para el modo kiosko.

Comprobación rápida de dependencias de Python:

```bash
python3 -c 'import Xlib, aiohttp' && echo OK
```

Si falta alguna, el script **se salta el servidor de entrada** y solo muestra
`Skipping browser control`.

---

## 4. Uso

```bash
chmod +x unido.sh input-server.py
```

### Apps de prueba

```bash
# 1) Un .jar normal (el script lo ejecuta con `java -Djava.awt.headless=false -jar`)
./unido.sh ./josm-tested.jar

# 2) WorldWind (globo 3D de la NASA): lanzar desde la carpeta extraída
cd ~/WorldWindJava-2.2.1
X11_ONLY=1 /ruta/a/unido.sh sh run-demo.bash

# 3) Prueba de GPU sencilla
./unido.sh glxgears
```

### Con depuración activada

```bash
INPUT_DEBUG=1 X11_ONLY=1 ./unido.sh sh run-demo.bash
```

### Qué debe mostrar la terminal

```
[*] Weston is up.
[*] Weston's Xwayland display: :1
[*] Starting input server on port 8090...
[*] Using PipeWire node NN
[*] Publishing to rtsp://127.0.0.1:8554/desktop
[*] Video only:        http://<ip>:8889/desktop
[*] Interactive (use): http://<ip>:8090/
```

Espera a ver `Starting input server...` **antes** de abrir la página. Si no, el navegador
muestra `NS_ERROR_WEBSOCKET_CONNECTION_REFUSED` hasta que el servidor está listo (se
reconecta solo cada 2 segundos).

---

## 5. Direcciones del navegador

| URL | Función |
|---|---|
| `http://localhost:8090/` | **Interfaz interactiva** (vídeo + control) |
| `http://localhost:8090/?debug=1` | Lo mismo, con panel de depuración |
| `http://localhost:8889/desktop` | Solo vídeo (reproductor de MediaMTX) |
| `http://localhost:8888/desktop` | Solo vídeo por HLS (más retardo) |
| `rtsp://localhost:8554/desktop` | Para probar con `ffplay` o VLC |

**No abras `http://0.0.0.0:8090`**: esa es la dirección donde escucha el servidor, no una
dirección a la que se pueda entrar. Los navegadores la bloquean.

Parámetros opcionales de la página: `?host=`, `?path=`, `?webrtc=`, `?input=`, `?token=`, `?debug=1`.

### Cómo usar la interfaz

1. Haz clic en el vídeo. El borde se pone azul (la página tiene el foco).
2. Los indicadores **video** y **control** de la barra deben estar en verde.
3. Mueve el ratón, haz clic, usa la rueda y escribe. Los atajos reservados del navegador
   (Ctrl+W, F5…) no se pueden capturar.

---

## 6. Variables de entorno

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `WIDTH`, `HEIGHT` | `1280`, `720` | Resolución de Weston (números pares) |
| `FPS` | `30` | Fotogramas por segundo |
| `BITRATE` | `4000` | kbit/s |
| `ENCODER` | `x264enc` | `x264enc`, `nvh264enc`, `vah264enc` o `vaapih264enc` |
| `SHELL_MODE` | `kiosk` | `kiosk` = la app a pantalla completa; `desktop` = escritorio con panel y terminal |
| `X11_ONLY` | `0` | `1` para scripts que lanzan Java por dentro (`run-demo.bash`) |
| `INPUT` | `1` | `0` desactiva el servidor de control |
| `INPUT_PORT` | `8090` | Puerto de la interfaz |
| `INPUT_HOST` | `0.0.0.0` | `127.0.0.1` para solo uso local |
| `INPUT_TOKEN` | vacío | Clave; abrir con `?token=CLAVE` |
| `INPUT_DEBUG` | vacío | `1` activa logs detallados y diagnóstico en la página |
| `DEBUG_SNAPSHOT` | `0` | `1` guarda un fotograma en `/tmp/frame.png` |
| `RENDER_NODE` | `/dev/dri/renderD128` | Solo comprueba permisos; **no** se pasa a Weston (ver sección 9) |
| `NODE_MATCH` | `weston\|pipewire` | Expresión para localizar el nodo PipeWire de Weston |
| `STREAM_PATH` | `desktop` | Nombre del stream en MediaMTX |

Ejemplo con más calidad: `WIDTH=1920 HEIGHT=1080 FPS=60 BITRATE=8000 ENCODER=nvh264enc ./unido.sh ...`

---

## 7. Logs y archivos temporales

| Ruta | Contenido |
|---|---|
| `/tmp/weston-app.log` | Salida y errores de tu app |
| `/tmp/weston-run.log` | Log de Weston (se copia al terminar) |
| `/tmp/weston-input.log` | Log del servidor de entrada |
| `/tmp/weston-xdisplay` | Display X de Weston (por ejemplo `:1`) |
| `/tmp/frame.png` | Fotograma capturado (solo con `DEBUG_SNAPSHOT=1`) |

---

## 8. Depuración paso a paso

### A. El vídeo no se ve (negro)

1. Comprueba que el script llegó a `Publishing to rtsp://...` y sigue en marcha.
2. Prueba fuera del navegador: `ffplay rtsp://localhost:8554/desktop`.
3. Ejecuta con `DEBUG_SNAPSHOT=1` y abre `/tmp/frame.png` para ver qué sale de Weston:
   - la imagen muestra la app: la captura funciona; mira MediaMTX/WebRTC;
   - negro: Weston no renderiza o la app no está dentro (revisa `/tmp/weston-run.log` y `/tmp/weston-app.log`);
   - sin PNG: el nodo PipeWire no entrega frames o es otro nodo (el script imprime su nombre).
4. Si Weston solo emite frames cuando la pantalla cambia, un contenido estático da vídeo negro. El script ya usa `keepalive-time` para reenviar el último fotograma.

### B. Los clics no llegan a la app

Abre `http://localhost:8090/?debug=1`, haz clic y mira el panel:

| Qué ves | Dónde falla |
|---|---|
| `WS: cerrado` o `descartados` crece | El WebSocket no conecta (puerto, token) |
| `enviados: move=0` | La página no captura eventos (¿foco? ¿`video: 0x0`?) |
| `enviados` crece pero el log del servidor está vacío | El mensaje no llega al servidor |
| El log muestra eventos pero la app no reacciona | Falla la inyección en X |

La línea **`servidor/X`** (aparece al hacer clic o pulsar una tecla) muestra lo que ve el
servidor X de Weston:

- `puntero X=[..]` no cambia al mover el ratón: no llega la inyección XTEST.
- `ventana bajo el puntero: None`: el puntero no está sobre la app (¿display equivocado?).
- `foco de teclado: None` o `PointerRoot`: el ratón puede funcionar pero el teclado no.

### C. Autotest sin navegador

Con el script y la app en marcha, en otra terminal:

```bash
python3 input-server.py --display "$(cat /tmp/weston-xdisplay)" --selftest
```

Mueve el puntero al centro y hace clic. Si la app reacciona, el fallo está en el
navegador o en el WebSocket; si no, en cómo Weston/Xwayland recibe la entrada.

### D. Comprobar que el servidor está corriendo

```bash
ss -ltnp | grep 8090
curl -I http://localhost:8090/
cat /tmp/weston-input.log
```

Se puede arrancar a mano (con Weston y la app ya en marcha):

```bash
python3 input-server.py --display "$(cat /tmp/weston-xdisplay)" --debug
```

### E. Fluidez (tirones)

- Mira `top`: `x264`/`gst-launch` al 100 % = cuello de botella en la codificación;
  `java` al 100 % = la app; todo bajo = Weston o PipeWire.
- Baja la carga (720p/30 fps ya es el valor por defecto) o usa un codificador por hardware.
- `glxgears` es una mala prueba (dibuja sin límite); usa WorldWind o JOSM moviendo el mapa.

---

## 9. GPU NVIDIA (RTX 5070) con CPU Intel

La CPU casi no importa para el 3D; lo que importa es que **render y codificación usen la 5070**.

Comprueba qué GPU renderiza la app (con el script en marcha):

```bash
DISPLAY=$(cat /tmp/weston-xdisplay) glxinfo -B | grep -E "OpenGL renderer|OpenGL vendor"
nvidia-smi        # debe mostrar procesos java/weston usando la GPU
```

- `NVIDIA GeForce RTX 5070`: correcto.
- `llvmpipe`: renderizado por CPU (explicaría los tirones).
- `Mesa Intel...`: está usando la gráfica integrada.

**Punto débil conocido:** la variable `RENDER_NODE` solo comprueba permisos, **no se
la pasa a Weston**. En un equipo Intel + NVIDIA, `renderD128` puede ser la integrada. Para
identificar cada nodo:

```bash
for d in /dev/dri/renderD*; do echo -n "$d: "; udevadm info -q property -n $d | grep ID_PATH=; done
```

Para codificar con la GPU: `gst-inspect-1.0 nvh264enc` y luego `ENCODER=nvh264enc ./unido.sh ...`
(`nvidia-smi dmon -s u` muestra la columna `enc` con uso).

---

## 10. Seguridad

El puerto 8090 permite **controlar la app** a quien pueda llegar a él.

- Solo uso local: `INPUT_HOST=127.0.0.1`.
- Acceso desde otra máquina: `INPUT_TOKEN=clave` y abrir `http://<ip>:8090/?token=clave`.
- No expongas 8090 ni 8889 a internet sin autenticación; añade HTTPS y usuario/contraseña en MediaMTX si lo necesitas.
- Firewall para uso en red: 8889/tcp y 8189/udp (WebRTC), 8090/tcp (control).

---

## 11. Qué hemos hecho (cronología)

1. **Versión inicial (Xvfb):** Weston anidado sobre Xvfb + `ximagesrc` → x264 → MediaMTX.
   Descartada porque Xvfb no da aceleración 3D.
2. **Versión GPU:** Weston con backend PipeWire y renderer GL; GStreamer lee el nodo con
   `pipewiresrc`.
3. **Bug del script que salía en silencio** tras `Using PipeWire node`: `hostname -I` no existe
   en tu sistema y, con `set -euo pipefail`, abortaba. Se sustituyó por `ip route`.
4. **`.jar` no ejecutable directamente:** el script ahora lo lanza con `java -jar`.
5. **La app no aparecía en Weston:** faltaba el `DISPLAY` de Xwayland. Se adoptó tu idea de
   detectar el socket X nuevo en `/tmp/.X11-unix` comparando antes y después de arrancar Weston.
   Java se lanza solo contra ese display (`env -u WAYLAND_DISPLAY DISPLAY=...`).
6. **Modo kiosko:** `kiosk-shell.so` para que la app llene toda la pantalla de Weston.
7. **Pantalla negra:** se añadió `keepalive-time` en `pipewiresrc` y `DEBUG_SNAPSHOT`.
8. **Tirones:** valores por defecto bajados a 720p/30 fps y dos `queue leaky=downstream`.
9. **Interfaz interactiva:** `remote.html` + `input-server.py` (WebSocket → XTEST), integrada
   en el script principal.
10. **Depuración de eventos:** panel `?debug=1`, logs detallados, respuesta de diagnóstico
    del servidor X y `--selftest`.
11. **Aclaraciones:** `0.0.0.0` no es una URL navegable; el `CONNECTION_REFUSED` inicial era
    por el orden de arranque (el servidor es lo último en levantarse).
12. **App 3D de prueba:** NASA WorldWind Java 2.2.1 (`sh run-demo.bash`) y JOSM como app de mapas 2D.

---

## 12. Limitaciones y puntos abiertos

- **Sin probar por mi parte:** los scripts solo se han comprobado a nivel de sintaxis.
- **Opciones de Weston:** el backend PipeWire y las banderas exactas (`--backend=pipewire`,
  selección de GPU) pueden variar entre versiones. Si falla la línea de `weston`, revisa
  `weston --help`.
- **Entrada y teclado (sospecha, sin confirmar):** el backend PipeWire de Weston puede no
  tener dispositivo de entrada, de modo que Xwayland no daría foco de teclado a la app. Se
  vería como "el ratón funciona a veces y el teclado no". La línea `servidor/X` del panel de
  depuración lo confirmaría o lo descartaría; la solución sería dar a Weston una entrada virtual.
- **Solo apps X11 reciben control:** las apps nativas de Wayland dentro de Weston no recibirían
  los eventos inyectados por XTEST.
- **Selección de GPU:** `RENDER_NODE` no se aplica a Weston (ver sección 9).
- **WorldWind:** necesita internet para las imágenes y, según la documentación de la versión
  2.2.1, se quitaron referencias a servicios que los servidores de WorldWind ya no ofrecen;
  alguna capa puede no cargar.
- **Portapapeles, audio y varios monitores:** no están implementados.

---

## 13. Referencia rápida

```bash
# Arranque normal
./unido.sh ./miapp.jar

# Arranque con depuración y WorldWind
cd ~/WorldWindJava-2.2.1
INPUT_DEBUG=1 X11_ONLY=1 /ruta/a/unido.sh sh run-demo.bash

# Abrir en el navegador
http://localhost:8090/?debug=1

# Diagnóstico
ss -ltnp | grep 8090
cat /tmp/weston-input.log /tmp/weston-app.log /tmp/weston-run.log
python3 input-server.py --display "$(cat /tmp/weston-xdisplay)" --selftest
```
## 14. Cosas posibles
   Ver en diferentes dispositivos y controlar desde los diferentes dispositivos, además de ver lo que hace una persona en remoto