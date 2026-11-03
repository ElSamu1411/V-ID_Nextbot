# **Documento de Configuración y Parámetros Globales** 

## **1. Velocidades y Movimiento (Movement Metrics)** 

### **Velocidad Base de Patrulla (Idle Speed)** 

- **Variable:** VOID_CONFIG.speed_patrol 

- **Valor:** 150 HU/s 

- **Justificación:** VØID se mueve más lento que un jugador caminando. Su movimiento será inexorable pero calmado, reforzando la idea de que solo está "observando" el servidor. 

### **Velocidad de Persecución (Chase Speed)** 

- **Variable:** VOID_CONFIG.speed_chase 

- **Valor:** 280 HU/s 

- **Justificación:** Ligeramente superior a la caminata humana, pero inferior al _sprint_ (320 HU/s). El jugador se verá obligado a correr para escapar. Si gestiona bien su estamina, podrá perderlo de vista; si tropieza, VØID lo alcanzará. 

### **Velocidad de Acecho Oculto (Off-Screen Speed)** 

- **Variable:** VOID_CONFIG.speed_offscreen 

- **Valor:** 350 HU/s 

- **Justificación:** Cuando el bot detecte que el jugador está huyendo pero _no_ lo está mirando ( is_player_looking == false ), VØID acelerará sutilmente por encima de la velocidad máxima del jugador. Esto garantiza que nunca se quede inofensivamente atrás en mapas grandes. En el instante en que el jugador voltee a ver si lo siguen, el bot frenará de golpe a su velocidad normal, dando la aterradora ilusión de que siempre está a pocos metros de distancia. 

### **Velocidad Extrema (Estado Hiperagresivo):** 

- **Variable:** VOID_CONFIG.speed_hyper 

- **Valor:** 500 HU/s 

- **Justificación:** Cuando el medidor de paciencia se agota, es matemáticamente imposible que un jugador normal escape corriendo en línea recta. Su única esperanza será usar la geometría del mapa a su favor (cerrar puertas, saltar ventanas) para sobrevivir. 

### **Umbral de Pánico de Cámara (Erratic Camera Movement)** 

- **Variable:** VOID_CONFIG.threshold_panic_angle 

- **Valor:** 300 (Grados por segundo) 

- **Justificación:** Un jugador normal girando el ratón para ver una esquina de forma táctica rara vez supera los 150-200 grados por segundo de forma sostenida. Un latigazo superior a 300 grados por segundo indica un movimiento de pánico (temblor o giro desesperado), detonando el ataque de VØID si el jugador está acorralado. 

### **Cinemática, Locomoción y Colisiones ( CLuaLocomotion )** 

- VOID_CONFIG.acceleration = 2000 y VOID_CONFIG.deceleration = 4000 

   - _Justificación:_ Anula la inercia resbaladiza por defecto de Source (400 HU/s²). Una desaceleración masiva de 4000 garantiza frenados absolutos "en seco" sin patinar. Esto es vital para no invadir el rango letal por accidente cuando VØID debe detenerse exactamente a 90 HU por la habilidad de parálisis. 

- VOID_CONFIG.step_height = 24 y VOID_CONFIG.jump_height = 64 

   - _Justificación:_ Valores del NavMesh que definen el tamaño máximo de un obstáculo que el bot puede pisar sin saltar, previniendo atascos en escombros pequeños o marcos de puertas irregulares. 

- VOID_CONFIG.hull_mins = Vector(-16, -16, 0) y VOID_CONFIG.hull_maxs = Vector(16, 16, 80) 

- _Justificación:_ Define vectorialmente el volumen ocupado por el bot (Bounding Box). Establece una entidad sólida de 32x32x80 HU, perfectamente calibrada para los mapas estándar de Garry's Mod. 

### **Velocidad de Acercamiento por Parálisis (Paralysis Approach)** 

- **Variable:** VOID_CONFIG.speed_paralysis 

- **Valor:** 80 HU/s 

- **Justificación:** Una velocidad angustiantemente lenta (menos de la mitad de la velocidad normal al caminar). Al combinarse con el audio stalking_lento_sonido_VOID.mp3 , le da tiempo al jugador de ver cómo la entidad invade su espacio inexorablemente sin que pueda correr para evitarlo. 

## **2. Distancias y Radios de Interacción (Spatial Ranges)** 

Para programar la inteligencia espacial de VØID, imaginaremos una serie de círculos o "esferas" invisibles a su alrededor. En el motor Source, estas distancias se miden en _Hammer Units_ (HU). 

### **Rango de Ataque (Melee Range)** 

- **Variable:** VOID_CONFIG.range_melee 

- **Valor:** 70 HU 

