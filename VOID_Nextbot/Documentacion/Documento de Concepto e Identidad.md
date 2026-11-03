# **Documento de Concepto e Identidad** 

## **1. Información General** 

- **Nombre del Nextbot:** VØID 

- **Clasificación de Amenaza:** Acosador Sigiloso (Inicial). 

El nombre "VØID" tiene mucha presencia y encaja a la perfección con la idea de una entidad observadora. La clasificación de "Acosador Sigiloso" justifica exactamente por qué diseñaremos un Árbol de Comportamiento: un acosador no se limita a correr en línea recta hacia su objetivo; analiza, evalúa si el jugador está vulnerable (como al estar AFK), y calcula el momento exacto para interceptar. 

## **2. Concepto Principal y "Lore"** 

### **Premisa Básica** 

VØID es una anomalía impredecible que materializa el terror a lo desconocido. Su diseño se basa en el "vacío de información": al ser invocado, el jugador no tiene manera de predecir sus patrones, habilidades o intenciones. La entidad utiliza esta absoluta falta de conocimiento a su favor para generar una sensación de vulnerabilidad e incertidumbre constante. 

### **Origen o Motivación** 

VØID es la manifestación absoluta de la soledad y el silencio de un servidor inactivo. El acto de ser invocado supone una violenta disrupción en su ecosistema de la "nada". Sin embargo, su reacción inicial no es de odio ciego, sino de una cautelosa y tímida incomprensión. Al no estar acostumbrado a la existencia de la materia ni al ruido, VØID percibe al jugador como una anomalía caótica fascinante que debe ser estudiada antes de ser "limpiada". 

Esta necesidad de procesar lo desconocido es lo que lo lleva a observar desde las sombras, a vigilar a un jugador AFK sin tocarlo, y a acorralar a su presa solo para mirarla con curiosidad. No obstante, VØID tiene un límite de tolerancia al caos. Si la anomalía (el jugador) comienza a comportarse de forma errática, se burla de su presencia ( _teabagging_ , dar vueltas) o lo ataca, VØID deja de verlo como un objeto de estudio y lo cataloga como una infección crítica. Es en ese momento cuando el vacío decide que la única forma de restaurar su paz es erradicar al jugador con violencia absoluta e inmediata. 

## **3. Perfil de Comportamiento y "Conciencia"** 

### **Firma de Comportamiento (El Sistema de Paciencia)** 

VØID opera bajo un modelo de hostilidad dinámica. En su estado base, muestra una actitud analítica y casi "tímida", prefiriendo acechar desde la distancia o asomarse desde las esquinas antes de iniciar su "limpieza". Su agresividad está directamente ligada a un medidor interno de paciencia. 

Si el jugador lo provoca mediante acciones específicas (como _teabagging_ o agacharse repetidamente, correr en círculos a su alrededor, o atacarlo), esta paciencia se drena. Al llegar al límite, VØID abandona cualquier táctica sigilosa y entra en un estado de hiperagresividad, alterando sus variables físicas para volverse exageradamente rápido y violento. 

### **Nivel de Interacción (Respuestas Contextuales)** 

La IA de VØID evalúa los inputs y el entorno del jugador para determinar su próximo movimiento. Ejemplos: 

- **Jugador AFK:** No ejecuta una muerte instantánea. VØID calcula una distancia segura y simplemente se le queda viendo fijamente, manteniendo su naturaleza cautelosa. 

- **Jugador en Huida (Corriendo):** Ejecuta un seguimiento paralelo. VØID calcula la ruta del jugador y lo sigue de cerca, intentando mantenerse deliberadamente fuera de su campo de visión (FOV) para no ser detectado mientras no le pierde el paso. 

- **Jugador Acorralado (Habitación sin salida):** VØID bloquea la salida y cambia a un estado de "observación curiosa". La decisión de atacar queda a la espera de la reacción del jugador: si el jugador entra en pánico (movimientos erráticos de cámara), dispara, o intenta burlarse, VØID ejecuta el ataque final. 

## **4. Apariencia Visual (El Asset 2D)** 

### **Descripción del Asset PNG** 

- **Estado Base (Cauteloso):** Se utilizará un rostro humanoide estilizado en alto contraste de blanco y negro, sumergido en sombras densas donde solo resaltan fragmentos iluminados como la frente, el puente de la nariz y parte del mentón. La ausencia de ojos claramente definidos y su expresión neutra refuerzan la identidad de un ser inescrutable que simplemente observa. 



