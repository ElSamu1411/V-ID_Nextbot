# Documento de Gestión de Assets y Recursos Multimedia 

**Objetivo:** Establecer las especificaciones técnicas estrictas para la compilación de texturas y exportación de audios, asegurando la compatibilidad absoluta con el motor Source (Garry's Mod) y previniendo errores de renderizado o reproducción espacial. 

## 1. Especificaciones de Texturas (.vtf - Valve Texture Format) 

- **Archivos Fuente:** Se utilizarán las imágenes originales face_1_VOID.jpg (Estado Base) y face_2_VOID.jpg (Estado Hiperagresivo). Dado que el formato JPG no soporta transparencia, el primer paso obligatorio es recortar el fondo negro digitalmente y guardar el resultado como un PNG de 32 bits (RGBA). 

- **Resolución Base (Power of Two):** El lienzo de las imágenes debe estar estrictamente configurado a **1024x1024 píxeles** . Esta resolución asegura una alta nitidez al acercarse al jugador sin sobrecargar la memoria de video del servidor. Los rostros deben centrarse dentro de este lienzo cuadrado, dejando el espacio sobrante completamente vacío (transparente), sin estirar la imagen para no deformar las proporciones. 

- **Canal Alfa y Formato de Compresión:** Al compilar los PNG resultantes a .vtf, se utilizará el formato de compresión **DXT5** (o RGBA8888 si se requiere cero pérdida visual), siendo el estándar del motor para manejar canales alfa limpios. 

- **Banderas (Flags) de Compilación (VTFEdit):** 

   - **Clamp S y Clamp T:** Obligatorio. Evita el efecto de mosaico (tiling) y la repetición de líneas de píxeles en los bordes. 

   - **No Level Of Detail (No LOD):** Evita que el motor reduzca la resolución de la textura automáticamente a la distancia. 

   - **No Mipmap:** Innecesario para un plano 2D; evita el consumo de memoria extra y el emborronamiento a distancias medias. 

## 2. Parámetros del Material (.vmt - Valve Material Type) 

- **Sombreador (Shader):** Se usará obligatoriamente UnlitGeneric. Este sombreador ignora la iluminación global del mapa, garantizando que el rostro blanco de alto contraste de VØID mantenga su luminosidad intacta en lugares oscuros, reforzando su factor psicológico. 

- **Variables Clave y Código Base:** Se crearán dos archivos de texto plano .vmt que acompañarán a las imágenes compiladas. 

**Código para face_1_VOID.vmt (Estado Base):** 

None "UnlitGeneric" { "$basetexture" "entities/npc_void/face_1_VOID" "$translucent" 1 "$nocull" 1 } 

**Código para face_2_VOID.vmt (Estado Hiperagresivo):** 

None "UnlitGeneric" { "$basetexture" "entities/npc_void/face_2_VOID" "$translucent" 1 "$nocull" 1 } 

_(Nota técnica: $translucent 1 procesa el canal alfa haciendo invisible el fondo. $nocull 1 desactiva el backface culling, asegurando que VØID sea visible desde la parte frontal y trasera de su plano)._ 

## 3. Especificaciones de Audio (Formatos y Metadatos) 

- **Codificación y Frecuencia:** Todos los archivos se exportarán en formato **.mp3** con una frecuencia de muestreo obligatoria de **44100 Hz** y codificación **CBR (Constant Bitrate)** para evitar errores de lectura y desincronización en el motor. Una tasa de bits de 128 kbps a 192 kbps es la óptima. 

- **Espacialidad y Nivel de Atenuación (SoundLevel):** 

   - **Audios Espaciales (Audio 3D direccional):** sonido_fondo_VOID.mp3, sonido_persecucion_VOID.mp3, stalking_lento_sonido_VOID.mp3 y todos los sonido_aleatorio_X_VOID.mp3. Emitidos desde la entidad, el motor aplicará atenuación por distancia (SoundLevel estándar de 75 a 85 dB), permitiendo al jugador ubicar al Nextbot por el sonido. 

   - **Audios Globales (Invasivos):** sonido_hiperagresividad_VOID.mp3 y grito_hiperagresividad_VOID.mp3. Para garantizar que se escuchen en todo el mapa de forma aterradora sin importar la distancia, el código Lua deberá emitirlos utilizando el nivel de atenuación SNDLVL_NONE (0), o preferiblemente, enviarse a través de mensajes de red para que se reproduzcan directamente en el cliente mediante surface.PlaySound o sound.PlayFile. 

- **Etiquetas de Bucle (Loop Cues) y Estrategia Lua:** Dado que los .mp3 no soportan los metadatos de bucle nativos del motor Source (solo los .wav lo hacen), la reproducción continua del estado "Idle" y "Chase" se controlará puramente mediante 

código Lua, gestionando los tiempos de duración de la pista para relanzarla sin saltos perceptibles. 

## 4. Estructura de Directorios (Rutas de Archivos) 

- **Jerarquía de Carpetas:** Para que el código Lua encuentre todos los recursos de VØID automáticamente, el addon (que llamaremos void_nextbot) debe seguir estrictamente esta estructura de árbol dentro del directorio addons/ del juego: 

None void_nextbot/ `├──` materials/ `│ └──` entities/ `│ └──` npc_void/ `│ ├──` face_1_VOID.vtf `│ ├──` face_1_VOID.vmt `│ ├──` face_2_VOID.vtf `│ └──` face_2_VOID.vmt `├──` sound/ `│ └──` npc_void/ `│ ├──` sonido_fondo_VOID.mp3 `│ ├──` sonido_persecucion_VOID.mp3 `│ ├──` sonido_hiperagresividad_VOID.mp3 `│ ├──` grito_hiperagresividad_VOID.mp3 `│ ├──` stalking_lento_sonido_VOID.mp3 `│ ├──` sonido_aleatorio_1_VOID.mp3 `│ ├──` sonido_aleatorio_2_VOID.mp3 `│ └──` (etc...) `└──` lua/ `└──` entities/ `└──` npc_void/ `├──` shared.lua `├──` init.lua `└──` cl_init.lua 

_(Nota: Los archivos originales face_1_VOID.jpg y face_2_VOID.jpg no se incluyen en esta carpeta final, ya que el motor solo lee sus versiones compiladas .vtf)._ 