- **Justificación:** En Garry's Mod, un jugador promedio ocupa un espacio de 32x32 unidades y los golpes cuerpo a cuerpo (como la palanca) alcanzan unas 50 a 70 unidades. Configurar el ataque de VØID a 70 HU garantiza que la muerte no se sienta "injusta"; el bot tiene que estar físicamente invadiendo tu espacio personal para eliminarte. Si el jugador hace un quiebre de movimiento perfecto en el último segundo, podría esquivarlo. 

### **Radio de Observación AFK (AFK Observe Distance)** 

- **Variable:** VOID_CONFIG.range_afk_observe 

- **Valor:** 300 HU 

- **Justificación:** Cuando el bot detecta que is_AFK == true , navegará hacia el jugador pero se detendrá en esta barrera invisible (aproximadamente a 5 metros de distancia). Es lo suficientemente cerca para que la presencia de 

VØID llene la pantalla del jugador cuando regrese, pero lo suficientemente lejos para demostrar una "curiosidad inofensiva" en lugar de hostilidad directa. 

### **Distancia de Detención por Parálisis (Paralysis Stop Distance)** 

- **Variable:** VOID_CONFIG.range_paralysis_stop 

- **Valor:** 90 HU 

- **Justificación:** Esta es la distancia más psicológica. Durante la habilidad de parálisis, VØID se acerca lentamente mientras suena stalking_lento_sonido_VOID.mp3 . Configurar la detención a 90 HU significa que frenará en seco _justo un paso antes_ de entrar en su propio rango de ataque letal (70 HU). Se quedará plantado cara a cara, respirando el miedo del jugador inmovilizado antes de desaparecer repentinamente de la vista. 

## **3. Estadísticas de Combate (Combat & Vitals)** 

Dado que VØID es la encarnación del vacío y no un ser biológico, sus estadísticas de combate reflejarán una fuerza implacable. No hay barra de vida que el jugador pueda mermar; enfrentarlo físicamente es solo un acelerador de su propia muerte. 

### **Inmortalidad Absoluta (God Mode)** 

- **Variable:** VOID_CONFIG.is_immortal 

- **Valor:** true 

- **Justificación:** VØID no tiene puntos de vida (HP) funcionales que el jugador pueda mermar. Como regla estricta, la función OnTakeDamage forzará el daño a 0 para burlar el sistema de salud base de la entidad base_nextbot . Enfrentarlo físicamente es inútil para matarlo; el recibir daño solo actúa como un interruptor lógico que activa su furia (si proviene de un jugador validado). Solo desaparecerá si el servidor se limpia o un administrador lo elimina mediante comandos. 

### **Daño de Ataque (Lethality)** 

- **Variable:** VOID_CONFIG.attack_damage 

- **Valor:** 9999 

- **Justificación:** Un Nextbot de esta categoría no "hiere" al jugador; lo borra. Un valor exageradamente alto asegura que ignorará cualquier armadura (Kevlar/HEV Suit) o modificador de resistencia que el jugador tenga instalado, garantizando un _One-Hit Kill_ (muerte instantánea) en el milisegundo que el jugador entre en los 70 HU del rango de ataque. 

### **Fuerza de Impacto Físico (Ragdoll Force)** 

- **Variable:** VOID_CONFIG.impact_force 

- **Valor:** 15000 

- **Justificación:** Como VØID no tendrá un sonido de _jumpscare_ y la pantalla de muerte será en total silencio, el impacto terrorífico recaerá en la física. Al aplicar 15000 unidades de fuerza direccional, el ragdoll (cadáver) del jugador saldrá volando violentamente contra la geometría del nivel, generando una sensación de choque muy perturbadora. 

- **Nota Técnica de Implementación:** Para que el motor transfiera esta fuerza masiva al ragdoll, está estrictamente prohibido usar funciones genéricas como ply:Kill() . El evento de muerte debe construirse instanciando un objeto CTakeDamageInfo() . A este objeto se le debe asignar un tipo de daño físico contundente (ej. dmg:SetDamageType(DMG_CLUB) ), seguido de la inyección del vector direccional mediante la fórmula dmg:SetDamageForce((ply:GetPos() - self:GetPos()):GetNormalized() * VOID_CONFIG.impact_force) . Finalmente, el daño se aplicará invocando ply:TakeDamageInfo(dmg) . 

## **4. Variables de Tiempos (Timers & Cooldowns)** 

Para erradicar por completo los "números mágicos" de nuestro código, centralizaremos todos los temporizadores críticos en nuestra tabla de configuración. Al usar estas variables, garantizamos que si en el futuro decides que el bot es muy predecible o muy indulgente, solo cambiarás los valores aquí sin tocar la lógica del comportamiento. 

### **Tiempo de Detección AFK** 

- **Variable:** VOID_CONFIG.timer_afk 

- **Valor:** 15.0 (segundos) 

