# Documento 5: Estructura del Árbol de Comportamiento (Behavior Tree) 

**Objetivo:** Definir la arquitectura lógica central (el "cerebro") de VØID. A diferencia de una máquina de estados tradicional, esta IA evalúa un Árbol de Comportamiento de **arriba hacia abajo y de izquierda a derecha** en cada _tick_ cognitivo (VOID_CONFIG.tick_rate_brain = 0.25 segundos). Si un nodo (rama) devuelve un estado de Fallo, el sistema aborta esa ruta y evalúa inmediatamente el siguiente nodo de prioridad inferior, garantizando que el Nextbot reaccione en tiempo real sin congelarse ( _stuck_ ). 

## 1. Leyenda de Nodos (Glosario Arquitectónico) 

Para traducir este diseño a código Lua (ENT:RunBehaviour()), utilizaremos la siguiente nomenclatura: 

- **[ ? ] Selector:** Evalúa a sus "hijos" de izquierda a derecha. Ejecuta el primero que devuelva ÉXITO y detiene la evaluación del resto. Se usa para tomar decisiones entre múltiples caminos. 

- **[ -> ] Secuencia:** Ejecuta a sus "hijos" en orden estricto (1, 2, 3...). Si uno falla, toda la secuencia se aborta. Se usa para encadenar acciones dependientes. 

- **[ C ] Condición:** Nodo hoja que lee las variables del Diccionario de Percepción (ej. ¿Tiene línea de visión?). 

- **[ A ] Acción:** Nodo hoja que ejecuta un comando en el motor Source (ej. Mover, atacar, reproducir audio). 

## 2. Inicialización y Selector Maestro (Root) 

Dado que VØID soporta multijugador, la primera fase del árbol es definir quién es la presa antes de tomar cualquier decisión. 

- **[ -> ] Secuencia Raíz (Root Sequence):** 

   1. **[ A ] Acción - Selector de Objetivo (Targeting):** El bot itera sobre todos los jugadores válidos en el servidor. Consulta la tabla PlayerState[ply] para evaluar la distancia y el nivel de provocación de cada uno. El jugador más cercano, o aquel con el patience_level más bajo, es asignado a la variable global current_target. 

2. **[ ? ] Selector Maestro (Master Selector):** Una vez definido el current_target, delega la decisión a las siguientes 8 ramas en orden estricto de prioridad (de la 1 a la 8). 

## 3. Rama de Prioridad 1: Fallback y Anti-Stuck (Excepciones del Motor) 

Protege el código contra errores topológicos de Garry's Mod. 

- **[ -> ] Secuencia: Recuperación Anti-Stuck** 

   1. **[ C ] Condición:** ¿El current_target es inalcanzable? (Detectado si el jugador está en MOVETYPE_NOCLIP, o si navmesh.GetNearestNavArea devuelve un área sin conexión válida). 

   2. **[ ? ] Selector de Resolución:** 

      - **[ -> ] Sub-Secuencia (Si es visible):** 

         1. **[ C ] Condición:** ¿has_los == true? 

         2. **[ A ] Acción:** Detener locomoción 

            - (self.loco:SetDesiredSpeed(0)). 

         3. **[ A ] Acción:** Clavar la mirada fijamente hacia la posición inalcanzable del jugador (incomodidad psicológica). 

      - **[ -> ] Sub-Secuencia (Si no es visible):** 

         1. **[ C ] Condición:** ¿has_los == false? 

         2. **[ A ] Acción:** Teletransportar (SetPos) al CNavArea válido más cercano al jugador para forzar la reanudación de la caza. 

## 4. Rama de Prioridad 2: Hiperagresividad (The Wipeout Sequence) 

La ejecución absoluta. Nada puede interrumpir esta rama una vez activada. 

