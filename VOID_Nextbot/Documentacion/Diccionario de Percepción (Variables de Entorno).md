# **Diccionario de Percepción (Variables de Entorno)** 

## **Arquitectura de Memoria Multijugador (PlayerState Table)** 

Para que VØID funcione en partidas cooperativas sin sobreescribir datos, el sistema no usará variables globales sueltas (como is_AFK o crouch_count ). En su lugar, el script inicializará una tabla maestra llamada PlayerState . Cada vez que un jugador ingrese al servidor, se creará un sub-diccionario indexado por su entidad: PlayerState[ply] . 

Todas las variables definidas en este documento se almacenarán dentro del perfil de cada jugador (ej. PlayerState[ply].is_AFK , PlayerState[ply].crouch_count ). 

Además, VØID utilizará una variable global dinámica llamada current_target (Entidad), la cual almacenará al jugador específico que el Nextbot ha decidido acechar o cazar en ese momento, basándose en la distancia y el nivel de provocación. 

## **1. Estado del Jugador (Player State)** 

### **Posición y Distancia Absoluta** 

- **Variable:** player_pos (Vector 3D) y distance_to_void (Float). 

- **Lógica de Extracción:** El bot leerá la posición exacta del jugador mediante la función nativa GetPos() . La distancia absoluta se calculará restando el vector de posición de VØID del vector del jugador ( bot_pos:Distance(player_pos) ), arrojando un valor en unidades del motor Source (HU - Hammer Units). Esto servirá para definir los radios de "Observación Segura" o "Ataque Inminente". 

### **Vector de Velocidad (Movimiento y Bunnyhop)** 

- **Variables:** player_speed (Float) y movement_state (String). 

- **Lógica de Extracción:** Se leerá la magnitud de la velocidad bidimensional del jugador usando GetVelocity():Length2D() . Los umbrales matemáticos exactos serán: 

   - **Quieto:** Velocidad < 10 HU/s (tolerancia para micromovimientos). 

   - **Caminando:** Velocidad entre 10 HU/s y 200 HU/s (Cubre el WalkSpeed estándar de Source). 

   - **Corriendo (Sprint):** Velocidad > 200 HU/s. 

### **Detección de Bunnyhop (Bhop)** 

Para eludir las caídas de muestreo del tickrate, se evaluará el tiempo aire ( air_time ). Si el jugador mantiene una velocidad horizontal > 250 HU/s y su tiempo de contacto con el suelo entre saltos (detectado vía OnPlayerHitGround ) es inferior a 0.15 segundos a lo largo de una ventana de 2 segundos continuos, movement_state = "bunnyhop" . (Condición de exclusión: Se ignorará si ply:WaterLevel() > 0 o si el jugador está en MOVETYPE_NOCLIP ). 

### **Estado AFK (Inactividad Total)** 

- **Variable:** is_AFK (Booleano). 

- **Lógica de Extracción:** No basta con que la velocidad sea cero, ya que el jugador podría estar escondido moviendo la cámara. El bot almacenará la posición ( GetPos() ) y el ángulo de visión de la cámara ( EyeAngles() ) en variables temporales. Si ambas variables se mantienen idénticas (con una varianza menor a 1 grado/unidad) durante **15 segundos consecutivos** , la variable is_AFK pasará a true . Al mínimo input de teclado o ratón, regresará a false . 

### **Detección de Pánico (Movimiento Errático de Cámara):** 

- **Variable:** is_panicking (Booleano). 

- **Lógica de Extracción:** Para evaluar si el jugador ha entrado en pánico (requisito para que VØID ataque cuando lo tiene acorralado), el script calculará el delta (diferencia matemática) del ángulo de visión usando EyeAngles() entre el _tick_ actual y el anterior. Si la velocidad angular de la cámara supera el umbral establecido de grados por segundo, is_panicking pasará a true , indicando un latigazo brusco o desesperado del ratón. 

## **2. Conciencia Espacial y Entorno (Environment & NavMesh)** 

### **Línea de Visión Directa (Raycasting y FOV):** 

- **Variables:** has_los (Booleano) y is_player_looking (Booleano). 