- **Justificación:** El tiempo exacto de inactividad total (movimiento y cámara) que debe transcurrir antes de que el bot asuma que el jugador no está prestando atención y active su rutina de observación curiosa. 

### **Intervalo de Paranoia Aleatoria** 

- **Variables:** VOID_CONFIG.timer_paranoia_min = 45.0 y VOID_CONFIG.timer_paranoia_max = 90.0 

- **Justificación:** Los límites para el cálculo aleatorio ( math.random ). Controlan la frecuencia con la que VØID reproducirá un ruido perturbador en el mapa para desgastar psicológicamente al jugador sin revelar su posición. 

### **Cooldown de Parálisis por Acecho** 

- **Variables:** VOID_CONFIG.cooldown_paralysis_min = 120.0 y VOID_CONFIG.cooldown_paralysis_max = 180.0 

- **Justificación:** El tiempo masivo de enfriamiento (entre 2 y 3 minutos) para su habilidad más fuerte. Al ser aleatorio dentro de este rango, el jugador nunca podrá calcular exactamente cuándo volverá a ser inmovilizado. 

### **Sistema de Paciencia y Ventanas de Provocación** 

- VOID_CONFIG.patience_max = 100 

   - Reserva de tolerancia inicial base de la entidad. 

- VOID_CONFIG.penalty_teabag = 35 

   - Puntos drenados por burla física confirmada. 

- VOID_CONFIG.penalty_orbit = 25 

   - Puntos drenados por dar vueltas alrededor del Nextbot. 

- VOID_CONFIG.teabag_crouch_count = 3 

   - Número de agachadas necesarias para que el sistema valide un _Teabagging_ . 

- VOID_CONFIG.window_teabag = 3.0 

   - Ventana de segundos en la que el sistema espera recibir los inputs de agacharse. 

- VOID_CONFIG.window_orbit = 4.0 

   - Segundos sostenidos en los que el jugador debe mantener una velocidad alta y una distancia reducida (en círculos) para registrar un comportamiento de órbita. 

### **Tickrate Cognitivo (Rendimiento del Servidor)** 

- **Variable:** VOID_CONFIG.tick_rate_brain = 0.25 

- **Justificación:** VØID ejecutará su lógica pesada (como leer el NavMesh y hacer Raycasting) 4 veces por segundo en lugar de hacerlo en cada _frame_ (que suele ser de 60 a 144 veces por segundo). Esto asegura que tu Nextbot sea ultra optimizado y mantenga sus tiempos de procesamiento por debajo de 1.5ms, tal como planeamos al inicio. 

### **Umbral de Campo de Visión Frontal (FOV Threshold)** 

- **Variable:** VOID_CONFIG.fov_dot_threshold 

- **Valor:** 0.5 

- **Justificación:** Define matemáticamente qué se considera "estar mirando al Nextbot". Un valor escalar de 0.5 en el Producto Punto equivale al coseno de 60 grados. Esto crea un cono frontal (120 grados totales) que se ajusta a la perfección al FOV horizontal estándar de un jugador en Garry's Mod (90° a 100°), garantizando que is_player_looking solo sea true cuando VØID esté claramente renderizado en la pantalla del usuario. 

### **Duración Estricta de Archivos de Audio (SoundDuration Fix)** 

Para evitar el bug histórico de SoundDuration() al leer archivos .mp3 en servidores dedicados, los tiempos de bucle y finalización de pistas se definen de forma absoluta mediante constantes. _(Nota: Ajusta estos valores flotantes para que coincidan exactamente con la duración final de tus archivos exportados)._ 

- VOID_CONFIG.duration_idle_loop = 45.0 

   - Duración exacta en segundos de sonido_fondo_VOID.mp3 antes de obligar a Lua a reiniciarlo. 

- VOID_CONFIG.duration_chase_loop = 25.0 

   - Duración exacta en segundos de la música de persecución normal. 

- VOID_CONFIG.duration_hyper_loop = 30.0 

   - Duración exacta en segundos de la música hiperagresiva. 

- VOID_CONFIG.duration_paralysis_sound = 8.5 

   - Duración del audio de acercamiento de la parálisis. Al terminar este tiempo matemático, VØID detiene su movimiento e inicia la pausa de quedarse viendo fijamente al jugador. 

### **Tiempo de Pausa Cara a Cara (Paralysis Stare)** 

- **Variable:** VOID_CONFIG.timer_paralysis_stare 

- **Valor:** 2.0 (Segundos) 

- **Justificación:** Los segundos exactos que VØID se quedará plantado e inmóvil a 90 HU de distancia del jugador paralizado, observándolo fijamente en silencio absoluto tras terminar su audio de acercamiento, justo antes de ejecutar la teletransportación de escape. 