- **[ -> ] Secuencia: Ejecución Letal** 

   1. **[ C ] Condición:** ¿PlayerState[current_target].patience_level <= 0? 

   2. **[ A ] Acción (Efecto Visual):** Swap de material a face_2_VOID. 

   3. **[ A ] Acción (Audio Global):** Reproducir 

grito_hiperagresividad_VOID.mp3 y emitir la pista 

sonido_hiperagresividad_VOID.mp3 utilizando el nivel de atenuación SNDLVL_NONE (0) o enviándolo vía red (surface.PlaySound) al cliente para evadir la atenuación de distancia. 

4. **[ A ] Acción (Locomoción Extrema):** Asignar velocidad a VOID_CONFIG.speed_hyper (500 HU/s) e iniciar persecución ignorando bloqueos. 

5. **[ C ] Condición:** ¿Distancia al jugador <= VOID_CONFIG.range_melee (70 HU)? 

6. **[ A ] Acción (Ejecución Física Silenciosa):** Construir el impacto. Instanciar CTakeDamageInfo(), asignar DMG_CLUB, aplicar el vector de impacto de fuerza VOID_CONFIG.impact_force (15000), e invocar TakeDamageInfo(). 

## 5. Rama de Prioridad 3: Parálisis por Acecho (Habilidad Especial) 

Habilidad invasiva con alto enfriamiento. 

- **[ -> ] Secuencia: Parálisis Psicológica** 

   1. **[ C ] Condición de Activación:** ¿paralysis_cooldown_timer llegó a 0? **Y** ¿has_los == true? **Y** ¿is_player_looking == true? **Y** ¿Distancia < 500 HU? 

   2. **[ A ] Acción (Inmovilización Parcial):** Interceptar el hook SetupMove del jugador para forzar CMoveData:SetForwardSpeed(0) y SetSideSpeed(0). (El jugador no puede caminar, pero puede girar la cámara). 

   3. **[ A ] Acción (Acercamiento Lento):** Desplazarse hacia el jugador a VOID_CONFIG.speed_paralysis (80 HU/s). 

   4. **[ A ] Acción (Audio):** Emitir stalking_lento_sonido_VOID.mp3 direccionalmente. 

   5. **[ C ] Condición:** ¿Distancia <= VOID_CONFIG.range_paralysis_stop (90 HU) O el audio terminó (tras VOID_CONFIG.duration_paralysis_sound = 8.5s)? 

   6. **[ A ] Acción (Pausa Cognitiva):** Frenado absoluto (desaceleración de 4000). Quedarse inmóvil frente al jugador durante VOID_CONFIG.timer_paralysis_stare (2.0 segundos). 

   7. **[ A ] Acción (Desaparición):** Restaurar movimiento del jugador. Buscar mediante BFS un CNavArea sin línea de visión (!has_los), ubicado a > 1200 HU, y teletransportar a VØID allí. Reiniciar cooldown masivo (120-180s). 

## 6. Rama de Prioridad 4: Reacción a Provocaciones (Castigos) 

Gestión de paciencia en tiempo real. 

- **[ -> ] Secuencia: Evaluación de Insultos** 

   1. **[ ? ] Selector de Provocación:** 

      - **[ C ] Condición A (Teabag):** 

¿PlayerState[current_target].crouch_count >= VOID_CONFIG.teabag_crouch_count (3) en 

VOID_CONFIG.window_teabag (3.0s)? 

   - **[ C ] Condición B (Órbita):** ¿El jugador orbita (is_orbiting == true) durante VOID_CONFIG.window_orbit (4.0s)? (Requiere velocidad > 150 HU/s y distancia < 300 HU estable). 

2. **[ C ] Condición de Debounce:** ¿Pasó el tiempo de enfriamiento interno de castigo? (Evita restar paciencia 4 veces por segundo). 

3. **[ A ] Acción (Penalizar):** Restar paciencia (-35 por teabag, -25 por órbita). Si llega a 0, en el siguiente tick el bot saltará automáticamente a la Prioridad 2 (Hiperagresivo). 

