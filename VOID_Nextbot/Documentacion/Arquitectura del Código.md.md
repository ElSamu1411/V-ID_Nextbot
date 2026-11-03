# Documento 6: Arquitectura del Código y Estructura de Scripts 

**Objetivo:** Definir la distribución técnica del código Lua para la entidad npc_void. En el motor Source, la optimización exige separar la lógica en tres dominios: Compartido (Shared), Servidor (Server) y Cliente (Client). Este documento establece qué sistemas van en cada archivo para prevenir desincronizaciones ( _prediction errors_ ), asegurar que el Árbol de Comportamiento funcione fluidamente y mostrar la estructura exacta del entorno de trabajo en el IDE. 

## 1. Visualización del Proyecto en el IDE (Workspace) 

Al abrir tu IDE (Antigravity) para comenzar a programar a VØID, tu explorador de archivos (File Explorer) en el panel izquierdo deberá lucir exactamente con esta jerarquía. Esta estructura es obligatoria para que Garry's Mod detecte el addon, los materiales y los audios correctamente, tal como validamos en el Documento 2. 

None 📦 Workspace: Garry's Mod Addons `└──` 📂 void_nextbot `├──` 📂 materials `│ └──` 📂 entities `│ └──` 📂 npc_void `│ ├──` 🖼 face_1_VOID.vtf     (Textura Base) `│ ├──` 📄 face_1_VOID.vmt     (Material Base UnlitGeneric) `│ ├──` 🖼 face_2_VOID.vtf     (Textura Hiperagresiva) `│ └──` 📄 face_2_VOID.vmt     (Material Hiperagresivo UnlitGeneric) `├──` 📂 sound `│ └──` 📂 npc_void `│ ├──` 🎵 sonido_fondo_VOID.mp3 `│ ├──` 🎵 sonido_persecucion_VOID.mp3 `│ ├──` 🎵 sonido_hiperagresividad_VOID.mp3 `│ ├──` 🎵 grito_hiperagresividad_VOID.mp3 `│ ├──` 🎵 stalking_lento_sonido_VOID.mp3 `│ ├──` 🎵 sonido_aleatorio_1_VOID.mp3 `│ └──` 🎵 sonido_aleatorio_2_VOID.mp3 `└──` 📂 lua `└──` 📂 entities `└──` 📂 npc_void `├──` 📜 shared.lua          (Variables globales y Red) `├──` 📜 init.lua            (IA y Cerebro Server-Side) 

`└──` 📜 cl_init.lua         (Renderizado y Audio Client-Side) 

## 2. Dominio Compartido (shared.lua) 

Este archivo se ejecuta tanto en el servidor como en el cliente. Su función principal es establecer la identidad de la entidad, las constantes de configuración y las variables de red (NetworkVars) para que ambos lados estén sincronizados. 

- **Definición de Entidad:** 

   - ENT.Base = "base_nextbot" 

   - ENT.Type = "nextbot" 

- **Tabla de Configuración (VOID_CONFIG):** 

   - Aquí se alojarán de forma estricta todas las constantes del Documento 4 (ej. VOID_CONFIG.speed_patrol = 150, VOID_CONFIG.duration_idle_loop = 45.0). Centralizarlas aquí permite que cliente y servidor las lean sin discrepancias. 

- **Sincronización de Red (ENT:SetupDataTables):** 

   - self:NetworkVar("Bool", 0, "IsHyper"): Define si VØID está en estado Hiperagresivo. El servidor lo activa (Prioridad 2), el cliente lo lee para cambiar el material face_2_VOID.vmt. 

   - self:NetworkVar("Entity", 0, "CurrentTarget"): Expone quién es la presa actual. 