- **Lógica de Extracción (Raycasting):** Para saber si VØID puede ver al jugador, el código lanzará un rayo invisible ( util.TraceLine ) mediante una tabla TraceData . Se definirá obligatoriamente filter = {self, target} para que el rayo no colisione con el propio modelo del Nextbot, y mask = MASK_BLOCKLOS_AND_NPCS para ignorar cristales o vallas transparentes. Si el rayo impacta en el jugador (o no impacta la geometría del mundo antes), has_los = true . 

- **Lógica de Extracción (FOV del Jugador):** Para evitar que el bot crea que el jugador lo mira a través de las paredes, se exigirá como primera condición que has_los == true . Si se cumple, se calculará el Producto Punto escalar: ply:GetAimVector():Dot((bot_pos - ply:EyePos()):GetNormalized()) . Si el resultado de esta operación es mayor o igual a la variable VOID_CONFIG.fov_dot_threshold , se confirmará que VØID está en el centro de su campo visual y is_player_looking = true . 

### **Análisis Topológico y Detección de Acorralamiento:** 

- **Variables:** escape_routes_count (Entero) y is_cornered (Booleano). 

- **Lógica de Extracción:** VØID no solo perseguirá; analizará la geometría del mapa. Para evitar los falsos positivos de las subdivisiones del motor Source, el bot ejecutará una búsqueda en anchura acotada (BFS) sobre el NavMesh con un radio de evaluación de 400 HU desde la posición del jugador. Si el algoritmo determina que todas las rutas viables de escape (hacia fuera de ese radio) obligan al jugador a pasar a una distancia crítica menor a 150 HU de la posición actual de VØID, el sistema deducirá que el bot está bloqueando físicamente la única salida real. En ese caso, is_cornered = true . 

### **Identificación de Acorralamiento:** 

- Si el área donde está el jugador tiene solo **1 o 0 salidas** viables (como el fondo de un pasillo o una habitación cerrada), la variable is_cornered pasará a true . Esto detonará el comportamiento especial donde VØID bloquea la puerta y observa con curiosidad, tal como definimos en el Documento 1. 

## **3. Sistema de Provocación (Triggers & Inputs)** 

Aquí es donde VØID deja de ser un simple bot y se convierte en una entidad reactiva. Traduciremos los insultos del jugador en variables que el sistema pueda procesar. 

### **Detección de Teabagging (Burla Física):** 

- **Variables:** crouch_count (Entero) y crouch_window_timer (Temporizador Float). 

- **Lógica de Extracción:** En lugar de interceptar las pulsaciones dentro del bucle del bot, se utilizará un listener en el hook del servidor hook.Add("KeyPress", ...) . El sistema solo sumará 1 al crouch_count si se cumplen tres condiciones simultáneas: la tecla presionada es IN_DUCK , VØID está mirando al jugador ( has_los == true ), y la distancia es menor a 800 HU . Si se acumula el límite definido en VOID_CONFIG.teabag_crouch_count dentro de la ventana de tiempo, el sistema restará paciencia y aplicará un tiempo de enfriamiento ( _debounce_ ) para evitar drenajes múltiples instantáneos. 

### **Detección de Burla/Vueltas (Orbitar al Nextbot):** 

- **Variables:** is_orbiting (Booleano). 

- **Lógica de Extracción:** Para detectar de forma precisa que el jugador está corriendo en círculos alrededor de VØID en lugar de huir, el bot medirá tres factores simultáneamente durante una ventana de 4 segundos: 

   - El jugador está corriendo ( player_speed > 150 HU/s ). 

   - El jugador se mantiene innecesariamente cerca del bot ( distance_to_void < 300 HU ). 

   - La diferencia de distancia se mantiene estable (es decir, el jugador se mueve rápido, pero la distancia hacia VØID no aumenta ni disminuye drásticamente). 

- Si estas tres métricas matemáticas coinciden, is_orbiting será true y VØID interpretará que se están burlando de él. 

### **Registro de Daño (Hostilidad Directa y Validación):** 