## 7. Rama de Prioridad 5: Acorralamiento (El Depredador Curioso) 

Topología dinámica y análisis de pánico. 

- **[ -> ] Secuencia: Bloqueo de Habitación** 

   1. **[ C ] Condición (BFS NavMesh):** ¿Todas las salidas del NavMesh en un radio de 400 HU obligan al jugador a pasar a < 150 HU de VØID? (is_cornered == true). 

   2. **[ A ] Acción:** Navegar hacia la puerta/salida única y mantener posición (bloquear ruta). 

   3. **[ C ] Condición de Quiebre:** ¿El jugador entra en pánico? Evaluado si la cámara supera VOID_CONFIG.threshold_panic_angle (300 grados/seg) O si causa daño (interceptado vía OnTakeDamage). 

   4. **[ A ] Acción:** Drenar paciencia instantáneamente, detonando el ataque final. 

## 8. Rama de Prioridad 6: Interacción AFK (La Observación Inofensiva) 

- **[ -> ] Secuencia: Modo Observador** 

   1. **[ C ] Condición:** ¿PlayerState[current_target].is_AFK == true? (Validado si posición y EyeAngles no varían por 15.0s). 

   2. **[ A ] Acción:** Aproximarse pacíficamente a VOID_CONFIG.speed_patrol (150 HU/s). 

3. **[ C ] Condición:** ¿Distancia <= VOID_CONFIG.range_afk_observe (300 HU)? 

4. **[ A ] Acción:** Detenerse (desaceleración de 4000) y mirar fijamente sin invadir su espacio. Permanecer en este bucle hasta que is_AFK se vuelva false. 

## 9. Rama de Prioridad 7: Caza Dinámica (El Acecho Acelerado) 

El estado principal cuando se está persiguiendo activamente a un jugador que huye. 

- **[ ? ] Selector: Persecución Direccional** 

   - **[ -> ] Sub-Secuencia A (Acecho Oculto / Off-Screen):** 

      1. **[ C ] Condición:** ¿El jugador no está mirando al bot? 

         - (is_player_looking == false). _Calculado si el Producto Punto es_ 

         - _< 0.5 o no hay línea de visión._ 

      2. **[ A ] Acción:** Acelerar el componente de locomoción a VOID_CONFIG.speed_offscreen (350 HU/s) para alcanzarlo o presionarlo por la espalda. 

   - **[ -> ] Sub-Secuencia B (Caza Frontal):** 

      1. **[ C ] Condición:** ¿El jugador lo está mirando? (is_player_looking == true). 

      2. **[ A ] Acción:** Frenar bruscamente a VOID_CONFIG.speed_chase (280 HU/s). Esto garantiza que el jugador logre mantener la distancia si corre de espaldas mirándolo. 

## 10. Rama de Prioridad 8: Inactividad y Paranoia (Idle/Lost) 

La base del árbol. Se ejecuta si no hay rastro, si el jugador está muy lejos o en fase de descubrimiento. 

- **[ -> ] Secuencia: Patrulla Idle** 

   1. **[ C ] Condición:** (Nodo por defecto, siempre verdadero si no se cumplió ninguna prioridad superior). 

   2. **[ A ] Acción (Patrullar):** Elegir un CNavArea aleatorio y navegar hacia él a VOID_CONFIG.speed_patrol (150 HU/s). 

   3. **[ A ] Acción (Bucle Base):** Mantener activo sonido_fondo_VOID.mp3, reiniciándolo manualmente tras VOID_CONFIG.duration_idle_loop (45.0s). 

   4. **[ C ] Condición (Paranoia):** ¿next_paranoia_timer llegó a 0? 

   5. **[ A ] Acción:** Seleccionar aleatoriamente un audio del arreglo sonido_aleatorio_X_VOID.mp3 y emitirlo desde una coordenada lejana 

para generar tensión ambiental. Reiniciar timer (math.random(45.0, 90.0)). 

