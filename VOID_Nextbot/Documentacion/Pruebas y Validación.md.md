# Documento 7: Protocolos de Pruebas y Validación (QA / Testing) 

**Objetivo:** Establecer una metodología estricta de control de calidad (QA) para garantizar que la entidad npc_void sea completamente estable en servidores de producción. Este documento detalla cómo medir el rendimiento del código, cómo manejar desconexiones o mapas incompatibles, y cómo someter a estrés el sistema multijugador para evitar caídas del servidor ( _crashes_ ) o errores de Lua. 

## 1. Pruebas de Rendimiento (Performance Testing) 

El objetivo principal es garantizar que el "cerebro" del Nextbot (ENT:RunBehaviour) no consuma demasiados recursos del hilo principal del servidor, manteniendo el tiempo de ejecución de cada ciclo cognitivo por debajo de **1.5 ms** . 

- **Medición del Árbol de Comportamiento:** 

   - **Protocolo:** Envolver la evaluación del Árbol de Comportamiento dentro de la función SysTime() para calcular su costo. 

   - **Implementación de prueba:** 

``` <mark>lua local start_time = SysTime() -- [Ejecución del Árbol de Comportamiento aquí] local end_time = SysTime() local exec_time = (end_time - start_time) * 1000 if exec_time > 1.5 then print(</mark> " <mark>[VØID WARNING] Cerebro lento:</mark> " <mark>.. exec_time ..</mark> " <mark>ms</mark> " <mark>) end</mark> ``` 

- **Monitoreo del BFS (Búsqueda en Anchura):** 

   - El nodo más costoso del árbol es la _Prioridad 5: Acorralamiento_ , ya que analiza topológicamente el NavMesh en un radio de 400 HU. Se debe verificar que la recursividad del BFS tenga un límite estricto de nodos analizados (por ejemplo, máximo 20 áreas adyacentes) para evitar bucles infinitos en mapas geométricamente complejos. 

## 2. Manejo de Excepciones Críticas (Exception Handling) 

El entorno de Garry's Mod es altamente caótico. VØID debe ser capaz de manejar los siguientes escenarios sin arrojar errores de Lua en la consola. 

- **Excepción A: Desconexión Repentina del Jugador (PlayerDisconnected)** 

   - _Riesgo:_ Si self.current_target es un jugador que se desconecta o si el bot intenta leer PlayerState[NULL], el servidor arrojará un error Attempt to index a NULL entity y el bot se congelará. 

   - _Protocolo de Validación:_ Simular la desconexión del objetivo principal mientras VØID lo persigue en estado Hiperagresivo. 

   - _Resolución Esperada:_ El hook de desconexión debe limpiar inmediatamente la memoria (PlayerState[ply] = nil) y VØID debe validar con IsValid(self.current_target) en cada inicio de su ciclo de 0.25s. Si no es válido, debe saltar automáticamente a la _Prioridad 8 (Patrulla Idle)_ hasta encontrar un nuevo objetivo. 

- **Excepción B: Mapas sin Malla de Navegación (No NavMesh)** 

   - _Riesgo:_ Los Nextbots basados en CLuaLocomotion dependen 100% de que el mapa tenga un NavMesh generado (archivos .nav). Si no existe, GetNearestNavArea devuelve nulo y el bot no sabe cómo moverse. 

   - _Protocolo de Validación:_ Invocar a VØID en un mapa de construcción plano sin NavMesh (ej. gm_flatgrass sin generar nav). 

   - _Resolución Esperada:_ En la función ENT:Initialize(), el código debe verificar navmesh.IsLoaded(). Si es false, VØID debe emitir una advertencia en consola ([VØID] NavMesh no encontrado. Autodestrucción iniciada.) y usar self:Remove() para borrarse del mapa ordenadamente, evitando saturar la consola con errores de ruteo por frame. 

- **Excepción C: Abuso de Físicas (Noclip y Zonas Inalcanzables)** 

   - _Riesgo:_ Jugadores subiéndose a accesorios voladores para evitar al bot. 

   - _Protocolo de Validación:_ Validar que la **Prioridad 1 (Fallback y Anti-Stuck)** funcione. Si el jugador vuela fuera de la malla, el bot debe detenerse y mirarlo fijamente. Si el jugador se oculta donde el bot no lo ve (!has_los), VØID debe teletransportarse al área válida más cercana al jugador. 

## 3. Pruebas de Estrés Multijugador (Multiplayer Stress Testing) 

Al ser una entidad de red, debemos comprobar la solidez de la tabla PlayerState y los mensajes globales. 

- **Prueba de Cambio de Objetivo (Target Switching):** 

   - _Escenario:_ 5 jugadores vivos. El objetivo actual está a 500 HU huyendo pacíficamente. Otro jugador, a 800 HU, presiona la tecla agacharse 3 veces (crouch_count >= 3). 

   - _Resolución Esperada:_ El algoritmo de selección en el _Root Node_ debe registrar que la paciencia del segundo jugador bajó (debido a VOID_CONFIG.penalty_teabag), forzando a VØID a cambiar su current_target instantáneamente hacia el provocador. 

- **Prueba de Saturación de Red (Net Messages):** 

   - _Escenario:_ VØID entra en estado Hiperagresivo. 

   - _Resolución Esperada:_ El mensaje de audio global 

      - (net.Start("Void_PlayGlobalAudio")) se envía mediante net.Broadcast() **una sola vez** al momento de la transición, y no en cada tick de evaluación (4 veces por segundo), para evitar saturar el _reliable buffer_ del motor de red del juego. 

- **Prueba de Sincronización Visual (Shared Variables):** 

   - _Escenario:_ Transición de pacífico a Hiperagresivo en cooperativo. 

   - _Resolución Esperada:_ Gracias a self:SetIsHyper(true) (la NetworkVar), la transición de renderizado de face_1_VOID.vmt a face_2_VOID.vmt debe ocurrir en el mismo _frame_ para todos los clientes conectados, sin retrasos visuales dependientes del ping. 

## 4. Validación de Habilidades y Variables de Tiempo 

Auditoría para asegurar que el motor respeta los tiempos matemáticos definidos en el Documento 4, parcheando bugs históricos de Source. 

- **Auditoría de Audio (SoundDuration Fix):** 

   - Verificar que sonido_fondo_VOID.mp3 se reinicia exactamente a los 45.0 segundos (VOID_CONFIG.duration_idle_loop). 

   - Comprobar que no existan superposiciones de audio ni silencios prolongados ("gaps") durante los bucles. 

- **Auditoría de Parálisis por Acecho:** 

   - Forzar la habilidad (Prioridad 3). 

- Verificar que el cliente afectado realmente no pueda moverse usando el teclado (validando la interrupción en el hook SetupMove), pero que **sí pueda girar el ratón** para ver el acercamiento. 

- Verificar que la teletransportación de escape ocurra exactamente tras los 2.0 segundos definidos en VOID_CONFIG.timer_paralysis_stare, ubicando al bot a más de 1200 HU fuera de línea de visión. 