- **Lógica de Extracción (Evento Hook):** Utilizaremos la función orientada a eventos nativa: ENT:OnTakeDamage(dmginfo) . Para garantizar la inmortalidad absoluta y evitar que armas de alto calibre invoquen la función de muerte ENT:OnKilled() , la primera instrucción de este hook será siempre anular el impacto matemáticamente mediante dmginfo:SetDamage(0) . 

- **Filtro de Atacante (Evitar Falsos Positivos):** El daño ambiental (fuego del mapa, puertas automáticas, caídas) no debe hacer enojar a VØID. El sistema validará al atacante con dmginfo:GetAttacker() . Solo si el atacante es directamente un jugador ( attacker:IsPlayer() ) o un prop físico lanzado por un jugador (validado vía GetPhysicsAttacker() ), la paciencia se drenará a 0 instantáneamente, provocando la transición violenta al estado Hiperagresivo. 

## **4. Memoria Interna de VØID (Internal State)** 

Aquí es donde definiremos el "metabolismo" de VØID: cómo cuantifica su ira y cómo administra sus habilidades especiales para no saturar al jugador. 

### **Medidor de Paciencia (El detonante de la Hiperagresividad):** 

- **Variable:** patience_level (Entero). 

- **Lógica y Valores:** VØID aparecerá en el mapa con la paciencia al tope, utilizando el valor de VOID_CONFIG.patience_max . Esta reserva no se regenera y se irá drenando según las siguientes acciones: 

   - **Por cada instancia de Teabagging confirmada:** resta el valor de VOID_CONFIG.penalty_teabag . 

   - **Por cada instancia de Orbitar (Dar vueltas burlescas):** resta el valor de VOID_CONFIG.penalty_orbit . 

   - **Por recibir Daño Físico:** Caída instantánea a 0. 

- **Umbral Crítico:** En el instante en el que patience_level <= 0 , el cerebro de VØID bloquea todas las funciones de sigilo, activa el Material Swap, reproduce el grito y cambia su estado general permanentemente a "Hiperagresivo". 

### **Cooldowns (Enfriamiento de Habilidades)** 

Para que VØID sea impredecible pero mecánicamente justo, sus habilidades no pueden activarse a cada segundo. Necesitan temporizadores (cooldowns): 

- **Temporizador de Paranoia Aleatoria:** 

   - **Variable:** next_paranoia_timer (Float). 

   - **Lógica:** Como establecimos en el diseño de audio, este temporizador se reiniciará constantemente eligiendo un valor con math.random(45, 90) . Al llegar a 0, reproduce un sonido aleatorio y se vuelve a lanzar. 

#### **● Cooldown y Ejecución de Parálisis por Acecho:** 

   - **Variable:** paralysis_cooldown_timer (Float). 

   - **Lógica de Activación:** Al ser una habilidad invasiva, su cooldown masivo será de entre 120 y 180 segundos. Para que el árbol de comportamiento ejecute la parálisis, exigirá estrictamente que has_los == true , que el jugador lo esté mirando de frente ( is_player_looking == true ), y que la distancia sea menor a 500 HU . 

   - **Mecánica de Inmovilización:** En lugar de usar la función estándar Player:Freeze(true) (que bloquearía también la cámara), el script interceptará el hook SetupMove y forzará CMoveData:SetForwardSpeed(0) y SetSideSpeed(0) . Esto anula por completo el vector de desplazamiento, pero permite al jugador girar la cámara aterrorizado mientras VØID se acerca. 

   - **Mecánica de Desaparición:** Al concluir la pausa final cara a cara, VØID no "huirá" caminando. El código buscará topológicamente un CNavArea oculto ( has_los == false desde la perspectiva del jugador) a una distancia mayor a 1200 HU y teletransportará a VØID allí de forma instantánea. 

- **Tickrate Cognitivo (Rendimiento):** 

- **Variable:** brain_tick_rate (Float = 0.25). 

- **Lógica:** VØID no calculará todo el NavMesh ni las rutas de escape en cada frame del juego (eso daría lag al servidor). Su cerebro procesará el entorno cada 0.25 segundos. Esto es lo suficientemente rápido para reaccionar al jugador, pero lo suficientemente ligero para no afectar los FPS. 