<!-- Start of picture text -->
: . 5<br>_><br><!-- End of picture text -->

_(Archivo asignado: face_1_VOID )_ . 

_Link: https://mx.pinterest.com/pin/910430880927182152/_ 

- **Estado Hiperagresivo (Limpieza):** La imagen cambia drásticamente a un rostro deformado con textura desgarrada, cuencas oculares vacías e irregulares, y una mandíbula inferior que expone dientes dentados. Este contraste visual destruye la calma inicial y proyecta una violencia caótica. 



<!-- Start of picture text -->
?<br>‘Aet/4,<br><!-- End of picture text -->

_(Archivo asignado: face_2_VOID )_ . 

_Link: https://mx.pinterest.com/pin/991214199267161997/_ 

### **Escala y Proporciones** 

VØID tendrá una caja de colisiones física exacta de 32x32 unidades de base por 80 unidades de alto, con una altura de paso ( StepHeight ) de 24 unidades. Esta escala es estratégicamente ideal: es lo suficientemente imponente para generar terror en distancias cortas, pero mecánicamente funcional, permitiéndole subir escaleras estándar, atravesar dinteles de puertas y asomarse por esquinas sin que su código de físicas colisione o se atasque con la geometría del techo. 

### **Variaciones Visuales (Swap de Materiales)** 

El motor no usará un solo PNG estático. Programaremos un intercambio dinámico de texturas ( _Material Swap_ ). El Nextbot mantendrá el rostro inexpresivo mientras su medidor de paciencia tenga puntos. En el milisegundo exacto en que la paciencia se agote por las acciones del jugador, el código reemplazará el material visual por la variante de los dientes expuestos, señalando visualmente que la persecución letal ha comenzado. 

## **5. Diseño de Audio (Soundscape)** 

La identidad sonora de VØID está diseñada para llenar el vacío del servidor y generar tensión constante, dividida en cinco categorías principales (todos los archivos estrictamente en formato .mp3 para evitar errores de red y compatibilidad en Linux): 

### **Sonido de Inactividad/Búsqueda (Idle)** 

El archivo sonido_fondo_VOID.mp3 será la presencia base del Nextbot. Se programará para reproducirse en un bucle (loop) ininterrumpido desde el momento en que VØID aparece en el mapa, y se detendrá inmediatamente cuando el bot sea eliminado. 

### **Tema de Persecución (Chase)** 

Al agotarse el medidor de paciencia y entrar en estado Hiperagresivo, el sistema ejecutará simultáneamente dos audios: sonido_hiperagresividad_VOID.mp3 (la música constante de persecución) y grito_hiperagresividad_VOID.mp3 (un impacto auditivo inicial muy fuerte). Mientras persigue al jugador en un estado normal (no hiperagresivo), se utilizará el archivo sonido_persecucion_VOID.mp3 (sin tilde). 

### **Reacciones Dinámicas (Sistema de Paranoia)** 

Se implementará un arreglo (array) en Lua con archivos nombrados sonido_aleatorio_X_VOID.mp3 . Un temporizador interno reproducirá uno de estos sonidos al azar en intervalos aleatorios de 45 a 90 segundos. 

### **Audio de Habilidad Especial (Parálisis por Acecho)** 

El archivo stalking_lento_sonido_VOID.mp3 está reservado para la inmovilización. VØID se acercará lentamente reproduciendo este audio. Al finalizar el sonido, se detendrá brevemente frente al jugador antes de desaparecer. 

### **Sonido de Interacción (Ejecución Silenciosa)** 

VØID **no** contará con ningún audio de _Jumpscare_ al ejecutar al jugador. La pantalla de muerte ocurrirá en total silencio absoluto, dejando que el impacto terrorífico recaiga únicamente en la fuerza física del cadáver golpeando el mapa. 

## **6. Experiencia del Jugador (Player Experience - PX)** 

### **Sensación Objetivo** 

VØID está diseñado para inducir paranoia sostenida y castigo a la imprudencia. El jugador inicial sentirá una falsa seguridad al ver que el Nextbot solo lo observa o se detiene cuando está AFK. Esta pausa cognitiva fomenta el miedo a lo desconocido (el "vacío"). Al castigar las provocaciones (como el _teabagging_ o atacarlo), la experiencia de usuario le enseña al jugador, a través de pánico inmediato y muerte súbita, que VØID no es un NPC básico corriendo en línea recta, sino una entidad reactiva que exige respeto. 

