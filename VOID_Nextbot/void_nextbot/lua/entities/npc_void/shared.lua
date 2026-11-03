AddCSLuaFile()

ENT.Base = "base_nextbot"
ENT.Type = "nextbot"
ENT.PrintName = "VØID"
ENT.Author = "VØID Project"
ENT.Category = "Nextbots"
ENT.Purpose = "Anomalía observadora reactiva basada en Árbol de Comportamiento."
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

-- ============================================================================
-- MODOS DE AUDIO SINCRONIZADOS CLIENTE-SERVIDOR
-- ============================================================================
VOID_AUDIO_NONE = 0
VOID_AUDIO_IDLE = 1
VOID_AUDIO_CHASE = 2
VOID_AUDIO_PARALYSIS = 3
VOID_AUDIO_HYPER = 4

-- ============================================================================
-- TABLA DE CONFIGURACIÓN GLOBAL CENTRALIZADA (VOID_CONFIG)
-- ============================================================================
VOID_CONFIG = {
    -- 1. Velocidades y Movimiento calibradas para Garry's Mod Sandbox (Hammer Units / segundo)
    speed_patrol = 260,
    speed_phantom_stalk = 620,
    speed_chase = 420,
    speed_offscreen = 510,
    speed_flee_hide = 480,
    speed_hyper = 900,
    speed_hyper_noclip_min = 1450,
    speed_paralysis = 80,

    -- Umbral de Pánico Angular de Cámara (Grados / segundo)
    threshold_panic_angle = 300,

    -- Cinemática, Locomoción y Colisiones (CLuaLocomotion)
    acceleration = 2400,
    acceleration_hyper = 5000,
    deceleration = 4000,
    step_height = 24,
    jump_height = 64,
    hull_mins = Vector(-16, -16, 0),
    hull_maxs = Vector(16, 16, 80),

    -- Escalado visual 1:1 del Sprite 2D Billboard (lienzo cuadrado 1024x1024)
    sprite_width = 118,
    sprite_height = 118,
    sprite_z_offset = 55,

    -- Filtro atmosférico grisáceo en pantalla mientras VØID existe en el mapa
    color_filter_saturation = 0.38,
    color_filter_contrast = 1.05,
    color_filter_brightness = -0.015,

    -- 2. Distancias y Radios de Interacción (Hammer Units)
    range_melee = 70,
    range_melee_flying = 82,
    range_afk_observe = 300,
    range_afk_min_safe = 120,
    range_paralysis_stop = 90,
    range_paralysis_trigger = 550,
    range_paralysis_escape = 1200,
    range_teabag_max = 800,
    range_orbit_max = 300,
    range_corner_bfs = 400,
    range_corner_choke = 150,
    corner_bfs_max_nodes = 48,

    -- Dimensiones de Silueta Volumétrica del Sprite 118x118 para Ocultación Completa (#7)
    silhouette_half_width = 66,
    silhouette_top_z = 122,

    -- Radios de Aparición Oculta, Observación a Distancia y Huida a Cubierto
    range_spawn_hide_min = 900,
    range_spawn_hide_max = 1950,
    range_observe_min = 550,
    range_observe_ideal = 850,
    range_observe_max = 1350,
    range_shy_retreat = 420,
    range_cover_search_min = 320,
    range_cover_search_max = 1350,

    -- Director Dual-Brain de Sector para Mapas Grandes y Multinivel (gm_mallparking, gm_bigcity, etc.)
    sector_nav_radius = 2400,
    sector_cache_ttl = 2.0,
    sector_tether_max_dist = 3200,
    sector_relocate_min = 850,
    sector_relocate_max = 1850,
    sector_same_floor_z = 240,
    phantom_sprint_min_dist = 1450,
    timer_director_no_los_relocate = 22.0,
    cooldown_director_relocate = 14.0,

    -- Adquisición de presencia y retención de rastro
    range_sight_acquire = 2500,
    range_sound_acquire = 900,
    trail_memory_duration = 10.0,
    paranoia_emit_min_dist = 180,
    paranoia_emit_max_dist = 420,

    -- 3. Estadísticas de Combate
    is_immortal = true,
    attack_damage = 9999,
    impact_force = 15000,

    -- 4. Temporizadores, Decisiones Tácticas, Anti-Noclip Global y Paciencia
    timer_afk = 30.0,
    afk_pos_tolerance = 1.0,
    afk_angle_tolerance = 1.0,

    -- Observación curiosa prolongada y mirada sostenida antes de huir (#4)
    timer_observe_to_hunt_min = 32.0,
    timer_observe_to_hunt_max = 52.0,
    timer_shy_stare_min = 3.2,
    timer_shy_stare_max = 4.8,
    timer_hunt_max_duration = 38.0,

    -- Prioridad de acecho en esquinas/paredes/rejas frente a patrulla abierta (#6)
    chance_patrol_roam = 0.32,

    -- Huida física corriendo a cobertura opaca + espera oculta de 1 a 2s (#1, #5 y #7)
    chance_run_hide_vs_tp = 0.85,
    timer_hide_unseen_min = 1.0,
    timer_hide_unseen_max = 2.0,
    cooldown_tactical_tp = 35.0,
    cooldown_antistuck_tp = 4.5,
    timer_corner_max_stare = 24.0,

    -- Detección de burla/seguimiento cuando el jugador persigue a VØID mientras huye (#5)
    timer_retreat_follow_limit = 10.0,
    retreat_respot_min = 5,
    retreat_respot_max = 6,
    chance_follow_punish_attack = 0.65,

    -- Decisión cognitiva no determinista de Parálisis por Acecho
    chance_paralysis_in_chase = 0.28,
    chance_paralysis_in_observe = 0.35,
    paralysis_rethink_min = 9.0,
    paralysis_rethink_max = 14.0,
    cooldown_paralysis_min = 65.0,
    cooldown_paralysis_max = 110.0,
    timer_paralysis_stare = 2.0,

    -- Paciencia global de Noclip ('v') de 10.0s en cualquier estado de la IA (#1 y #2)
    timer_noclip_abuse_limit = 10.0,
    noclip_abuse_decay_rate = 0.35,

    timer_paranoia_min = 25.0,
    timer_paranoia_max = 50.0,

    patience_max = 100,
    penalty_teabag = 35,
    penalty_orbit = 25,
    teabag_crouch_count = 3,
    window_teabag = 3.0,
    window_orbit = 4.0,
    provoke_debounce = 2.0,

    -- Umbrales cinemáticos del jugador (Diccionario de Percepción)
    speed_idle_max = 10,
    speed_walk_max = 200,
    orbit_min_speed = 150,
    orbit_radial_tolerance = 65,
    orbit_min_angular_deg = 28.0,
    bhop_min_speed = 250,
    bhop_max_ground_time = 0.15,
    bhop_window = 2.0,

    -- Frecuencia de evaluación cognitiva y visión frontal
    tick_rate_brain = 0.25,
    brain_tick_rate = 0.25,
    fov_dot_threshold = 0.5,

    -- 5. Rutas, Volúmenes y Duraciones Exactas Post-Masterización (44100 Hz CBR 192 kbps)
    sound_idle = "npc_void/sonido_fondo_VOID.mp3",
    sound_chase = "npc_void/sonido_persecucion_VOID.mp3",
    sound_hyper_loop = "npc_void/sonido_hiperagresividad_VOID.mp3",
    sound_hyper_scream = "npc_void/grito_hiperagresividad_VOID.mp3",
    sound_paralysis = "npc_void/stalking_lento_sonido_VOID.mp3",

    random_sounds = {
        "npc_void/sonido_aleatorio_1_VOID.mp3",
        "npc_void/sonido_aleatorio_2_VOID.mp3",
        "npc_void/sonido_aleatorio_3_VOID.mp3",
        "npc_void/sonido_aleatorio_4_VOID.mp3",
        "npc_void/sonido_aleatorio_5_VOID.mp3",
        "npc_void/sonido_aleatorio_6_VOID.mp3",
    },

    -- Curvas de volumen del Director de Audio BASS en Cliente (0.0 a 1.0)
    volume_idle_min = 0.42,
    volume_idle_max = 1.00,
    volume_idle_falloff_dist = 1800,
    volume_chase_target = 1.00,
    volume_chase_min = 0.55,
    volume_paranoia = 1.00,
    chase_audio_hold_time = 0.65,

    -- Duraciones reales medidas al milisegundo sobre los archivos masterizados sin silencio inicial
    duration_idle_loop = 251.01,
    duration_chase_loop = 9.72,
    duration_hyper_loop = 131.32,
    duration_hyper_scream = 17.97,
    duration_paralysis_sound = 10.53,
}

-- ============================================================================
-- DESCRIPTORES DE SONIDO REGISTRADOS (Compatibilidad con motor Source)
-- ============================================================================
sound.Add({
    name = "VOID_Nextbot.IdleLoop",
    channel = CHAN_STATIC,
    volume = 1.0,
    level = 95,
    pitch = 100,
    sound = VOID_CONFIG.sound_idle,
})

sound.Add({
    name = "VOID_Nextbot.ChaseLoop",
    channel = CHAN_STATIC,
    volume = 1.0,
    level = 100,
    pitch = 100,
    sound = VOID_CONFIG.sound_chase,
})

sound.Add({
    name = "VOID_Nextbot.ParalysisApproach",
    channel = CHAN_VOICE,
    volume = 1.0,
    level = 100,
    pitch = 100,
    sound = VOID_CONFIG.sound_paralysis,
})

-- ============================================================================
-- VARIABLES DE RED COMPARTIDAS (SetupDataTables)
-- ============================================================================
function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "IsHyper")
    self:NetworkVar("Bool", 1, "IsFlyingHyper")
    self:NetworkVar("Bool", 2, "TeleportCloak")
    self:NetworkVar("Entity", 0, "CurrentTarget")
    self:NetworkVar("Int", 0, "BehaviorBranch")
    self:NetworkVar("Int", 1, "AudioMode")
end

-- ============================================================================
-- HOOK COMPARTIDO DE PARÁLISIS POR ACECHO (Prevención de Rubberbanding)
-- Anula el desplazamiento del jugador permitiendo el giro libre de cámara
-- ============================================================================
local nextParalyzeBotCheckAt = 0
local cachedHasActiveVoid = false

local function HasAnyActiveVoidInstance()
    local now = CurTime()
    if now >= nextParalyzeBotCheckAt or not cachedHasActiveVoid then
        nextParalyzeBotCheckAt = now + 0.25
        cachedHasActiveVoid = false
        local bots = ents.FindByClass("npc_void")
        for i = 1, #bots do
            if IsValid(bots[i]) then
                cachedHasActiveVoid = true
                break
            end
        end
    end
    return cachedHasActiveVoid
end

hook.Add("SetupMove", "VoidParalysis", function(ply, mvd, cmd)
    if not IsValid(ply) or not ply:GetNWBool("VoidParalyzed", false) then
        return
    end

    if not ply:Alive() then
        return
    end

    if not HasAnyActiveVoidInstance() then
        if SERVER then
            ply:SetNWBool("VoidParalyzed", false)
        end
        return
    end

    mvd:SetForwardSpeed(0)
    mvd:SetSideSpeed(0)
    mvd:SetUpSpeed(0)

    if cmd then
        cmd:ClearMovement()
    end

    local buttons = mvd:GetButtons()
    buttons = bit.band(buttons, bit.bnot(bit.bor(IN_JUMP, IN_DUCK, IN_SPEED, IN_WALK, IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT)))
    mvd:SetButtons(buttons)

    local vel = mvd:GetVelocity()
    mvd:SetVelocity(Vector(0, 0, math.min(0, vel.z)))
end)

-- ============================================================================
-- REGISTRO EN EL SPAWNMENU (Pestaña NPCs -> Nextbots)
-- ============================================================================
list.Set("NPC", "npc_void", {
    Name = "VØID",
    Class = "npc_void",
    Category = "Nextbots",
    IconOverride = "entities/npc_void.png",
})