- **Hook de Inmovilización (Parálisis por Acecho):** 

   - La intercepción de controles **debe** ir en shared.lua. Si solo bloqueas el movimiento en el servidor, el cliente intentará predecir el movimiento, causando un error de _rubberbanding_ (tirones). 

   - _Lógica:_ hook.Add("SetupMove", "VoidParalysis", function(ply, mvd, cmd) -> Si ply:GetNWBool("VoidParalyzed") == true, entonces forzar mvd:SetForwardSpeed(0) y mvd:SetSideSpeed(0), pero permitir el giro de cámara. 

## 3. Dominio del Servidor (init.lua) 

El archivo más pesado. Solo el servidor procesa esto. Aquí reside la tabla multijugador, la validación de físicas y el Árbol de Comportamiento dictado en el Documento 5. 

- **Inicialización Física (ENT:Initialize):** 

   - Aplicar colisiones exactas: 

      - self:SetCollisionBounds(VOID_CONFIG.hull_mins, VOID_CONFIG.hull_maxs). 

   - Configurar locomoción: Inyectar acceleration = 2000, deceleration = 4000, step_height = 24 en el objeto self.loco. 

   - Inicializar la tabla PlayerState para el sistema multijugador. 

- **El Cerebro (ENT:RunBehaviour):** 

   - Esta es la corrutina nativa del Nextbot. Su estructura será un bucle while 

      - (true) do que invoca 

coroutine.wait(VOID_CONFIG.tick_rate_brain) (0.25s). 

   - Dentro de este bucle se programan las 8 secuencias lógicas del Documento 5. El código evaluará los Selectores (Prioridad 1 Anti-Stuck, Prioridad 2 Hiperagresividad...) saltando de una a otra en caso de devolver un fallo en la condición. 

- **Eventos Asíncronos (Hooks Servidor):** 

   - ENT:OnTakeDamage(dmginfo): Intercepta todo daño. Obliga dmginfo:SetDamage(0). Valida con 

      - dmginfo:GetAttacker():IsPlayer() o GetPhysicsAttacker(). Si es válido, drena paciencia a 0. 

   - hook.Add("KeyPress", "VoidTeabagDetect"): Escucha de forma asíncrona la tecla IN_DUCK, valida la Línea de Visión (LOS) y distancia, y actualiza PlayerState[ply].crouch_count. 

## 4. Dominio del Cliente (cl_init.lua) 

Este código se envía y ejecuta en la computadora de cada jugador. Es ligero y maneja exclusivamente el _feedback_ audiovisual sin lógica de persecución. 

- **Gestión Visual y Material Swap (ENT:DrawTranslucent):** 

   - Dado que VØID requiere transparencias en los bordes, el renderizado se ancla aquí. 

   - _Lógica:_ El cliente consulta self:GetIsHyper() por frame. 

      - Si es false: Renderiza face_1_VOID.vmt. 

      - Si es true: Renderiza face_2_VOID.vmt. 

   - Se requiere matemática vectorial (EyeAngles():Up() y Right()) para que el Sprite 2D rote continuamente en modo Billboard, mirando siempre a la cámara del cliente. 

- **Receptores de Audio Global (net.Receive):** 

- Los audios globales invasivos (el grito hiperagresivo) NO deben usar EmitSound() en el servidor debido a la atenuación de 75dB de Source. 

- El servidor ejecutará net.Start("Void_PlayGlobalAudio") y net.Broadcast(). 

- Este archivo intercepta el mensaje con net.Receive y ejecuta surface.PlaySound("npc_void/grito_hiperagresividad_VOID.mp3" ) o sound.PlayFile(), forzando el volumen al 100% en los oídos del jugador. 

## 5. Arquitectura de Memoria y Mensajería (Networking) 

Para enlazar los tres dominios sin que existan variables sobrescritas (especialmente en cooperativo): 

- **Registro de Mensajes:** En init.lua, usar obligatoriamente util.AddNetworkString("Void_PlayGlobalAudio"). 

- **Gestión de PlayerState:** 

   - Almacenada globalmente en init.lua. 

   - Hook PlayerInitialSpawn: Crea la entrada en la tabla para el nuevo jugador, inicializando patience_level = VOID_CONFIG.patience_max. 

   - Hook PlayerDisconnected: Destruye la entrada PlayerState[ply] para evitar fugas de memoria ( _memory leaks_ ). 

