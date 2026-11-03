AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

-- ============================================================================
-- REGISTRO DE MENSAJES DE RED Y DESCARGA DE RECURSOS MULTIJUGADOR
-- ============================================================================
util.AddNetworkString("Void_PlayGlobalAudio")
util.AddNetworkString("Void_StopGlobalAudio")
util.AddNetworkString("Void_PlayParanoiaSound")
util.AddNetworkString("Void_TeleportCloak")

resource.AddFile("materials/entities/npc_void.png")
resource.AddFile("materials/entities/npc_void/face_1_VOID.vmt")
resource.AddFile("materials/entities/npc_void/face_1_VOID.vtf")
resource.AddFile("materials/entities/npc_void/face_2_VOID.vmt")
resource.AddFile("materials/entities/npc_void/face_2_VOID.vtf")
resource.AddFile("sound/" .. VOID_CONFIG.sound_idle)
resource.AddFile("sound/" .. VOID_CONFIG.sound_chase)
resource.AddFile("sound/" .. VOID_CONFIG.sound_hyper_loop)
resource.AddFile("sound/" .. VOID_CONFIG.sound_hyper_scream)
resource.AddFile("sound/" .. VOID_CONFIG.sound_paralysis)
for _, snd in ipairs(VOID_CONFIG.random_sounds) do
    resource.AddFile("sound/" .. snd)
end

-- ============================================================================
-- ARQUITECTURA DE MEMORIA MULTIJUGADOR Y MULTI-INSTANCIA
-- SharedPlayerState: cinemática intrínseca del jugador, AFK, pánico y caché de sector.
-- bot.PlayerMemories[ply]: percepción, fase de acecho y paciencia aisladas por instancia de VØID.
-- ============================================================================
SharedPlayerState = SharedPlayerState or {}
PlayerState = PlayerState or {}

local BT_FAILURE = 0
local BT_SUCCESS = 1
local BT_RUNNING = 2

local BRANCH_NAMES = {
    [1] = "P1: Fallback y Anti-Stuck",
    [2] = "P2: Hiperagresividad",
    [3] = "P3: Parálisis por Acecho",
    [4] = "P4: Reacción a Provocaciones",
    [5] = "P5: Acorralamiento",
    [6] = "P6: Interacción AFK (Enfrente)",
    [7] = "P7: Caza Dinámica",
    [8] = "P8: Acecho en Esquinas y Patrulla",
    [9] = "P7-Obs: Observación Curiosa a Distancia",
    [10] = "P7-Hide: Huida a Cubierto (Espera 1-2s Oculto)",
}

local IGNORE_PLAYERS_CVAR = GetConVar("ai_ignoreplayers")
local VOID_CachedNavAreas = nil

local function GetCachedNavAreas()
    local engineCount = navmesh.GetNavAreaCount and navmesh.GetNavAreaCount() or nil
    if not VOID_CachedNavAreas
        or #VOID_CachedNavAreas == 0
        or (engineCount and engineCount > 0 and #VOID_CachedNavAreas ~= engineCount)
        or not IsValid(VOID_CachedNavAreas[1])
    then
        VOID_CachedNavAreas = navmesh.GetAllNavAreas()
    end
    return VOID_CachedNavAreas
end

hook.Add("PostCleanupMap", "Void_PostCleanupMap", function()
    VOID_CachedNavAreas = nil
end)

local function RollObservationDuration()
    return math.Rand(VOID_CONFIG.timer_observe_to_hunt_min, VOID_CONFIG.timer_observe_to_hunt_max)
end

local function RollShyStareDuration()
    return math.Rand(VOID_CONFIG.timer_shy_stare_min or 3.2, VOID_CONFIG.timer_shy_stare_max or 4.8)
end

local function RollHideWaitDuration()
    return math.Rand(VOID_CONFIG.timer_hide_unseen_min or 1.0, VOID_CONFIG.timer_hide_unseen_max or 2.0)
end

local function RollRetreatRespotLimit()
    return math.random(VOID_CONFIG.retreat_respot_min or 5, VOID_CONFIG.retreat_respot_max or 6)
end

local function BuildPlayerTraceFilter(ply, extraEnt)
    local filter = { ply }
    if extraEnt then
        filter[#filter + 1] = extraEnt
    end
    if IsValid(ply) and ply:IsPlayer() and ply:InVehicle() then
        local veh = ply:GetVehicle()
        if IsValid(veh) then
            filter[#filter + 1] = veh
            local parent = veh:GetParent()
            if IsValid(parent) then
                filter[#filter + 1] = parent
            end
        end
    end
    return filter
end

local function IsEntityPlayerOrVehicle(ent, ply)
    if not IsValid(ent) or not IsValid(ply) then
        return false
    end
    if ent == ply then
        return true
    end
    if ply:IsPlayer() and ply:InVehicle() then
        local veh = ply:GetVehicle()
        if IsValid(veh) then
            if ent == veh or ent == veh:GetParent() then
                return true
            end
        end
    end
    return false
end

local function GetEffectivePlayerVelocity(ply)
    if not IsValid(ply) then
        return vector_origin
    end
    if ply:IsPlayer() and ply:InVehicle() then
        local veh = ply:GetVehicle()
        if IsValid(veh) then
            local parent = veh:GetParent()
            if IsValid(parent) then
                local pVel = parent:GetVelocity()
                if pVel:LengthSqr() > veh:GetVelocity():LengthSqr() then
                    return pVel
                end
            end
            return veh:GetVelocity()
        end
    end
    return ply:GetVelocity()
end

local function EnsureSharedPlayerState(ply)
    if not IsValid(ply) or not ply:IsPlayer() then
        return nil
    end

    local shared = SharedPlayerState[ply]
    if not shared then
        local now = CurTime()
        local pos = ply:GetPos()
        local ang = ply:EyeAngles()
        shared = {
            player_pos = pos,
            player_speed = 0,
            movement_state = "quieto",

            -- Bunnyhop intrínseco al jugador
            was_on_ground = ply:IsOnGround(),
            last_land_time = now,
            last_ground_contact = 1.0,
            bhop_valid_since = 0,
            last_kinematic_eval_at = -1.0,

            -- AFK intrínseco al jugador
            is_AFK = false,
            afk_ref_pos = pos,
            afk_ref_ang = ang,
            afk_idle_since = now,

            -- Pánico angular de cámara intrínseco al jugador
            is_panicking = false,
            prev_eye_ang = ang,
            prev_ang_time = now,
            panic_hold_until = 0,
            skip_panic_until = 0,

            -- Caché topológica de sector NavMesh alrededor del jugador
            sector_nav_areas = nil,
            sector_nav_anchor = nil,
            sector_nav_cached_at = 0.0,
        }
        SharedPlayerState[ply] = shared
    end

    return shared
end

-- Obtiene y cachea cada 2.0s las CNavAreas conectadas al piso/sector real del jugador usando navmesh.Find (C++ nativo)
local function GetPlayerSectorNavAreas(ply, customRadius)
    if not IsValid(ply) or not ply:IsPlayer() then
        return GetCachedNavAreas()
    end

    local shared = EnsureSharedPlayerState(ply)
    local now = CurTime()
    local plyPos = ply:GetPos()
    local radius = customRadius or VOID_CONFIG.sector_nav_radius or 2400
    local ttl = VOID_CONFIG.sector_cache_ttl or 2.0

    if not customRadius
        and shared
        and shared.sector_nav_areas
        and #shared.sector_nav_areas > 0
        and IsValid(shared.sector_nav_areas[1])
        and (now - (shared.sector_nav_cached_at or 0)) < ttl
        and shared.sector_nav_anchor
        and plyPos:DistToSqr(shared.sector_nav_anchor) <= (450 * 450)
    then
        return shared.sector_nav_areas
    end

    -- Anclar primero al suelo real del NavMesh (evita fallos si el jugador salta o sube al techo de un auto en gm_mallparking)
    local searchOrigin = plyPos
    local nearestFloorArea = navmesh.GetNearestNavArea(plyPos, true, 650, false, false)
    if IsValid(nearestFloorArea) then
        searchOrigin = nearestFloorArea:GetClosestPointOnArea(plyPos)
    end

    local found = navmesh.Find(searchOrigin, radius, 260, 260) or {}
    if #found < 10 then
        found = navmesh.Find(searchOrigin, math.max(radius * 1.65, 3800), 420, 420) or {}
    end

    -- Respaldo espacial acotado si el mapa tiene islas de NavMesh desconectadas manualmente
    if #found < 6 then
        local all = GetCachedNavAreas()
        local maxHorizSqr = (radius * 1.4) * (radius * 1.4)
        local fallback = {}
        for i = 1, #all do
            local a = all[i]
            if IsValid(a) then
                local c = a:GetCenter()
                local dx = c.x - plyPos.x
                local dy = c.y - plyPos.y
                if (dx * dx + dy * dy) <= maxHorizSqr and math.abs(c.z - plyPos.z) <= 420 then
                    fallback[#fallback + 1] = a
                    if #fallback >= 96 then break end
                end
            end
        end
        if #fallback > #found then
            found = fallback
        end
    end

    if shared and not customRadius then
        shared.sector_nav_areas = found
        shared.sector_nav_anchor = plyPos
        shared.sector_nav_cached_at = now
    end

    return (#found > 0) and found or GetCachedNavAreas()
end

function ENT:GetPlayerMemory(ply)
    if not IsValid(ply) or not ply:IsPlayer() then
        return nil
    end

    self.PlayerMemories = self.PlayerMemories or {}
    local shared = EnsureSharedPlayerState(ply)
    local st = self.PlayerMemories[ply]

    if not st then
        local now = CurTime()
        local pos = ply:GetPos()
        st = {
            -- 1. Espejo sincronizado del estado cinemático intrínseco + distancias a ESTA instancia de VØID
            player_pos = pos,
            distance_to_void = math.huge,
            prev_distance = math.huge,
            prev_bearing_deg = nil,
            player_speed = shared and shared.player_speed or 0,
            movement_state = shared and shared.movement_state or "quieto",
            is_AFK = shared and shared.is_AFK or false,
            is_panicking = shared and shared.is_panicking or false,

            -- 2. Conciencia espacial relativa a ESTA instancia de VØID
            has_los = false,
            is_player_looking = false,
            escape_routes_count = 2,
            is_cornered = false,
            corner_choke_pos = nil,
            corner_started_at = 0.0,

            -- 3. Provocaciones y paciencia global de Noclip relativas a ESTA instancia
            crouch_count = 0,
            crouch_window_timer = 0,
            crouch_timestamps = {},
            is_orbiting = false,
            orbit_accum_time = 0,
            provoke_debounce_until = 0,
            noclip_abuse_accum = 0.0,
            last_noclip_tick_at = 0.0,
            enraged_by_noclip = false,
            execute_cooldown_until = 0.0,

            -- 4. Memoria de paciencia, fase de acecho, seguimiento en huida y rastro
            patience_level = VOID_CONFIG.patience_max,
            stalk_phase = "UNDISCOVERED", -- "UNDISCOVERED" | "OBSERVING" | "RETREATING" | "HUNTING"
            observe_accum_time = 0.0,
            observe_target_duration = RollObservationDuration(),
            player_stare_accum = 0.0,
            shy_stare_limit = RollShyStareDuration(),
            observe_vantage_pos = nil,
            observe_vantage_expire = 0.0,
            observe_lost_los_accum = 0.0,
            retreat_cover_pos = nil,
            retreat_unseen_accum = 0.0,
            retreat_target_wait = RollHideWaitDuration(),
            retreat_exposed_accum = 0.0,
            retreat_follow_accum = 0.0,
            retreat_respot_count = 0,
            retreat_respot_limit = RollRetreatRespotLimit(),
            retreat_was_hidden = false,
            retreat_last_respot_at = 0.0,
            retreat_started_at = 0.0,
            retreat_repath_at = 0.0,
            hunt_started_at = 0.0,
            has_trail = false,
            trail_until = 0.0,
            last_los_contact_at = now,
        }
        self.PlayerMemories[ply] = st
    else
        -- Compatibilidad en caliente tras Lua AutoRefresh
        if not st.stalk_phase then st.stalk_phase = "UNDISCOVERED" end
        if not st.observe_accum_time then st.observe_accum_time = 0.0 end
        if not st.observe_target_duration then st.observe_target_duration = RollObservationDuration() end
        if not st.player_stare_accum then st.player_stare_accum = 0.0 end
        if not st.shy_stare_limit then st.shy_stare_limit = RollShyStareDuration() end
        if not st.retreat_unseen_accum then st.retreat_unseen_accum = 0.0 end
        if not st.retreat_target_wait then st.retreat_target_wait = RollHideWaitDuration() end
        if not st.retreat_follow_accum then st.retreat_follow_accum = 0.0 end
        if not st.retreat_respot_count then st.retreat_respot_count = 0 end
        if not st.retreat_respot_limit then st.retreat_respot_limit = RollRetreatRespotLimit() end
        if not st.noclip_abuse_accum then st.noclip_abuse_accum = 0.0 end
        if not st.last_los_contact_at then st.last_los_contact_at = CurTime() end
        if st.enraged_by_noclip == nil then st.enraged_by_noclip = false end
        if not st.corner_started_at then st.corner_started_at = 0.0 end
        if not st.execute_cooldown_until then st.execute_cooldown_until = 0.0 end
    end

    PlayerState[ply] = st
    return st
end

function ENT:ResetPlayerMemory(ply, resetToUndiscovered)
    if not IsValid(ply) or not ply:IsPlayer() then
        return
    end
    local st = self:GetPlayerMemory(ply)
    if not st then
        return
    end
    local now = CurTime()
    st.patience_level = VOID_CONFIG.patience_max
    st.noclip_abuse_accum = 0.0
    st.enraged_by_noclip = false
    st.is_orbiting = false
    st.orbit_accum_time = 0
    st.prev_bearing_deg = nil
    st.crouch_count = 0
    st.crouch_timestamps = {}
    st.crouch_window_timer = 0
    st.is_panicking = false
    st.has_trail = false
    st.trail_until = 0
    st.is_cornered = false
    st.corner_choke_pos = nil
    st.corner_started_at = 0.0
    st.provoke_debounce_until = math.max(st.provoke_debounce_until or 0, now + 1.0)

    if resetToUndiscovered ~= false then
        st.stalk_phase = "UNDISCOVERED"
        st.observe_accum_time = 0.0
        st.observe_target_duration = RollObservationDuration()
        st.player_stare_accum = 0.0
        st.shy_stare_limit = RollShyStareDuration()
        st.observe_vantage_pos = nil
        st.observe_vantage_expire = 0.0
        st.observe_lost_los_accum = 0.0
        st.retreat_cover_pos = nil
        st.retreat_unseen_accum = 0.0
        st.retreat_target_wait = RollHideWaitDuration()
        st.retreat_exposed_accum = 0.0
        st.retreat_follow_accum = 0.0
        st.retreat_respot_count = 0
        st.retreat_respot_limit = RollRetreatRespotLimit()
        st.retreat_was_hidden = false
        st.retreat_started_at = 0.0
        st.retreat_repath_at = 0.0
        st.hunt_started_at = 0.0
    end
end

local function IsValidTargetPlayer(ply)
    if not IsValid(ply) or not ply:IsPlayer() or not ply:Alive() then
        return false
    end
    if ply:Team() == TEAM_SPECTATOR or ply:GetObserverMode() ~= OBS_MODE_NONE then
        return false
    end
    if IGNORE_PLAYERS_CVAR and IGNORE_PLAYERS_CVAR:GetBool() then
        return false
    end
    return true
end

local function ResetPlayerProvocation(ply, resetToUndiscovered)
    if not IsValid(ply) or not ply:IsPlayer() then
        return
    end
    local shared = EnsureSharedPlayerState(ply)
    if shared then
        shared.is_panicking = false
        shared.panic_hold_until = 0
        shared.bhop_valid_since = 0
    end
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) and bot.ResetPlayerMemory then
            bot:ResetPlayerMemory(ply, resetToUndiscovered)
        end
    end
end

local function CheckLineOfSightFromPos(startEyePos, ply, filterEnt)
    if not IsValid(ply) then
        return false
    end
    local tr = util.TraceLine({
        start = startEyePos,
        endpos = ply:EyePos(),
        filter = BuildPlayerTraceFilter(ply, filterEnt),
        mask = MASK_BLOCKLOS_AND_NPCS,
    })
    return (not tr.Hit) or IsEntityPlayerOrVehicle(tr.Entity, ply)
end

local function CheckLineOfSight(bot, ply)
    if not IsValid(bot) or not IsValid(ply) then
        return false
    end
    return CheckLineOfSightFromPos(bot:GetPos() + Vector(0, 0, 64), ply, bot)
end

-- ============================================================================
-- TRANSMISIÓN DE RED PERMANENTE (Audio BASS y Filtro Gris activos en todo el mapa)
-- ============================================================================
function ENT:UpdateTransmitState()
    return TRANSMIT_ALWAYS
end

function ENT:IsFlyingHyperMode()
    return (self.GetIsFlyingHyper and self:GetIsFlyingHyper()) or self:GetNWBool("VoidFlyingHyper", false)
end

-- ============================================================================
-- HOOKS GLOBALES DEL SERVIDOR (Gestión de Ciclo de Vida e Inputs Asíncronos)
-- ============================================================================
hook.Add("PlayerInitialSpawn", "Void_PlayerInitialSpawn", function(ply)
    EnsureSharedPlayerState(ply)
end)

hook.Add("PlayerDisconnected", "Void_PlayerDisconnected", function(ply)
    SharedPlayerState[ply] = nil
    PlayerState[ply] = nil
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) then
            if bot.PlayerMemories then
                bot.PlayerMemories[ply] = nil
            end
            if bot.current_target == ply then
                bot.current_target = nil
                bot:SetCurrentTarget(NULL)
            end
            if bot.ParalysisState and bot.ParalysisState.target == ply then
                bot:AbortParalysis()
            end
            if bot:GetIsHyper() then
                if bot.HasAnyEnragedAlivePlayer and not bot:HasAnyEnragedAlivePlayer() then
                    bot:CalmDownToBaseState(true)
                elseif bot:IsFlyingHyperMode() and bot.HasAnyFlyingEnragedAlivePlayer and not bot:HasAnyFlyingEnragedAlivePlayer() then
                    bot:ExitFlyingToTerrestrialHyper()
                end
            end
        end
    end
end)

hook.Add("PlayerDeath", "Void_PlayerDeath", function(ply)
    if IsValid(ply) and ply:GetNWBool("VoidParalyzed", false) then
        ply:SetNWBool("VoidParalyzed", false)
    end
    ResetPlayerProvocation(ply, true)
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) then
            if bot.ParalysisState and bot.ParalysisState.target == ply then
                bot:AbortParalysis()
            end
            local wasTarget = (bot.current_target == ply)
            if wasTarget then
                bot.current_target = nil
                bot:SetCurrentTarget(NULL)
            end
            if bot:GetIsHyper() then
                if bot.HasAnyEnragedAlivePlayer and not bot:HasAnyEnragedAlivePlayer() then
                    bot:CalmDownToBaseState(true)
                elseif bot:IsFlyingHyperMode() and bot.HasAnyFlyingEnragedAlivePlayer and not bot:HasAnyFlyingEnragedAlivePlayer() then
                    bot:ExitFlyingToTerrestrialHyper()
                end
            elseif wasTarget and bot.TeleportToHiddenVantage then
                bot:TeleportToHiddenVantage(VOID_CONFIG.range_spawn_hide_min, VOID_CONFIG.range_spawn_hide_max, true)
                bot:SetSpatialLoopMode("IDLE")
                bot:SetBehaviorBranch(8)
            end
        end
    end
end)

hook.Add("PlayerSpawn", "Void_PlayerSpawn", function(ply)
    if not IsValid(ply) then return end
    ply:SetNWBool("VoidParalyzed", false)
    local now = CurTime()
    local shared = EnsureSharedPlayerState(ply)
    if shared then
        shared.afk_ref_pos = ply:GetPos()
        shared.afk_ref_ang = ply:EyeAngles()
        shared.afk_idle_since = now
        shared.is_AFK = false
        shared.prev_eye_ang = ply:EyeAngles()
        shared.prev_ang_time = now
        shared.is_panicking = false
        shared.panic_hold_until = 0
        shared.skip_panic_until = now + 0.35
        shared.sector_nav_areas = nil
        shared.sector_nav_cached_at = 0.0
    end

    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) and bot.GetPlayerMemory then
            local st = bot:GetPlayerMemory(ply)
            if st then
                st.crouch_count = 0
                st.crouch_timestamps = {}
                st.is_orbiting = false
                st.orbit_accum_time = 0
                st.prev_bearing_deg = nil
                st.is_panicking = false
                st.noclip_abuse_accum = 0.0
                st.has_trail = false
                st.trail_until = 0
                st.last_los_contact_at = now
                if st.patience_level > 0 then
                    st.stalk_phase = "UNDISCOVERED"
                    st.observe_accum_time = 0.0
                    st.observe_target_duration = RollObservationDuration()
                    st.player_stare_accum = 0.0
                    st.observe_vantage_pos = nil
                    st.retreat_cover_pos = nil
                    st.retreat_unseen_accum = 0.0
                end
            end
        end
    end

    -- En mapas enormes/multinivel (ej. gm_mallparking), si el jugador reaparece en un info_player_start lejano
    -- o en otro piso tras morir, reubicar silenciosamente a VØID en el nuevo sector si ningún otro jugador lo ve.
    timer.Simple(0.15, function()
        if not IsValidTargetPlayer(ply) then return end
        local s = EnsureSharedPlayerState(ply)
        if s then
            s.sector_nav_areas = nil
            s.sector_nav_cached_at = 0.0
            s.afk_ref_pos = ply:GetPos()
            s.afk_ref_ang = ply:EyeAngles()
            s.prev_eye_ang = ply:EyeAngles()
            s.prev_ang_time = CurTime()
        end
        for _, bot in ipairs(ents.FindByClass("npc_void")) do
            if IsValid(bot) and not bot:GetIsHyper() and not bot.ParalysisState then
                local st = bot:GetPlayerMemory(ply)
                if st then
                    st.last_los_contact_at = CurTime()
                end
                local busyWithOther = IsValidTargetPlayer(bot.current_target) and (bot.current_target ~= ply)
                if not busyWithOther and not bot:DoesAnyAlivePlayerSeeVoidSilhouette(bot:GetPos()) then
                    local d = bot:GetPos():Distance(ply:GetPos())
                    local dz = math.abs(bot:GetPos().z - ply:GetPos().z)
                    if d > ((VOID_CONFIG.sector_relocate_max or 1850) + 350) or dz > (VOID_CONFIG.sector_same_floor_z or 240) then
                        bot:TeleportToHiddenVantage(VOID_CONFIG.sector_relocate_min, VOID_CONFIG.sector_relocate_max, true, ply)
                        bot.NextDirectorRelocateAt = CurTime() + (VOID_CONFIG.cooldown_director_relocate or 14.0)
                    end
                end
            end
        end
    end)
end)

hook.Add("OnPlayerHitGround", "Void_BhopGroundDetect", function(ply)
    local shared = EnsureSharedPlayerState(ply)
    if not shared then return end
    shared.last_land_time = CurTime()
    shared.was_on_ground = true
end)

hook.Add("KeyPress", "VoidTeabagDetect", function(ply, key)
    if not IsValidTargetPlayer(ply) then return end
    local shared = EnsureSharedPlayerState(ply)
    if not shared then return end

    local now = CurTime()
    shared.is_AFK = false
    shared.afk_idle_since = now
    shared.afk_ref_pos = ply:GetPos()
    shared.afk_ref_ang = ply:EyeAngles()

    -- Registrar el tiempo real de contacto en el suelo y desactivar was_on_ground para que el tick de 0.25s no lo sobrescriba con aire
    if key == IN_JUMP and shared.was_on_ground and shared.last_land_time > 0 then
        shared.last_ground_contact = now - shared.last_land_time
        shared.was_on_ground = false
    end

    if key == IN_DUCK and ply:GetMoveType() ~= MOVETYPE_NOCLIP and not ply:InVehicle() then
        local plyPos = ply:GetPos()
        for _, bot in ipairs(ents.FindByClass("npc_void")) do
            if IsValid(bot) and not bot:GetIsHyper() and bot.GetPlayerMemory then
                local dist = bot:GetPos():Distance(plyPos)
                if dist < VOID_CONFIG.range_teabag_max and CheckLineOfSight(bot, ply) then
                    local bst = bot:GetPlayerMemory(ply)
                    if bst then
                        local validStamps = {}
                        for _, ts in ipairs(bst.crouch_timestamps) do
                            if (now - ts) <= VOID_CONFIG.window_teabag then
                                validStamps[#validStamps + 1] = ts
                            end
                        end
                        validStamps[#validStamps + 1] = now
                        bst.crouch_timestamps = validStamps
                        bst.crouch_count = #validStamps
                        bst.crouch_window_timer = now + VOID_CONFIG.window_teabag
                    end
                end
            end
        end
    end
end)

-- ============================================================================
-- INICIALIZACIÓN FÍSICA, TELETRANSPORTE OCULTO INICIAL Y MEMORIA DE VØID
-- ============================================================================
function ENT:Initialize()
    if not navmesh.IsLoaded() then
        print("[VØID] NavMesh no encontrado. Autodestrucción iniciada.")
        self:Remove()
        return
    end

    self:SetModel("models/props_c17/oildrum001.mdl")
    self:DrawShadow(false)
    self:SetSolid(SOLID_BBOX)
    self:SetCollisionGroup(COLLISION_GROUP_NPC)
    self:SetCollisionBounds(VOID_CONFIG.hull_mins, VOID_CONFIG.hull_maxs)

    self:SetHealth(999999)
    self:SetMaxHealth(999999)

    if self.loco then
        self.DefaultGravity = self.loco:GetGravity()
        self.loco:SetAcceleration(VOID_CONFIG.acceleration)
        self.loco:SetDeceleration(VOID_CONFIG.deceleration)
        self.loco:SetStepHeight(VOID_CONFIG.step_height)
        self.loco:SetJumpHeight(VOID_CONFIG.jump_height)
        self.loco:SetDeathDropHeight(2000)
        self.loco:SetDesiredSpeed(VOID_CONFIG.speed_patrol)
    else
        self.DefaultGravity = 1000
    end

    self.PlayerMemories = {}
    self.PlayerState = self.PlayerMemories
    self.current_target = nil
    self.patience_level = VOID_CONFIG.patience_max
    self:SetIsHyper(false)
    if self.SetIsFlyingHyper then self:SetIsFlyingHyper(false) end
    self:SetNWBool("VoidFlyingHyper", false)
    if self.SetTeleportCloak then self:SetTeleportCloak(false) end
    self:SetNWBool("VoidTeleportCloak", false)
    self:SetCurrentTarget(NULL)
    self:SetBehaviorBranch(8)

    local now = CurTime()
    self.NextBrainTick = now + 0.10
    self.LastBrainEvalAt = now
    self.CurrentBrainDt = VOID_CONFIG.tick_rate_brain
    self.NextMicroSample = now
    self.LastBrainExecMs = 0.0
    self.DiscoveryGraceUntil = now + 1.5
    self.PendingTeleportUntil = 0.0
    self.TeleportToken = 0
    self.LastMaskedTeleportDest = nil
    self.NextAntiStuckTeleportAt = 0.0
    self.NextDoorScanAt = 0.0
    self.NextErrorLogAt = 0.0

    -- Temporizadores tácticos y Director de Sector para mapas grandes
    self.next_paranoia_timer = now + math.Rand(15.0, 28.0)
    self.paralysis_cooldown_timer = now + 22.0
    self.paralysis_rethink_until = 0.0
    self.next_tactical_tp_at = now + 15.0
    self.NextDirectorRelocateAt = now + 8.0
    self.PhantomSprintActive = false

    -- Navegación, acecho estacionario y anti-stuck
    self.ActivePath = nil
    self.ActiveGoalPos = nil
    self.NextPathRecompute = 0
    self.StuckSince = nil
    self.UnreachableStrikes = 0
    self.PatrolGoalPos = nil
    self.PatrolExpireTime = 0
    self.IdleIsLurking = false
    self.NextAFKSnapAt = 0.0
    self.ParalysisState = nil
    self.CurrentSpatialMode = "NONE"

    GetCachedNavAreas()

    for _, ply in ipairs(player.GetAll()) do
        EnsureSharedPlayerState(ply)
        self:ResetPlayerMemory(ply, true)
    end

    -- Teletransportarse instantáneamente lejos del jugador, oculto y con supresión de interpolación
    self:TeleportToHiddenVantage(VOID_CONFIG.range_spawn_hide_min, VOID_CONFIG.range_spawn_hide_max, true)

    self:SetSpatialLoopMode("IDLE")
end

-- ============================================================================
-- CONTROL DE FÍSICAS DE VUELO 3D ("NOCLIP") Y MODOS DE HIPERAGRESIVIDAD
-- ============================================================================
function ENT:SetFlyingNoclipPhysics(enabled)
    if enabled then
        if self.SetIsFlyingHyper then self:SetIsFlyingHyper(true) end
        self:SetNWBool("VoidFlyingHyper", true)
        self.ActivePath = nil
        self.ActiveGoalPos = nil
        if self.loco then
            self.loco:SetGravity(0)
            self.loco:SetDesiredSpeed(0)
            self.loco:SetVelocity(vector_origin)
        end
        self:SetSolid(SOLID_NONE)
        self:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    else
        if self.SetIsFlyingHyper then self:SetIsFlyingHyper(false) end
        self:SetNWBool("VoidFlyingHyper", false)
        if self.loco then
            self.loco:SetGravity(self.DefaultGravity or 1000)
            self.loco:SetAcceleration(VOID_CONFIG.acceleration)
            self.loco:SetDesiredSpeed(VOID_CONFIG.speed_patrol)
            self.loco:SetVelocity(vector_origin)
        end
        self:SetSolid(SOLID_BBOX)
        self:SetCollisionGroup(COLLISION_GROUP_NPC)
    end
end

function ENT:SyncNetworkAudioMode(modeInt)
    if self.SetAudioMode then
        self:SetAudioMode(modeInt)
    end
    self:SetNWInt("VoidAudioMode", modeInt)
end

function ENT:SetSpatialLoopMode(mode)
    if self:GetIsHyper() then
        self.CurrentSpatialMode = "HYPER"
        self:SyncNetworkAudioMode(VOID_AUDIO_HYPER)
        return
    end

    self.CurrentSpatialMode = mode

    if mode == "IDLE" then
        self:SyncNetworkAudioMode(VOID_AUDIO_IDLE)
    elseif mode == "CHASE" then
        self:SyncNetworkAudioMode(VOID_AUDIO_CHASE)
    elseif mode == "PARALYSIS" then
        self:SyncNetworkAudioMode(VOID_AUDIO_PARALYSIS)
    else
        self:SyncNetworkAudioMode(VOID_AUDIO_NONE)
    end
end

function ENT:HasAnyEnragedAlivePlayer()
    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            local st = self:GetPlayerMemory(ply)
            if st and st.patience_level <= 0 then
                return true
            end
        end
    end
    return false
end

function ENT:HasAnyFlyingEnragedAlivePlayer()
    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            local st = self:GetPlayerMemory(ply)
            if st and st.patience_level <= 0 and st.enraged_by_noclip then
                return true
            end
        end
    end
    return false
end

function ENT:ExitFlyingToTerrestrialHyper()
    self:SetFlyingNoclipPhysics(false)
    local botPos = self:GetPos()
    local nearArea = navmesh.GetNearestNavArea(botPos, false, 180, false, false)
    if not IsValid(nearArea) or not self:IsHullClearAt(botPos) then
        local groundPos = self:FindNearestValidTeleportPos(botPos)
        if groundPos then
            self:PerformMaskedTeleport(groundPos, true)
        end
    end
    if self.loco then
        self.loco:SetAcceleration(VOID_CONFIG.acceleration_hyper)
        self.loco:SetDesiredSpeed(VOID_CONFIG.speed_hyper)
    end
end

function ENT:CalmDownToBaseState(teleportHidden)
    if self.ParalysisState then
        self:AbortParalysis()
    end

    -- Desactivar vuelo ("noclip") si había sido activado por abuso de noclip del jugador
    self:SetFlyingNoclipPhysics(false)

    self.patience_level = VOID_CONFIG.patience_max
    self.current_target = nil
    self:SetCurrentTarget(NULL)
    self.ActivePath = nil
    self.ActiveGoalPos = nil
    self.UnreachableStrikes = 0
    self.PatrolGoalPos = nil
    self.PatrolExpireTime = 0

    if self.loco then
        self.loco:SetAcceleration(VOID_CONFIG.acceleration)
        self.loco:SetDesiredSpeed(VOID_CONFIG.speed_patrol)
    end

    self:SetIsHyper(false)
    self:SetBehaviorBranch(8)
    self:SetSpatialLoopMode("IDLE")

    net.Start("Void_StopGlobalAudio")
    net.WriteUInt(self:EntIndex(), 16)
    net.WriteBool(false)
    net.Broadcast()

    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) then
            self:ResetPlayerMemory(ply, true)
        end
    end

    if teleportHidden then
        local moved = self:TeleportToHiddenVantage(VOID_CONFIG.range_spawn_hide_min, VOID_CONFIG.range_spawn_hide_max, true)
        if not moved then
            local groundPos = self:FindNearestValidTeleportPos(self:GetPos())
            if groundPos then
                self:PerformMaskedTeleport(groundPos, true)
            end
        end
    end
end

-- Hiperagresividad TERRESTRE estándar (por daño directo, teabag, órbita o pánico en rincón — NO vuela)
function ENT:TriggerHyperAggressive(culprit)
    local victim = IsValidTargetPlayer(culprit) and culprit
        or (IsValidTargetPlayer(self.current_target) and self.current_target or nil)

    if IsValid(victim) then
        local st = self:GetPlayerMemory(victim)
        if st then
            st.patience_level = 0
            st.stalk_phase = "HUNTING"
            st.has_trail = true
            st.trail_until = math.huge
        end
        self.current_target = victim
        self:SetCurrentTarget(victim)
    end

    self.patience_level = 0

    -- Asegurar locomoción terrestre si no provino de abuso de noclip
    if not self:IsFlyingHyperMode() and self.loco then
        self.loco:SetAcceleration(VOID_CONFIG.acceleration_hyper)
        self.loco:SetDesiredSpeed(VOID_CONFIG.speed_hyper)
    end

    if self.ParalysisState then
        self:AbortParalysis()
    end

    if not self:GetIsHyper() then
        self:SetIsHyper(true)
        self:SyncNetworkAudioMode(VOID_AUDIO_HYPER)

        net.Start("Void_PlayGlobalAudio")
        net.WriteUInt(self:EntIndex(), 16)
        net.WriteBool(true)
        net.Broadcast()
    end
end

-- Hiperagresividad AÉREA EXCLUSIVA Anti-Noclip (#6: tras abuso de noclip)
function ENT:TriggerFlyingNoclipHyper(culprit)
    local victim = IsValidTargetPlayer(culprit) and culprit
        or (IsValidTargetPlayer(self.current_target) and self.current_target or nil)

    if not IsValid(victim) then
        return
    end

    local st = self:GetPlayerMemory(victim)
    if st then
        st.enraged_by_noclip = true
    end

    -- Cancelar cualquier teletransporte diferido pendiente y activar físicas de vuelo libre 3D
    self.TeleportToken = (self.TeleportToken or 0) + 1
    self.PendingTeleportUntil = 0.0
    self:SetNoDraw(false)
    if self.SetTeleportCloak then self:SetTeleportCloak(false) end
    self:SetNWBool("VoidTeleportCloak", false)

    self:SetFlyingNoclipPhysics(true)
    self:TriggerHyperAggressive(victim)
end

-- ============================================================================
-- SISTEMA DE PARANOIA CERCANA AL JUGADOR
-- ============================================================================
function ENT:EmitParanoiaSound()
    local sounds = VOID_CONFIG.random_sounds
    if not sounds or #sounds == 0 then return end
    local chosen = sounds[math.random(1, #sounds)]

    local validPlayers = {}
    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            validPlayers[#validPlayers + 1] = ply
        end
    end
    if #validPlayers == 0 then return end

    local refPly = IsValidTargetPlayer(self.current_target) and self.current_target
        or validPlayers[math.random(1, #validPlayers)]

    local refPos = refPly:GetPos()
    local refEye = refPly:EyePos()
    local aimVec = refPly:GetAimVector()
    local minD = VOID_CONFIG.paranoia_emit_min_dist
    local maxD = VOID_CONFIG.paranoia_emit_max_dist

    local bestPos = nil
    local bestScore = -math.huge

    local nearAreas = navmesh.Find(refPos, maxD + 120, 220, 220)
    if nearAreas and #nearAreas > 0 then
        local step = math.max(1, math.floor(#nearAreas / 24))
        for i = 1, #nearAreas, step do
            local area = nearAreas[i]
            if IsValid(area) then
                local c = area:GetCenter() + Vector(0, 0, 42)
                local d = c:Distance(refPos)
                if d >= minD and d <= maxD then
                    local dir = (c - refEye):GetNormalized()
                    local dot = aimVec:Dot(dir)
                    local tr = util.TraceLine({
                        start = c,
                        endpos = refEye,
                        filter = BuildPlayerTraceFilter(refPly, self),
                        mask = MASK_BLOCKLOS_AND_NPCS,
                    })
                    local score = (-dot * 50.0) + (tr.Hit and 30.0 or 0.0)
                    if score > bestScore then
                        bestScore = score
                        bestPos = c
                    end
                end
            end
        end
    end

    if not bestPos then
        local flatAim = Vector(aimVec.x, aimVec.y, 0)
        if flatAim:LengthSqr() < 0.01 then
            flatAim = Vector(1, 0, 0)
        else
            flatAim:Normalize()
        end
        local backDir = (-flatAim)
        backDir:Rotate(Angle(0, math.Rand(-55, 55), 0))

        local trBack = util.TraceLine({
            start = refEye,
            endpos = refEye + backDir * 290,
            filter = BuildPlayerTraceFilter(refPly, self),
            mask = MASK_SOLID_BRUSHONLY,
        })
        bestPos = trBack.HitPos - backDir * 24
    end

    net.Start("Void_PlayParanoiaSound")
    net.WriteString(chosen)
    net.WriteVector(bestPos)
    net.Broadcast()
end

-- ============================================================================
-- INMORTALIDAD ABSOLUTA Y DETECCIÓN DE HOSTILIDAD DIRECTA (OnTakeDamage)
-- ============================================================================
function ENT:OnTakeDamage(dmginfo)
    if VOID_CONFIG.is_immortal then
        dmginfo:SetDamage(0)
        dmginfo:ScaleDamage(0)
    end

    local attacker = dmginfo:GetAttacker()
    local inflictor = dmginfo:GetInflictor()
    local culprit = nil

    if IsValid(attacker) and attacker:IsPlayer() then
        culprit = attacker
    elseif IsValid(attacker) and attacker.GetPhysicsAttacker then
        local physAtk = attacker:GetPhysicsAttacker(5)
        if IsValid(physAtk) and physAtk:IsPlayer() then
            culprit = physAtk
        end
    elseif IsValid(inflictor) and inflictor.GetPhysicsAttacker then
        local physAtk = inflictor:GetPhysicsAttacker(5)
        if IsValid(physAtk) and physAtk:IsPlayer() then
            culprit = physAtk
        end
    end

    -- Recibir daño del jugador activa Hiperagresividad TERRESTRE (sin volar)
    if IsValidTargetPlayer(culprit) then
        self:TriggerHyperAggressive(culprit)
    end

    return 0
end

function ENT:OnKilled()
    return
end

-- ============================================================================
-- EJECUCIÓN FÍSICA SILENCIOSA + EXPULSIÓN DE VEHÍCULOS + MANEJO DE GODMODE
-- ============================================================================
function ENT:ExecuteTarget(ply)
    if not IsValidTargetPlayer(ply) then
        return
    end

    if ply:GetNWBool("VoidParalyzed", false) then
        ply:SetNWBool("VoidParalyzed", false)
    end

    -- Si el jugador está dentro de un vehículo o asiento, expulsarlo antes de aplicar daño letal
    if ply:InVehicle() then
        local veh = ply:GetVehicle()
        if IsValid(veh) then
            local phys = veh:GetPhysicsObject()
            if IsValid(phys) then
                phys:Wake()
            end
        end
        ply:ExitVehicle()
    end

    -- Si la víctima estaba volando en noclip, devolverla a físicas normales antes del golpe
    -- para que su cadáver reciba toda la fuerza cinética del impacto.
    if ply:GetMoveType() == MOVETYPE_NOCLIP then
        ply:SetMoveType(MOVETYPE_WALK)
    end

    local dir = ply:WorldSpaceCenter() - (self:GetPos() + Vector(0, 0, 40))
    if not self:IsFlyingHyperMode() then
        dir.z = 0
    end
    if dir:LengthSqr() < 1 then
        dir = self:GetForward()
    else
        dir:Normalize()
    end

    local forceVec = (dir + Vector(0, 0, 0.2)):GetNormalized() * VOID_CONFIG.impact_force

    local dmg = DamageInfo()
    dmg:SetDamage(VOID_CONFIG.attack_damage)
    dmg:SetAttacker(self)
    dmg:SetInflictor(self)
    dmg:SetDamageType(DMG_CLUB)
    dmg:SetDamagePosition(ply:WorldSpaceCenter())
    dmg:SetDamageForce(forceVec)

    ply:TakeDamageInfo(dmg)

    if IsValid(ply) and ply:Alive() and not (ply.HasGodMode and ply:HasGodMode()) then
        ply:Kill()
    end

    self:ResetPlayerMemory(ply, true)
    if IsValid(ply) and ply:Alive() then
        -- Si sobrevivió por GodMode (sbox_godmode 1 / god), aplicar empuje físico limpio y enfriamiento
        ply:SetVelocity((dir + Vector(0, 0, 0.32)):GetNormalized() * 680)
        local mem = self:GetPlayerMemory(ply)
        if mem then
            mem.execute_cooldown_until = CurTime() + 1.0
        end
    end

    if self.current_target == ply then
        self.current_target = nil
        self:SetCurrentTarget(NULL)
    end

    -- Al matar al jugador, si estaba Hiperagresivo (terrestre o volador anti-noclip),
    -- restablecer paciencia, dejar de volar y reaparecer oculto en tierra si no quedan culpables.
    if self:GetIsHyper() then
        if not self:HasAnyEnragedAlivePlayer() then
            self:CalmDownToBaseState(true)
        elseif self:IsFlyingHyperMode() and not self:HasAnyFlyingEnragedAlivePlayer() then
            self:ExitFlyingToTerrestrialHyper()
        end
    else
        self:TeleportToHiddenVantage(VOID_CONFIG.range_spawn_hide_min, VOID_CONFIG.range_spawn_hide_max, true)
        self:SetSpatialLoopMode("IDLE")
        self:SetBehaviorBranch(8)
    end
end

function ENT:IsTargetInMeleeReach(ply)
    if not IsValidTargetPlayer(ply) then
        return false
    end

    local st = self:GetPlayerMemory(ply)
    if st and (st.execute_cooldown_until or 0) > CurTime() then
        return false
    end

    local botPos = self:GetPos()
    local botCenter = botPos + Vector(0, 0, 40)
    local plyPos = ply:GetPos()

    if self:IsFlyingHyperMode() then
        local plyCenter = ply:WorldSpaceCenter()
        local rFly = VOID_CONFIG.range_melee_flying or 82
        if botCenter:DistToSqr(plyCenter) <= (rFly * rFly) then
            return true
        end
        if ply:InVehicle() then
            local veh = ply:GetVehicle()
            if IsValid(veh) and veh:NearestPoint(botCenter):DistToSqr(botCenter) <= (96 * 96) then
                return true
            end
        end
        return false
    end

    local meleeRange = VOID_CONFIG.range_melee
    if botPos:DistToSqr(plyPos) <= (meleeRange * meleeRange) then
        return true
    end
    local dx = plyPos.x - botPos.x
    local dy = plyPos.y - botPos.y
    if (dx * dx + dy * dy) <= (meleeRange * meleeRange) then
        local dzCenters = math.abs((plyPos.z + 36) - (botPos.z + 40))
        if dzCenters <= 74 then
            return true
        end
    end

    -- Alcance contra el chasis del vehículo si el jugador conduce (ej. autos en gm_mallparking)
    if ply:InVehicle() then
        local vehReachSqr = (meleeRange + 18) * (meleeRange + 18)
        local veh = ply:GetVehicle()
        if IsValid(veh) then
            if veh:NearestPoint(botCenter):DistToSqr(botCenter) <= vehReachSqr then
                return true
            end
            local parent = veh:GetParent()
            if IsValid(parent) and parent:NearestPoint(botCenter):DistToSqr(botCenter) <= vehReachSqr then
                return true
            end
        end
    end

    return false
end

-- ============================================================================
-- SISTEMA DE PERCEPCIÓN, CONTEO DE ABUSO DE NOCLIP Y BFS TOPOLÓGICO
-- ============================================================================
local AFK_CHECK_KEYS = {
    IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT,
    IN_JUMP, IN_DUCK, IN_SPEED, IN_WALK,
    IN_ATTACK, IN_ATTACK2, IN_USE, IN_RELOAD,
}

local function IsPlayerHoldingAnyKey(ply)
    if not ply.KeyDown then
        return false
    end
    for i = 1, #AFK_CHECK_KEYS do
        if ply:KeyDown(AFK_CHECK_KEYS[i]) then
            return true
        end
    end
    return false
end

function ENT:SampleCameraAndAFK()
    local now = CurTime()
    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            local shared = EnsureSharedPlayerState(ply)
            local curAng = ply:EyeAngles()
            local curPos = ply:GetPos()
            local dt = now - shared.prev_ang_time

            if dt >= 0.05 then
                if now < (shared.skip_panic_until or 0) then
                    shared.is_panicking = false
                else
                    local dp = math.AngleDifference(curAng.p, shared.prev_eye_ang.p)
                    local dy = math.AngleDifference(curAng.y, shared.prev_eye_ang.y)
                    local angSpeed = math.sqrt(dp * dp + dy * dy) / dt

                    if angSpeed > VOID_CONFIG.threshold_panic_angle then
                        shared.is_panicking = true
                        shared.panic_hold_until = now + 0.55
                    elseif now > shared.panic_hold_until then
                        shared.is_panicking = false
                    end
                end

                shared.prev_eye_ang = curAng
                shared.prev_ang_time = now
            end

            local posDelta = curPos:Distance(shared.afk_ref_pos)
            local angDeltaP = math.abs(math.AngleDifference(curAng.p, shared.afk_ref_ang.p))
            local angDeltaY = math.abs(math.AngleDifference(curAng.y, shared.afk_ref_ang.y))
            local activeButtons = IsPlayerHoldingAnyKey(ply)
            local isParalyzed = ply:GetNWBool("VoidParalyzed", false)
            local movingInWorld = (GetEffectivePlayerVelocity(ply):Length2DSqr() > 9.0)

            if posDelta >= VOID_CONFIG.afk_pos_tolerance
                or angDeltaP >= VOID_CONFIG.afk_angle_tolerance
                or angDeltaY >= VOID_CONFIG.afk_angle_tolerance
                or activeButtons
                or isParalyzed
                or movingInWorld
            then
                shared.afk_ref_pos = curPos
                shared.afk_ref_ang = curAng
                shared.afk_idle_since = now
                shared.is_AFK = false
            elseif (now - shared.afk_idle_since) >= VOID_CONFIG.timer_afk then
                shared.is_AFK = true
            end

            if self.PlayerMemories and self.PlayerMemories[ply] then
                self.PlayerMemories[ply].is_AFK = shared.is_AFK
                self.PlayerMemories[ply].is_panicking = shared.is_panicking
            end
        end
    end
end

function ENT:EvaluateCorneredBFS(ply, playerPos)
    local botPos = self:GetPos()
    if math.abs(botPos.z - playerPos.z) > 120 then
        return 2, false, nil
    end

    local startArea = navmesh.GetNearestNavArea(playerPos, false, 300, false, false)
    if not IsValid(startArea) then
        return 0, false, nil
    end

    local chokeDistSqr = VOID_CONFIG.range_corner_choke * VOID_CONFIG.range_corner_choke
    local bfsRadius = VOID_CONFIG.range_corner_bfs
    local maxNodes = VOID_CONFIG.corner_bfs_max_nodes

    local queue = {
        { area = startArea, blocked = false, firstStep = nil }
    }
    local visited = { [startArea:GetID()] = true }
    local visitedCount = 1
    local qHead = 1

    local unblockedExits = 0
    local blockedExits = 0
    local bestChokePos = nil

    while qHead <= #queue and visitedCount <= maxNodes do
        local node = queue[qHead]
        qHead = qHead + 1

        local adjList = node.area:GetAdjacentAreas()
        for _, adj in ipairs(adjList) do
            if IsValid(adj) and not visited[adj:GetID()] then
                local deltaZ = node.area:ComputeAdjacentConnectionHeightChange(adj)
                if deltaZ <= VOID_CONFIG.jump_height then
                    visited[adj:GetID()] = true
                    visitedCount = visitedCount + 1

                    local closestToBot = adj:GetClosestPointOnArea(botPos)
                    local dzChoke = math.abs(closestToBot.z - botPos.z)
                    local passesNearVoid = (dzChoke <= 85) and (closestToBot:DistToSqr(botPos) < chokeDistSqr)
                    if passesNearVoid then
                        local trWall = util.TraceLine({
                            start = botPos + Vector(0, 0, 48),
                            endpos = closestToBot + Vector(0, 0, 48),
                            filter = BuildPlayerTraceFilter(ply, self),
                            mask = MASK_NPCSOLID_BRUSHONLY,
                        })
                        if trWall.Hit then
                            passesNearVoid = false
                        end
                    end

                    local isBlocked = node.blocked or passesNearVoid
                    local stepPos = node.firstStep
                    if passesNearVoid and not stepPos then
                        stepPos = closestToBot
                    end

                    local distFromPlayer = adj:GetCenter():Distance(playerPos)
                    if distFromPlayer >= bfsRadius then
                        if isBlocked then
                            blockedExits = blockedExits + 1
                            if not bestChokePos then
                                bestChokePos = stepPos or closestToBot
                            end
                        else
                            unblockedExits = unblockedExits + 1
                        end
                    elseif visitedCount < maxNodes then
                        queue[#queue + 1] = {
                            area = adj,
                            blocked = isBlocked,
                            firstStep = stepPos,
                        }
                    end

                    if visitedCount >= maxNodes then
                        break
                    end
                end
            end
        end
    end

    local exhaustedNaturally = (qHead > #queue)
    local isCornered = false
    if unblockedExits == 0 and (blockedExits >= 1 or (exhaustedNaturally and visitedCount <= 12 and botPos:Distance(playerPos) < 420 and CheckLineOfSight(self, ply))) then
        isCornered = true
        if not bestChokePos then
            bestChokePos = startArea:GetClosestPointOnArea(botPos)
        end
    end

    return unblockedExits, isCornered, bestChokePos
end

function ENT:UpdateAllPlayersPerception()
    local now = CurTime()
    local dt = self.CurrentBrainDt or VOID_CONFIG.tick_rate_brain
    local botPos = self:GetPos()
    local botEyePos = botPos + Vector(0, 0, 64)
    local pastGrace = now >= (self.DiscoveryGraceUntil or 0)
    local triggeredNoclipVictim = nil

    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            local shared = EnsureSharedPlayerState(ply)
            local st = self:GetPlayerMemory(ply)
            local pPos = ply:GetPos()
            local dist = botPos:Distance(pPos)
            local effVel = GetEffectivePlayerVelocity(ply)
            local vel2D = effVel:Length2D()
            local inNoclip = (ply:GetMoveType() == MOVETYPE_NOCLIP)

            -- Evaluación cinemática intrínseca del jugador (protegida frente a múltiples bots en el mismo tick)
            if (now - (shared.last_kinematic_eval_at or -1.0)) >= 0.04 then
                shared.last_kinematic_eval_at = now
                shared.player_pos = pPos
                shared.player_speed = vel2D

                if vel2D < VOID_CONFIG.speed_idle_max then
                    shared.movement_state = "quieto"
                elseif vel2D <= VOID_CONFIG.speed_walk_max then
                    shared.movement_state = "caminando"
                else
                    shared.movement_state = "corriendo"
                end

                local onGround = ply:IsOnGround()
                if not onGround and shared.was_on_ground then
                    shared.last_ground_contact = now - shared.last_land_time
                end
                shared.was_on_ground = onGround

                if ply:WaterLevel() == 0
                    and not inNoclip
                    and not ply:InVehicle()
                    and vel2D > VOID_CONFIG.bhop_min_speed
                    and shared.last_ground_contact < VOID_CONFIG.bhop_max_ground_time
                    and (now - shared.last_land_time) < 1.2
                then
                    if shared.bhop_valid_since == 0 then
                        shared.bhop_valid_since = now
                    elseif (now - shared.bhop_valid_since) >= VOID_CONFIG.bhop_window then
                        shared.movement_state = "bunnyhop"
                    end
                else
                    shared.bhop_valid_since = 0
                end
            end

            st.prev_distance = (st.distance_to_void < math.huge) and st.distance_to_void or dist
            st.player_pos = pPos
            st.distance_to_void = dist
            st.player_speed = shared.player_speed
            st.movement_state = shared.movement_state
            st.is_AFK = shared.is_AFK
            st.is_panicking = shared.is_panicking

            -- Línea de Visión (LOS) y Producto Punto de FOV (compatible con vehículos)
            local hasLos = CheckLineOfSight(self, ply)
            st.has_los = hasLos

            if hasLos or dist <= 520 or st.stalk_phase == "HUNTING" or st.stalk_phase == "RETREATING" or st.is_AFK then
                st.last_los_contact_at = now
            end

            if hasLos then
                local dirToBot = (botEyePos - ply:EyePos()):GetNormalized()
                local dot = ply:GetAimVector():Dot(dirToBot)
                st.is_player_looking = (dot >= VOID_CONFIG.fov_dot_threshold)
            else
                st.is_player_looking = false
            end

            -- Paciencia GLOBAL de Noclip ('v') de 10.0s sin importar en qué estado esté la IA (#1 y #2)
            if inNoclip then
                st.last_noclip_tick_at = now
                st.noclip_abuse_accum = (st.noclip_abuse_accum or 0.0) + dt

                -- Si estaba siendo cazado, no dejar caducar el rastro durante noclip
                if st.stalk_phase == "HUNTING" or (self:GetIsHyper() and ply == self.current_target) then
                    st.has_trail = true
                    st.trail_until = now + VOID_CONFIG.trail_memory_duration
                    if st.hunt_started_at and st.hunt_started_at > 0 then
                        st.hunt_started_at = st.hunt_started_at + dt
                    end
                end

                if st.noclip_abuse_accum >= VOID_CONFIG.timer_noclip_abuse_limit and not self:IsFlyingHyperMode() then
                    triggeredNoclipVictim = ply
                end
            elseif (st.noclip_abuse_accum or 0) > 0 then
                st.last_noclip_tick_at = now
                st.noclip_abuse_accum = math.max(0.0, st.noclip_abuse_accum - (VOID_CONFIG.noclip_abuse_decay_rate * dt))
            end

            -- Progresión de Descubrimiento -> Observación Curiosa a Distancia -> Caza Dinámica
            local sensoryContactNow = pastGrace and (
                (hasLos and dist <= VOID_CONFIG.range_sight_acquire)
                or (dist <= VOID_CONFIG.range_sound_acquire and vel2D > VOID_CONFIG.speed_walk_max)
            )
            local sameFloorSector = math.abs(pPos.z - botPos.z) <= (VOID_CONFIG.sector_same_floor_z or 240)
            local sectorPresenceNow = pastGrace and (
                sensoryContactNow
                or (dist <= 1250 and vel2D > 80)
                or (dist <= 1650 and sameFloorSector)
            )

            if self:GetIsHyper() then
                if st.patience_level <= 0 then
                    st.stalk_phase = "HUNTING"
                    st.has_trail = true
                    st.trail_until = now + VOID_CONFIG.trail_memory_duration
                end
            elseif st.stalk_phase == "UNDISCOVERED" then
                if sectorPresenceNow then
                    st.stalk_phase = "OBSERVING"
                    st.observe_accum_time = 0.0
                    st.observe_target_duration = RollObservationDuration()
                    st.player_stare_accum = 0.0
                    st.shy_stare_limit = RollShyStareDuration()
                    st.observe_vantage_pos = nil
                end
            elseif st.stalk_phase == "HUNTING" then
                if sensoryContactNow or inNoclip then
                    st.has_trail = true
                    st.trail_until = now + VOID_CONFIG.trail_memory_duration
                elseif now > st.trail_until or dist > (VOID_CONFIG.range_sight_acquire * 1.35) then
                    st.has_trail = false
                end
            end

            -- Limpieza de ventana de Teabag expirada
            if st.crouch_count > 0 and now > st.crouch_window_timer then
                local fresh = {}
                for _, ts in ipairs(st.crouch_timestamps) do
                    if (now - ts) <= VOID_CONFIG.window_teabag then
                        fresh[#fresh + 1] = ts
                    end
                end
                st.crouch_timestamps = fresh
                st.crouch_count = #fresh
            end

            -- Evaluación de Órbita (exige giro angular tangencial real >= 28°/s alrededor de VØID; descarta persecuciones en línea recta)
            local dx = pPos.x - botPos.x
            local dy = pPos.y - botPos.y
            local bearingDeg = math.deg(math.atan2(dy, dx))
            local angularDelta = st.prev_bearing_deg and math.abs(math.AngleDifference(bearingDeg, st.prev_bearing_deg)) or 0.0
            st.prev_bearing_deg = bearingDeg
            local angularSpeedDeg = angularDelta / math.max(dt, 0.05)

            local radialDelta = math.abs(dist - st.prev_distance)
            local minAngularDeg = VOID_CONFIG.orbit_min_angular_deg or 28.0

            if vel2D > VOID_CONFIG.orbit_min_speed
                and dist > VOID_CONFIG.range_melee
                and dist < VOID_CONFIG.range_orbit_max
                and radialDelta <= VOID_CONFIG.orbit_radial_tolerance
                and angularSpeedDeg >= minAngularDeg
                and not inNoclip
            then
                st.orbit_accum_time = st.orbit_accum_time + dt
                if st.orbit_accum_time >= VOID_CONFIG.window_orbit then
                    st.is_orbiting = true
                end
            else
                st.orbit_accum_time = math.max(0, st.orbit_accum_time - dt * 0.5)
                if st.orbit_accum_time < VOID_CONFIG.window_orbit then
                    st.is_orbiting = false
                end
            end
        end
    end

    if IsValid(triggeredNoclipVictim) then
        self:TriggerFlyingNoclipHyper(triggeredNoclipVictim)
    end
end

-- ============================================================================
-- SELECTOR DE OBJETIVO EN NODO RAÍZ (Multijugador: Distancia + Provocación)
-- ============================================================================
function ENT:SelectTarget()
    if not self:GetIsHyper() and self.ParalysisState and IsValidTargetPlayer(self.ParalysisState.target) then
        self.current_target = self.ParalysisState.target
        self:SetCurrentTarget(self.current_target)
        return self.current_target
    end

    -- En modo Hiperagresivo Volador Anti-Noclip, fijar implacablemente al infractor aéreo mientras viva
    if self:IsFlyingHyperMode() then
        if IsValidTargetPlayer(self.current_target) then
            local curSt = self:GetPlayerMemory(self.current_target)
            if curSt and curSt.patience_level <= 0 and curSt.enraged_by_noclip then
                return self.current_target
            end
        end
        for _, ply in ipairs(player.GetAll()) do
            if IsValidTargetPlayer(ply) then
                local pst = self:GetPlayerMemory(ply)
                if pst and pst.patience_level <= 0 and pst.enraged_by_noclip then
                    self.current_target = ply
                    self:SetCurrentTarget(ply)
                    return ply
                end
            end
        end
        -- Ningún infractor aéreo sigue con vida: volver a locomoción terrestre antes de elegir objetivo
        self:ExitFlyingToTerrestrialHyper()
    end

    local isHyper = self:GetIsHyper()
    local bestPly = nil
    local bestScore = -math.huge

    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            local st = self:GetPlayerMemory(ply)
            -- En Hiperagresividad jamás seleccionar ni atacar a jugadores inocentes (patience > 0)
            if isHyper and st.patience_level > 0 then
                continue
            end

            local pendingPenalty = 0
            if st.crouch_count >= VOID_CONFIG.teabag_crouch_count then
                pendingPenalty = VOID_CONFIG.penalty_teabag
            elseif st.is_orbiting then
                pendingPenalty = VOID_CONFIG.penalty_orbit
            end
            local effectivePatience = math.max(0, st.patience_level - pendingPenalty)
            local provocationWeight = (VOID_CONFIG.patience_max - effectivePatience) * 35.0
            local hysteresis = (ply == self.current_target) and 150.0 or 0.0
            local score = provocationWeight - st.distance_to_void + hysteresis

            if score > bestScore then
                bestScore = score
                bestPly = ply
            end
        end
    end

    if self.current_target ~= bestPly then
        self.current_target = bestPly
        self:SetCurrentTarget(IsValid(bestPly) and bestPly or NULL)
        self.UnreachableStrikes = 0
    end

    if IsValidTargetPlayer(bestPly) then
        local st = self:GetPlayerMemory(bestPly)
        if not isHyper
            and st.stalk_phase ~= "UNDISCOVERED"
            and st.stalk_phase ~= "RETREATING"
            and st.distance_to_void <= 620
            and (st.has_los or st.distance_to_void <= 320)
            and not st.is_AFK
        then
            local exits, cornered, chokePos = self:EvaluateCorneredBFS(bestPly, st.player_pos)
            st.escape_routes_count = exits
            if cornered and not st.is_cornered then
                st.corner_started_at = CurTime()
            elseif not cornered then
                st.corner_started_at = 0.0
            end
            st.is_cornered = cornered
            st.corner_choke_pos = chokePos
        else
            st.is_cornered = false
            st.corner_choke_pos = nil
            st.corner_started_at = 0.0
        end
    end

    return bestPly
end

-- ============================================================================
-- LOCOMOCIÓN CONTINUA, COBERTURAS Y TELETRANSPORTE ENMASCARADO SIN FRAMES (#3)
-- ============================================================================
function ENT:StopMotionAndLookAt(lookPos)
    self.ActivePath = nil
    self.ActiveGoalPos = nil
    self.PhantomSprintActive = false
    if self.loco then
        self.loco:SetDesiredSpeed(0)
        if lookPos then
            self.loco:FaceTowards(lookPos)
        end
    end
end

-- Calcula velocidad adaptativa de acecho: Sprint Fantasma (620 HU/s) al estar 100% oculto en tramos largos/rampas,
-- desacelerando automáticamente a 260 HU/s antes de asomarse por una esquina (predicción 95 HU adelante).
function ENT:ComputeAdaptiveStalkSpeed(goalPos, baseSpeed)
    local normalSpd = baseSpeed or VOID_CONFIG.speed_patrol
    if self:GetIsHyper() or self:IsFlyingHyperMode() or not goalPos then
        self.PhantomSprintActive = false
        return normalSpd
    end

    if normalSpd > VOID_CONFIG.speed_patrol then
        self.PhantomSprintActive = false
        return normalSpd
    end

    local refPly = IsValidTargetPlayer(self.current_target) and self.current_target or nil
    if not refPly then
        for _, p in ipairs(player.GetAll()) do
            if IsValidTargetPlayer(p) then
                refPly = p
                break
            end
        end
    end
    if not refPly then
        self.PhantomSprintActive = false
        return normalSpd
    end

    local botPos = self:GetPos()
    local plyPos = refPly:GetPos()
    local dist = botPos:Distance(plyPos)
    local dz = math.abs(plyPos.z - botPos.z)
    local minSprintDist = VOID_CONFIG.phantom_sprint_min_dist or 1450
    local sameFloorZ = VOID_CONFIG.sector_same_floor_z or 240

    local needsFastTransit = (dist >= minSprintDist) or (dz > sameFloorZ and dist >= 750)
    if not needsFastTransit then
        self.PhantomSprintActive = false
        return normalSpd
    end

    -- Debe estar 100% fuera de la vista de todos los jugadores tanto ahora como 95 HU más adelante
    if self:DoesAnyAlivePlayerSeeVoidSilhouette(botPos) then
        self.PhantomSprintActive = false
        return normalSpd
    end

    local nextWaypoint = goalPos
    if self.ActivePath and self.ActivePath:IsValid() then
        local curGoal = self.ActivePath:GetCurrentGoal()
        if curGoal and curGoal.pos then
            nextWaypoint = curGoal.pos
        end
    end

    local stepVec = nextWaypoint - botPos
    local stepLen = stepVec:Length()
    if stepLen > 1.0 then
        local lookAheadPos = botPos + (stepVec / stepLen) * math.min(95.0, stepLen)
        if self:DoesAnyAlivePlayerSeeVoidSilhouette(lookAheadPos) then
            self.PhantomSprintActive = false
            return normalSpd
        end
    end

    self.PhantomSprintActive = true
    return VOID_CONFIG.speed_phantom_stalk or 620
end

function ENT:MoveTowardsGoal(goalPos, speed, forceRecompute)
    if not goalPos or self:IsFlyingHyperMode() then return false end
    self.PhantomSprintActive = (not self:GetIsHyper()) and (speed >= ((VOID_CONFIG.speed_phantom_stalk or 620) - 5))
    self.loco:SetDesiredSpeed(speed)

    local now = CurTime()
    local curB = self:GetBehaviorBranch()
    local isFastMove = (curB == 2 or curB == 7 or curB == 10 or self.PhantomSprintActive)
    local driftThresholdSqr = isFastMove and 1600 or 6400

    local needRecompute = forceRecompute
        or (not self.ActivePath)
        or (not self.ActivePath:IsValid())
        or (now >= self.NextPathRecompute)
        or (self.ActiveGoalPos and self.ActiveGoalPos:DistToSqr(goalPos) > driftThresholdSqr)

    if needRecompute then
        local path = Path("Follow")
        local isHyper = self:GetIsHyper()
        path:SetMinLookAheadDistance(isHyper and 220 or (self.PhantomSprintActive and 195 or 165))
        path:SetGoalTolerance((curB == 2 or curB == 7) and 10 or 25)
        local ok = path:Compute(self, goalPos)

        if isHyper then
            self.NextPathRecompute = now + 0.12
        elseif isFastMove then
            self.NextPathRecompute = now + 0.20
        else
            self.NextPathRecompute = now + 0.42
        end

        if ok and path:IsValid() then
            self.ActivePath = path
            self.ActiveGoalPos = goalPos
            self.UnreachableStrikes = 0
            return true
        else
            self.ActivePath = nil
            self.UnreachableStrikes = (self.UnreachableStrikes or 0) + 1
            return false
        end
    end

    return true
end

function ENT:CanDirectRushTarget(plyPos)
    local botPos = self:GetPos()
    local dz = math.abs(plyPos.z - botPos.z)
    if dz > 42 then
        return false
    end

    local dist2DSqr = (plyPos.x - botPos.x) * (plyPos.x - botPos.x) + (plyPos.y - botPos.y) * (plyPos.y - botPos.y)
    if dist2DSqr > (260 * 260) then
        return false
    end

    local trWall = util.TraceHull({
        start = botPos + Vector(0, 0, 26),
        endpos = plyPos + Vector(0, 0, 26),
        mins = Vector(-14, -14, -4),
        maxs = Vector(14, 14, 44),
        filter = self,
        mask = MASK_NPCSOLID_BRUSHONLY,
    })
    return not trWall.Hit
end

function ENT:HandleNearbyDoorsAndObstacles()
    local now = CurTime()
    if now < (self.NextDoorScanAt or 0) then
        return
    end
    self.NextDoorScanAt = now + 0.12

    local pos = self:GetPos()
    local isHyper = self:GetIsHyper()
    for _, ent in ipairs(ents.FindInSphere(pos + Vector(0, 0, 40), 78)) do
        if IsValid(ent) then
            local cls = ent:GetClass()
            if cls == "prop_door_rotating" or cls == "func_door" or cls == "func_door_rotating" then
                if isHyper then
                    ent:Fire("Unlock", "", 0)
                    ent:Fire("SetSpeed", "500", 0)
                end
                ent:Fire("Open", "", 0)
            elseif isHyper and cls == "prop_physics" then
                local phys = ent:GetPhysicsObject()
                if IsValid(phys) then
                    local pushDir = (ent:GetPos() - pos):GetNormalized() + Vector(0, 0, 0.35)
                    phys:Wake()
                    phys:ApplyForceCenter(pushDir * phys:GetMass() * 450)
                end
            end
        end
    end
end

function ENT:IsHullClearAt(pos)
    local tr = util.TraceHull({
        start = pos,
        endpos = pos,
        mins = VOID_CONFIG.hull_mins,
        maxs = VOID_CONFIG.hull_maxs,
        filter = self,
        mask = MASK_NPCSOLID,
    })
    return not tr.Hit
end

-- Evalúa si un punto concreto de la silueta del sprite 2D es visible (no bloqueado por geometría OPACA)
local TRANSPARENT_CONTENTS_MASK = bit.bor(CONTENTS_GRATE, CONTENTS_TRANSLUCENT, CONTENTS_WINDOW)

local function IsPointVisibleToEye(pt, plyEye, ply, filterEnt)
    local traceFilter = BuildPlayerTraceFilter(ply, filterEnt)

    local trOpaque = util.TraceLine({
        start = plyEye,
        endpos = pt,
        filter = traceFilter,
        mask = MASK_OPAQUE,
    })
    if trOpaque.Hit and not IsEntityPlayerOrVehicle(trOpaque.Entity, ply) and trOpaque.Fraction < 0.995 then
        return false
    end

    -- Segunda verificación contra props opacos grandes (puertas cerradas, contenedores) ignorando rejas/cristales
    local trBlock = util.TraceLine({
        start = plyEye,
        endpos = pt,
        filter = traceFilter,
        mask = MASK_BLOCKLOS_AND_NPCS,
    })
    if trBlock.Hit and not IsEntityPlayerOrVehicle(trBlock.Entity, ply) and trBlock.Fraction < 0.995 then
        if bit.band(trBlock.Contents or 0, TRANSPARENT_CONTENTS_MASK) == 0 then
            return false
        end
    end

    return true
end

-- Comprobación volumétrica de 6 extremos del sprite 118x118 (#7: impide que se asome la frente en rampas o un costado en esquinas)
function ENT:IsSilhouetteVisibleToPlayer(basePos, ply)
    if not IsValidTargetPlayer(ply) then
        return false
    end

    local plyEye = ply:EyePos()
    local halfW = VOID_CONFIG.silhouette_half_width or 66
    local topZ = VOID_CONFIG.silhouette_top_z or 122

    -- 1. Frente / coronilla superior (+122 Z): el primer punto que queda expuesto en rampas y desniveles
    if IsPointVisibleToEye(basePos + Vector(0, 0, topZ), plyEye, ply, self) then
        return true
    end

    -- 2. Centro del torso (+58 Z)
    if IsPointVisibleToEye(basePos + Vector(0, 0, 58), plyEye, ply, self) then
        return true
    end

    local dx = basePos.x - plyEye.x
    local dy = basePos.y - plyEye.y
    local len2D = math.sqrt(dx * dx + dy * dy)
    local right = (len2D > 1.0) and Vector(-dy / len2D, dx / len2D, 0) or Vector(0, 1, 0)
    local sideOffset = right * halfW

    -- 3 y 4. Costados laterales (+58 Z +- 66 HU): detectan bordes de muros, columnas y esquinas
    if IsPointVisibleToEye(basePos + Vector(0, 0, 58) + sideOffset, plyEye, ply, self) then
        return true
    end
    if IsPointVisibleToEye(basePos + Vector(0, 0, 58) - sideOffset, plyEye, ply, self) then
        return true
    end

    -- 5 y 6. Esquinas superiores de la imagen (+116 Z +- 66 HU): detectan rampas diagonales y barandales bajos
    if IsPointVisibleToEye(basePos + Vector(0, 0, 116) + sideOffset, plyEye, ply, self) then
        return true
    end
    if IsPointVisibleToEye(basePos + Vector(0, 0, 116) - sideOffset, plyEye, ply, self) then
        return true
    end

    return false
end

function ENT:DoesAnyAlivePlayerSeeVoidSilhouette(testPos)
    local origin = testPos or self:GetPos()
    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) and self:IsSilhouetteVisibleToPlayer(origin, ply) then
            return true
        end
    end
    return false
end

function ENT:DoesAnyAlivePlayerSeeVoid()
    return self:DoesAnyAlivePlayerSeeVoidSilhouette(self:GetPos())
end

-- Teletransporte Enmascarado en 3 capas: elimina 100% los frames de interpolación direccional (#3)
function ENT:PerformMaskedTeleport(destPos, instantNoDelay)
    if not destPos then return false end

    local now = CurTime()
    if not instantNoDelay
        and now < (self.PendingTeleportUntil or 0)
        and self.LastMaskedTeleportDest
        and self.LastMaskedTeleportDest:DistToSqr(destPos) <= (32 * 32)
    then
        return true
    end

    self.LastMaskedTeleportDest = destPos
    self.TeleportToken = (self.TeleportToken or 0) + 1
    local myToken = self.TeleportToken

    if self.SetTeleportCloak then self:SetTeleportCloak(true) end
    self:SetNWBool("VoidTeleportCloak", true)

    net.Start("Void_TeleportCloak")
    net.WriteUInt(self:EntIndex(), 16)
    net.WriteFloat(instantNoDelay and 0.28 or 0.38)
    net.Broadcast()

    local function ApplyDestination()
        if not IsValid(self) or self.TeleportToken ~= myToken then return end
        self:AddEffects(EF_NOINTERP)
        self:SetPos(destPos)
        self:AddEffects(EF_NOINTERP)
        if self.loco then
            self.loco:ClearStuck()
            self.loco:SetVelocity(vector_origin)
        end
        self.ActivePath = nil
        self.ActiveGoalPos = nil
        self.StuckSince = nil
        self.UnreachableStrikes = 0
        self.DiscoveryGraceUntil = CurTime() + 1.25
    end

    local function UncloakAfterInterp()
        if not IsValid(self) or self.TeleportToken ~= myToken then return end
        self:RemoveEffects(EF_NOINTERP)
        self:SetNoDraw(false)
        if self.SetTeleportCloak then self:SetTeleportCloak(false) end
        self:SetNWBool("VoidTeleportCloak", false)
    end

    if instantNoDelay then
        self:SetNoDraw(true)
        ApplyDestination()
        timer.Simple(0.22, UncloakAfterInterp)
    else
        -- Ocultar en su sitio actual 70 ms ANTES de mover coordenadas para que ningún cliente interpole el viaje
        self.PendingTeleportUntil = CurTime() + 0.09
        self:SetNoDraw(true)
        self:StopMotionAndLookAt(nil)
        if self.loco then
            self.loco:SetVelocity(vector_origin)
        end
        timer.Simple(0.07, ApplyDestination)
        timer.Simple(0.27, UncloakAfterInterp)
    end

    return true
end

function ENT:FindNearestValidTeleportPos(refPos)
    local area = navmesh.GetNearestNavArea(refPos, true, 1500, false, false)
    if not IsValid(area) then
        local all = GetCachedNavAreas()
        local bestDist = math.huge
        for _, a in ipairs(all) do
            if IsValid(a) then
                local d = a:GetCenter():DistToSqr(refPos)
                if d < bestDist then
                    bestDist = d
                    area = a
                end
            end
        end
    end

    if IsValid(area) then
        local candidate = area:GetClosestPointOnArea(refPos) + Vector(0, 0, 4)
        if not self:IsHullClearAt(candidate) then
            candidate = area:GetCenter() + Vector(0, 0, 4)
        end
        return candidate
    end
    return nil
end

-- Muestrea múltiples puntos candidatos dentro de un CNavArea (esencial en explanadas/estacionamientos > 280x280 HU de gm_mallparking)
local function CollectAreaSamplePoints(area, outList)
    if not IsValid(area) or area:GetSizeX() < 32 or area:GetSizeY() < 32 then
        return
    end

    outList[#outList + 1] = area:GetCenter() + Vector(0, 0, 4)

    local spots = area:GetHidingSpots()
    if spots and #spots > 0 then
        for s = 1, math.min(#spots, 2) do
            outList[#outList + 1] = spots[s] + Vector(0, 0, 4)
        end
    end

    if area:GetSizeX() > 280 or area:GetSizeY() > 280 then
        outList[#outList + 1] = area:GetRandomPoint() + Vector(0, 0, 4)
        outList[#outList + 1] = area:GetRandomPoint() + Vector(0, 0, 4)
    end
end

function ENT:FindHiddenVantagePos(minDist, maxDist, anchorPly)
    local allAreas = GetCachedNavAreas()
    local total = #allAreas
    if total == 0 then
        return nil
    end

    minDist = minDist or VOID_CONFIG.range_spawn_hide_min
    maxDist = maxDist or VOID_CONFIG.range_spawn_hide_max

    local alivePlayers = {}
    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            alivePlayers[#alivePlayers + 1] = ply
        end
    end

    -- Si ningún jugador está vivo en este tick exacto (ej. muerte en singleplayer), anclar cerca del jugador/spawn y NO a 12,000 HU
    if #alivePlayers == 0 then
        local fallbackAnchor = (IsValid(anchorPly) and anchorPly:GetPos())
            or (IsValid(player.GetAll()[1]) and player.GetAll()[1]:GetPos())
            or (IsValid(ents.FindByClass("info_player_start")[1]) and ents.FindByClass("info_player_start")[1]:GetPos())

        if fallbackAnchor then
            local nearSpawnAreas = navmesh.Find(fallbackAnchor, maxDist + 400, 320, 320) or {}
            for i = 1, math.min(#nearSpawnAreas, 28) do
                local a = nearSpawnAreas[math.random(1, #nearSpawnAreas)]
                if IsValid(a) and a:GetSizeX() >= 32 and a:GetSizeY() >= 32 then
                    local c = a:GetCenter() + Vector(0, 0, 4)
                    local d = c:Distance(fallbackAnchor)
                    if d >= 700 and d <= (maxDist + 400) and self:IsHullClearAt(c) then
                        return c
                    end
                end
            end
        end

        for _ = 1, math.min(total, 20) do
            local a = allAreas[math.random(1, total)]
            if IsValid(a) and a:GetSizeX() >= 32 and a:GetSizeY() >= 32 then
                local c = a:GetCenter() + Vector(0, 0, 4)
                if self:IsHullClearAt(c) then
                    return c
                end
            end
        end
        return nil
    end

    local refPly = (IsValidTargetPlayer(anchorPly) and anchorPly)
        or (IsValidTargetPlayer(self.current_target) and self.current_target)
        or alivePlayers[math.random(1, #alivePlayers)]
    local refPos = refPly:GetPos()
    local idealDist = (minDist + maxDist) * 0.5
    local sameFloorZ = VOID_CONFIG.sector_same_floor_z or 240

    local bestSectorCand = nil
    local bestSectorScore = -math.huge

    local function SearchAreaPool(pool, maxProbes)
        local pCount = #pool
        if pCount == 0 then return end
        local probes = math.min(pCount, maxProbes)
        for i = 1, probes do
            local idx = (pCount <= maxProbes) and i or math.random(1, pCount)
            local area = pool[idx]
            local samples = {}
            CollectAreaSamplePoints(area, samples)

            for s = 1, #samples do
                local cand = samples[s]
                local nearestDist = math.huge
                local anyLos = false

                for _, ply in ipairs(alivePlayers) do
                    local d = cand:Distance(ply:GetPos())
                    if d < nearestDist then
                        nearestDist = d
                    end
                    if d < 520 or self:IsSilhouetteVisibleToPlayer(cand, ply) then
                        anyLos = true
                        break
                    end
                end

                if not anyLos and nearestDist >= 520 then
                    local refDist = cand:Distance(refPos)
                    local dzRef = math.abs(cand.z - refPos.z)
                    local score = nil

                    if refDist >= minDist and refDist <= maxDist then
                        score = 180.0 - math.abs(refDist - idealDist) * 0.08
                    elseif refDist >= 620 and refDist <= (maxDist + 700) then
                        score = 75.0 - math.abs(refDist - minDist) * 0.05
                    end

                    if score then
                        if dzRef <= sameFloorZ then
                            score = score + 140.0
                        elseif dzRef <= 420 then
                            score = score + 45.0
                        else
                            score = score - 95.0
                        end
                        score = score + math.Rand(0.0, 18.0)

                        if score > bestSectorScore and self:IsHullClearAt(cand) then
                            bestSectorScore = score
                            bestSectorCand = cand
                        end
                    end
                end
            end
        end
    end

    -- Pasada 1: Sector topológicamente conectado al piso actual del jugador (2400 HU)
    SearchAreaPool(GetPlayerSectorNavAreas(refPly), 42)
    if bestSectorCand then
        return bestSectorCand
    end

    -- Pasada 2: Sector ampliado (3600 HU) para explanadas muy abiertas (estacionamientos exteriores)
    SearchAreaPool(GetPlayerSectorNavAreas(refPly, 3600), 36)
    if bestSectorCand then
        return bestSectorCand
    end

    -- Pasada 3: Respaldo global ACOTADO (nunca desterrar a VØID a 10,000+ HU en el extremo opuesto del mapa)
    local tier1Best = nil
    local tier2Best = nil
    local tier3Best = nil
    local tier3Closest = math.huge

    local probes = math.min(total, 52)
    for _ = 1, probes do
        local area = allAreas[math.random(1, total)]
        if IsValid(area) and area:GetSizeX() >= 32 and area:GetSizeY() >= 32 then
            local cand = area:GetCenter() + Vector(0, 0, 4)
            local eyeCand = cand + Vector(0, 0, 60)

            local nearestDist = math.huge
            local anyLos = false
            local anyInFrontCone = false

            for _, ply in ipairs(alivePlayers) do
                local d = cand:Distance(ply:GetPos())
                if d < nearestDist then
                    nearestDist = d
                end
                if self:IsSilhouetteVisibleToPlayer(cand, ply) then
                    anyLos = true
                end
                local toCand = (eyeCand - ply:EyePos()):GetNormalized()
                if ply:GetAimVector():Dot(toCand) > -0.05 then
                    anyInFrontCone = true
                end
            end

            if not anyLos and nearestDist >= 650 and nearestDist <= 3400 then
                if self:IsHullClearAt(cand) then
                    tier1Best = cand
                    break
                end
            elseif not anyInFrontCone and nearestDist >= minDist and nearestDist <= 3600 and not tier2Best then
                if self:IsHullClearAt(cand) then
                    tier2Best = cand
                end
            elseif not anyLos and nearestDist >= 600 and nearestDist < tier3Closest then
                if self:IsHullClearAt(cand) then
                    tier3Closest = nearestDist
                    tier3Best = cand
                end
            end
        end
    end

    return tier1Best or tier2Best or tier3Best
end

function ENT:TeleportToHiddenVantage(minDist, maxDist, instantNoDelay, anchorPly)
    local hiddenPos = self:FindHiddenVantagePos(
        minDist or VOID_CONFIG.range_spawn_hide_min,
        maxDist or VOID_CONFIG.range_spawn_hide_max,
        anchorPly
    )
    if hiddenPos then
        return self:PerformMaskedTeleport(hiddenPos, instantNoDelay == true)
    end
    return false
end

-- Busca una cobertura OPACA completa (0% de frente o costados asomados en rampas/esquinas) hacia donde correr (#7)
function ENT:FindCoverHideNavPos(fromPly)
    local botPos = self:GetPos()
    local plyPos = IsValid(fromPly) and fromPly:GetPos() or botPos
    local awayDir = (botPos - plyPos)
    awayDir.z = 0
    if awayDir:LengthSqr() < 1 then
        awayDir = Vector(1, 0, 0)
    else
        awayDir:Normalize()
    end

    local alivePlayers = {}
    for _, p in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(p) then
            alivePlayers[#alivePlayers + 1] = p
        end
    end

    local minR = VOID_CONFIG.range_cover_search_min or 320
    local maxR = VOID_CONFIG.range_cover_search_max or 1350
    local bestCover = nil
    local bestScore = -math.huge

    local function EvaluateCoverCandidate(cand)
        local distFromBot = cand:Distance(botPos)
        local distFromPly = cand:Distance(plyPos)
        if distFromBot < minR or distFromBot > maxR or distFromPly < 340 then
            return
        end

        for _, p in ipairs(alivePlayers) do
            if self:IsSilhouetteVisibleToPlayer(cand, p) then
                return
            end
        end

        -- Verificar además que 40 HU alrededor el techo/rampa tampoco exponga la frente (+122 Z)
        local towardPly2D = (plyPos - cand)
        towardPly2D.z = 0
        if towardPly2D:LengthSqr() > 1 then
            towardPly2D:Normalize()
        end
        local bufferCheckPos = cand + towardPly2D * 34
        local deepClear = true
        for _, p in ipairs(alivePlayers) do
            if IsPointVisibleToEye(bufferCheckPos + Vector(0, 0, VOID_CONFIG.silhouette_top_z or 122), p:EyePos(), p, self) then
                deepClear = false
                break
            end
        end

        local moveDir = (cand - botPos)
        moveDir.z = 0
        moveDir:Normalize()
        local awayDot = awayDir:Dot(moveDir)
        local deepBonus = deepClear and 65.0 or 0.0
        local score = (awayDot * 135.0) + deepBonus - (distFromBot * 0.12)

        if score > bestScore and self:IsHullClearAt(cand) then
            bestScore = score
            bestCover = cand
        end
    end

    local localAreas = navmesh.Find(botPos, maxR, 280, 280)
    if localAreas and #localAreas > 0 then
        local step = math.max(1, math.floor(#localAreas / 36))
        for i = 1, #localAreas, step do
            local area = localAreas[i]
            if IsValid(area) and area:GetSizeX() >= 32 and area:GetSizeY() >= 32 then
                EvaluateCoverCandidate(area:GetCenter() + Vector(0, 0, 4))
                local spots = area:GetHidingSpots()
                if spots and #spots > 0 then
                    EvaluateCoverCandidate(spots[1] + Vector(0, 0, 4))
                end
            end
        end
    end

    if bestCover then
        return bestCover
    end

    return self:FindHiddenVantagePos(750, 1850, fromPly)
end

-- Puntúa posiciones arquitectónicas para acechar desde ESQUINAS, PAREDES o DETRÁS DE REJAS en el mismo piso (#6)
function ENT:EvaluateArchitecturalStalkScore(candPos, ply)
    local plyPos = ply:GetPos()
    local plyEye = ply:EyePos()
    local candEye = candPos + Vector(0, 0, 58)
    local traceFilter = BuildPlayerTraceFilter(ply, self)

    -- Debe poder observar al jugador sin un muro opaco sólido que bloquee el 100% de la visión
    local trOpaque = util.TraceLine({
        start = candEye,
        endpos = plyEye,
        filter = traceFilter,
        mask = MASK_OPAQUE,
    })
    if trOpaque.Hit and not IsEntityPlayerOrVehicle(trOpaque.Entity, ply) and trOpaque.Fraction < 0.995 then
        return nil
    end

    local score = 0.0

    -- Coherencia vertical de piso para mapas multinivel (ej. gm_mallparking)
    local dz = math.abs(candPos.z - plyPos.z)
    if dz <= 160 then
        score = score + 50.0
    elseif dz > 280 then
        score = score - 80.0
    end

    -- 1. ¿Está detrás de una REJA, malla metálica, barandal o ventana translúcida?
    local trSolid = util.TraceLine({
        start = candEye,
        endpos = plyEye,
        filter = traceFilter,
        mask = MASK_SOLID,
    })
    if trSolid.Hit and not IsEntityPlayerOrVehicle(trSolid.Entity, ply) and trSolid.Fraction < 0.98 then
        score = score + 95.0
    end

    -- 2. ¿Está pegado a una ESQUINA, marco de puerta o PARED lateral?
    local toPly2D = (plyPos - candPos)
    toPly2D.z = 0
    if toPly2D:LengthSqr() < 1 then
        toPly2D = Vector(1, 0, 0)
    else
        toPly2D:Normalize()
    end
    local right2D = Vector(-toPly2D.y, toPly2D.x, 0)

    local trLeft = util.TraceLine({
        start = candEye,
        endpos = candEye - right2D * 72,
        filter = self,
        mask = MASK_SOLID_BRUSHONLY,
    })
    local trRight = util.TraceLine({
        start = candEye,
        endpos = candEye + right2D * 72,
        filter = self,
        mask = MASK_SOLID_BRUSHONLY,
    })

    if trLeft.Hit or trRight.Hit then
        score = score + 65.0
        -- Bonificación extra si es el filo de una esquina (la pared termina justo hacia adelante)
        local wallSide = trLeft.Hit and (-right2D) or right2D
        local cornerProbe = candEye + toPly2D * 56 + wallSide * 56
        local trCorner = util.TraceLine({
            start = candEye + toPly2D * 56,
            endpos = cornerProbe,
            filter = self,
            mask = MASK_SOLID_BRUSHONLY,
        })
        if not trCorner.Hit then
            score = score + 45.0
        end
    end

    -- 3. Bonificación por ángulo periférico (fuera de la mira central inmediata del jugador)
    local dirFromPly = (candPos - plyPos):GetNormalized()
    local aimDot = ply:GetAimVector():Dot(dirFromPly)
    if aimDot < 0.40 then
        score = score + 40.0
    end

    return score
end

function ENT:FindObservationVantageForTarget(ply)
    if not IsValidTargetPlayer(ply) then
        return nil
    end
    local plyPos = ply:GetPos()
    local minR = VOID_CONFIG.range_observe_min + 40
    local maxR = VOID_CONFIG.range_observe_max - 40
    local sameFloorZ = VOID_CONFIG.sector_same_floor_z or 240

    local bestArchPos = nil
    local bestArchScore = -math.huge
    local bestFallback = nil
    local bestFallbackDz = math.huge

    local function ScanVantageAreas(areaPool, maxProbes)
        local pCount = #areaPool
        if pCount == 0 then return end
        local probes = math.min(pCount, maxProbes)

        for i = 1, probes do
            local idx = (pCount <= maxProbes) and i or math.random(1, pCount)
            local area = areaPool[idx]
            if IsValid(area) and area:GetSizeX() >= 32 and area:GetSizeY() >= 32 then
                local center = area:GetCenter()
                local isLargeArea = (area:GetSizeX() > 280 or area:GetSizeY() > 280)
                local distCheck = isLargeArea and area:GetClosestPointOnArea(plyPos):Distance(plyPos) or center:Distance(plyPos)

                if distCheck <= (maxR + 220) then
                    local candidates = {}

                    local hidingSpots = area:GetHidingSpots()
                    if hidingSpots then
                        for s = 1, math.min(#hidingSpots, 2) do
                            candidates[#candidates + 1] = hidingSpots[s] + Vector(0, 0, 4)
                        end
                    end

                    -- Muestrear también una esquina del CNavArea retraída 24 HU hacia el centro para respetar el hull
                    local cornerRaw = area:GetCorner(math.random(0, 3))
                    if cornerRaw then
                        local insetDir = (center - cornerRaw)
                        insetDir.z = 0
                        if insetDir:LengthSqr() > 1 then
                            insetDir:Normalize()
                        end
                        candidates[#candidates + 1] = cornerRaw + insetDir * 24 + Vector(0, 0, 4)
                    end

                    candidates[#candidates + 1] = center + Vector(0, 0, 4)

                    if isLargeArea then
                        candidates[#candidates + 1] = area:GetRandomPoint() + Vector(0, 0, 4)
                        candidates[#candidates + 1] = area:GetRandomPoint() + Vector(0, 0, 4)
                    end

                    for cIdx = 1, #candidates do
                        local c = candidates[cIdx]
                        local d = c:Distance(plyPos)
                        if d >= minR and d <= maxR then
                            local archScore = self:EvaluateArchitecturalStalkScore(c, ply)
                            if archScore and archScore > bestArchScore and self:IsHullClearAt(c) then
                                bestArchScore = archScore
                                bestArchPos = c
                            else
                                local dz = math.abs(c.z - plyPos.z)
                                if dz < bestFallbackDz and dz <= (sameFloorZ + 120) and self:IsHullClearAt(c) then
                                    bestFallbackDz = dz
                                    bestFallback = c
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Primero buscar dentro del sector conectado al piso del jugador (éxito inmediato en gm_mallparking)
    ScanVantageAreas(GetPlayerSectorNavAreas(ply), 40)
    if bestArchPos then
        return bestArchPos
    end

    -- Respaldo global únicamente si el sector local no arrojó ningún punto con línea visual
    ScanVantageAreas(GetCachedNavAreas(), 36)
    return bestArchPos or bestFallback
end

-- Calcula el punto exacto LITERALMENTE ENFRENTE del eje visual del jugador AFK a distancia segura (#3)
function ENT:ComputeAFKFrontSpot(ply)
    if not IsValidTargetPlayer(ply) then
        return nil
    end

    local plyPos = ply:GetPos()
    local plyEye = ply:EyePos()
    local baseYaw = ply:EyeAngles().y
    local flatFwd = Angle(0, baseYaw, 0):Forward()
    local traceFilter = BuildPlayerTraceFilter(ply, self)
    local desiredDist = VOID_CONFIG.range_afk_observe or 300
    local minSafeDist = VOID_CONFIG.range_afk_min_safe or 120
    local angleOffsets = { 0, 8, -8, 16, -16, 25, -25 }

    for i = 1, #angleOffsets do
        local testDir = Angle(0, baseYaw + angleOffsets[i], 0):Forward()
        local trFwd = util.TraceLine({
            start = plyEye,
            endpos = plyEye + testDir * (desiredDist + 28),
            filter = traceFilter,
            mask = MASK_NPCSOLID,
        })

        local useDist = desiredDist
        if trFwd.Hit then
            useDist = (trFwd.Fraction * (desiredDist + 28)) - 34
        end

        if useDist >= minSafeDist then
            local horiz = plyPos + testDir * useDist
            local trDown = util.TraceHull({
                start = Vector(horiz.x, horiz.y, plyEye.z + 36),
                endpos = Vector(horiz.x, horiz.y, plyPos.z - 180),
                mins = VOID_CONFIG.hull_mins,
                maxs = VOID_CONFIG.hull_maxs,
                filter = traceFilter,
                mask = MASK_NPCSOLID,
            })

            local groundPos = nil
            if trDown.Hit and not trDown.StartSolid then
                groundPos = trDown.HitPos + Vector(0, 0, 2)
            else
                local nearArea = navmesh.GetNearestNavArea(horiz, false, 180, false, false)
                if IsValid(nearArea) then
                    groundPos = nearArea:GetClosestPointOnArea(horiz) + Vector(0, 0, 4)
                end
            end

            if groundPos then
                local toGround2D = Vector(groundPos.x - plyPos.x, groundPos.y - plyPos.y, 0)
                local gDist2D = toGround2D:Length()
                local gDot = (gDist2D > 1.0) and flatFwd:Dot(toGround2D / gDist2D) or -1.0

                if gDot >= 0.88
                    and math.abs(groundPos.z - plyPos.z) <= 135
                    and groundPos:Distance(plyPos) >= (minSafeDist - 10)
                    and self:IsHullClearAt(groundPos)
                    and CheckLineOfSightFromPos(groundPos + Vector(0, 0, 58), ply, self)
                then
                    return groundPos
                end
            end
        end
    end

    return nil
end

function ENT:AbortParalysis()
    if self.ParalysisState then
        local ply = self.ParalysisState.target
        if IsValid(ply) then
            ply:SetNWBool("VoidParalyzed", false)
        end
        self.ParalysisState = nil
    end
    if not self:GetIsHyper() and self.CurrentSpatialMode == "PARALYSIS" then
        self:SetSpatialLoopMode("IDLE")
    end
end

-- ============================================================================
-- LAS RAMAS DEL ÁRBOL DE COMPORTAMIENTO (Auditadas y Evolucionadas)
-- ============================================================================

-- RAMA 1: Fallback y Anti-Stuck (Se inhibe en modo de vuelo libre Anti-Noclip y si hay alcance letal directo)
function ENT:Branch1_FallbackAntiStuck(target, st)
    if self:IsFlyingHyperMode() then
        return BT_FAILURE
    end

    local now = CurTime()
    local isPhysicallyStuck = false
    if self.loco and self.loco:IsStuck() then
        self.StuckSince = self.StuckSince or now
        if (now - self.StuckSince) >= 1.40 then
            isPhysicallyStuck = true
        end
    else
        self.StuckSince = nil
    end

    if not IsValidTargetPlayer(target) or not st then
        if isPhysicallyStuck and now >= (self.NextAntiStuckTeleportAt or 0) then
            self.NextAntiStuckTeleportAt = now + (VOID_CONFIG.cooldown_antistuck_tp or 4.5)
            self:TeleportToHiddenVantage(VOID_CONFIG.range_spawn_hide_min, VOID_CONFIG.range_spawn_hide_max, false)
            return BT_SUCCESS
        end
        return BT_FAILURE
    end

    local activelyHunting = self:GetIsHyper() or (st.stalk_phase == "HUNTING")

    -- Jamás secuestrar la prioridad si el objetivo ya está en rango letal o puede embestirse directamente
    if activelyHunting and self:IsTargetInMeleeReach(target) then
        return BT_FAILURE
    end
    if activelyHunting and not isPhysicallyStuck and target:GetMoveType() ~= MOVETYPE_NOCLIP and self:CanDirectRushTarget(st.player_pos) then
        return BT_FAILURE
    end

    local inNoclip = activelyHunting and (target:GetMoveType() == MOVETYPE_NOCLIP)
    local nearArea = activelyHunting and navmesh.GetNearestNavArea(st.player_pos, false, 380, false, false) or nil
    local disconnectedNav = activelyHunting
        and (not inNoclip)
        and (((not IsValid(nearArea)) and (self.UnreachableStrikes or 0) >= 2) or ((self.UnreachableStrikes or 0) >= 4))

    if not inNoclip and not disconnectedNav and not isPhysicallyStuck then
        return BT_FAILURE
    end

    if self.ParalysisState and (inNoclip or isPhysicallyStuck) then
        self:AbortParalysis()
    end

    if isPhysicallyStuck and not activelyHunting then
        if now >= (self.NextAntiStuckTeleportAt or 0) then
            self.NextAntiStuckTeleportAt = now + (VOID_CONFIG.cooldown_antistuck_tp or 4.5)
            self:TeleportToHiddenVantage(850, 2200, false, target)
            return BT_SUCCESS
        end
        return BT_FAILURE
    end

    -- Si el jugador vuela en noclip (y aún no alcanza el límite de abuso), VØID lo clava con la mirada desde abajo
    -- (o camina por debajo suyo si perdió visión) sin spamear teletransportes bruscos.
    if inNoclip then
        if st.has_los then
            self:StopMotionAndLookAt(st.player_pos)
        else
            local groundUnder = self:FindNearestValidTeleportPos(st.player_pos)
            if groundUnder then
                self:MoveTowardsGoal(groundUnder, self:GetIsHyper() and VOID_CONFIG.speed_hyper or VOID_CONFIG.speed_offscreen, false)
            end
        end
        if not self:GetIsHyper() then
            self:SetSpatialLoopMode("IDLE")
        end
        self:SetBehaviorBranch(1)
        return BT_SUCCESS
    end

    if st.has_los and not isPhysicallyStuck then
        self:StopMotionAndLookAt(st.player_pos)
        if not self:GetIsHyper() then
            self:SetSpatialLoopMode("IDLE")
        end
        self:SetBehaviorBranch(1)
        return BT_SUCCESS
    end

    local tpPos = self:FindNearestValidTeleportPos(st.player_pos)
    if isPhysicallyStuck and tpPos and self:GetPos():DistToSqr(tpPos) <= (96 * 96) then
        tpPos = self:FindHiddenVantagePos(650, 1650, target) or tpPos
    end

    if tpPos then
        local distToTpSqr = self:GetPos():DistToSqr(tpPos)
        local canTpNow = now >= (self.NextAntiStuckTeleportAt or 0)

        -- Cooldown explícito (4.5s >> 0.27s de Uncloak) + histéresis de distancia para impedir invisibilidad perpetua
        if canTpNow and (distToTpSqr > (140 * 140) or isPhysicallyStuck) then
            self.NextAntiStuckTeleportAt = now + (VOID_CONFIG.cooldown_antistuck_tp or 4.5)
            self:PerformMaskedTeleport(tpPos, false)
        elseif distToTpSqr > (65 * 65) then
            self:MoveTowardsGoal(tpPos, self:GetIsHyper() and VOID_CONFIG.speed_hyper or VOID_CONFIG.speed_offscreen, false)
        else
            self:StopMotionAndLookAt(st.player_pos)
        end

        if not self:GetIsHyper() then
            self:SetSpatialLoopMode("IDLE")
        end
        self:SetBehaviorBranch(1)
        return BT_SUCCESS
    end

    return BT_FAILURE
end

-- RAMA 2: Hiperagresividad (Terrestre 900 HU/s O Aérea Noclip 3D tras abuso de noclip)
function ENT:Branch2_HyperAggressiveness(target, st)
    local targetTriggered = st and (st.patience_level <= 0)
    if not self:GetIsHyper() and not targetTriggered then
        return BT_FAILURE
    end

    if self:GetIsHyper() and not targetTriggered and not self:HasAnyEnragedAlivePlayer() then
        self:CalmDownToBaseState(true)
        return BT_FAILURE
    end

    if self:IsFlyingHyperMode() and not self:HasAnyFlyingEnragedAlivePlayer() then
        self:ExitFlyingToTerrestrialHyper()
    end

    if not self:GetIsHyper() then
        self:TriggerHyperAggressive(target)
    elseif not self:IsFlyingHyperMode() and self.loco then
        self.loco:SetAcceleration(VOID_CONFIG.acceleration_hyper)
    end

    self:SetBehaviorBranch(2)
    self:SyncNetworkAudioMode(VOID_AUDIO_HYPER)

    -- Protección estricta multijugador: jamás ejecutar en Rama 2 a un jugador inocente (patience > 0)
    if not IsValidTargetPlayer(target) or not st or st.patience_level > 0 then
        if not self:HasAnyEnragedAlivePlayer() then
            self:CalmDownToBaseState(true)
            return BT_FAILURE
        end
        if not self:IsFlyingHyperMode() then
            self:RunIdlePatrolMovement(VOID_CONFIG.speed_hyper, true)
        end
        return BT_RUNNING
    end

    if self:IsTargetInMeleeReach(target) then
        self:ExecuteTarget(target)
        return BT_SUCCESS
    end

    if not self:IsFlyingHyperMode() then
        self:MoveTowardsGoal(target:GetPos(), VOID_CONFIG.speed_hyper, false)
    end

    return BT_RUNNING
end

-- RAMA 3: Parálisis por Acecho con Nodo de Decisión Cognitiva No Predecible (#1)
function ENT:Branch3_StalkingParalysis(target, st)
    if not IsValidTargetPlayer(target) or not st or self:GetIsHyper() then
        return BT_FAILURE
    end

    local now = CurTime()
    local dt = self.CurrentBrainDt or VOID_CONFIG.tick_rate_brain

    if self.ParalysisState then
        if self.ParalysisState.target ~= target
            or not IsValidTargetPlayer(target)
            or target:InVehicle()
            or target:GetMoveType() == MOVETYPE_NOCLIP
        then
            self:AbortParalysis()
            return BT_FAILURE
        end

        self:SetBehaviorBranch(3)
        target:SetNWBool("VoidParalyzed", true)

        if self.ParalysisState.phase == "APPROACH" then
            if st.has_los then
                self.ParalysisState.lostLosAccum = 0.0
            else
                self.ParalysisState.lostLosAccum = (self.ParalysisState.lostLosAccum or 0.0) + dt
            end

            local dirFromPly = (self:GetPos() - st.player_pos)
            dirFromPly.z = 0
            if dirFromPly:LengthSqr() > 1 then
                dirFromPly:Normalize()
            else
                dirFromPly = Vector(1, 0, 0)
            end

            local stopPoint = st.player_pos + dirFromPly * VOID_CONFIG.range_paralysis_stop
            local nearStopArea = navmesh.GetNearestNavArea(stopPoint, false, 160, false, true)
            if IsValid(nearStopArea) then
                stopPoint = nearStopArea:GetClosestPointOnArea(stopPoint)
            end

            -- Si se cerró una puerta/obstáculo o no existe ruta hacia el jugador, liberar parálisis y escapar oculto
            if (self.ParalysisState.lostLosAccum or 0.0) >= 2.2
                or (((self.UnreachableStrikes or 0) >= 3) and not self:CanDirectRushTarget(stopPoint))
            then
                self:AbortParalysis()
                self.paralysis_cooldown_timer = now + 25.0
                self:TeleportToHiddenVantage(VOID_CONFIG.range_paralysis_escape, VOID_CONFIG.range_spawn_hide_max, false, target)
                st.stalk_phase = "OBSERVING"
                st.observe_accum_time = 0.0
                st.observe_target_duration = RollObservationDuration()
                st.player_stare_accum = 0.0
                st.has_trail = false
                st.trail_until = 0
                self:SetSpatialLoopMode("IDLE")
                return BT_SUCCESS
            end

            if st.distance_to_void <= (VOID_CONFIG.range_paralysis_stop + 2) or now >= self.ParalysisState.approachEndTime then
                self.ParalysisState.phase = "STARE"
                self.ParalysisState.stareEndTime = now + VOID_CONFIG.timer_paralysis_stare
                self:StopMotionAndLookAt(st.player_pos)
                if self.loco then
                    self.loco:SetVelocity(vector_origin)
                end
                self:SetSpatialLoopMode("NONE")
            else
                self:SetSpatialLoopMode("PARALYSIS")
                self:MoveTowardsGoal(stopPoint, VOID_CONFIG.speed_paralysis, false)
            end
            return BT_RUNNING

        elseif self.ParalysisState.phase == "STARE" then
            self:StopMotionAndLookAt(st.player_pos)
            if now >= self.ParalysisState.stareEndTime then
                target:SetNWBool("VoidParalyzed", false)
                self.ParalysisState = nil
                self.paralysis_cooldown_timer = now + math.Rand(VOID_CONFIG.cooldown_paralysis_min, VOID_CONFIG.cooldown_paralysis_max)

                -- Desaparición limpia sin frames fantasma (> 1200 HU) dentro del sector conectado del jugador
                self:TeleportToHiddenVantage(VOID_CONFIG.range_paralysis_escape, VOID_CONFIG.range_spawn_hide_max, false, target)
                st.stalk_phase = "OBSERVING"
                st.observe_accum_time = 0.0
                st.observe_target_duration = RollObservationDuration()
                st.player_stare_accum = 0.0
                st.has_trail = false
                st.trail_until = 0
                self:SetSpatialLoopMode("IDLE")
                return BT_SUCCESS
            end
            return BT_RUNNING
        end
    end

    if now >= self.paralysis_cooldown_timer
        and now >= (self.paralysis_rethink_until or 0)
        and st.stalk_phase ~= "UNDISCOVERED"
        and st.stalk_phase ~= "RETREATING"
        and st.has_los
        and st.is_player_looking
        and st.distance_to_void < VOID_CONFIG.range_paralysis_trigger
        and st.distance_to_void > (VOID_CONFIG.range_paralysis_stop + 15)
        and not st.is_AFK
        and not target:InVehicle()
        and target:GetMoveType() ~= MOVETYPE_NOCLIP
    then
        -- NODO DE DECISIÓN TÁCTICA (#1): La IA evalúa si conviene paralizar ahora o seguir cazando/acechando
        local triggerProb = (st.stalk_phase == "HUNTING")
            and (VOID_CONFIG.chance_paralysis_in_chase or 0.28)
            or (VOID_CONFIG.chance_paralysis_in_observe or 0.35)

        if not self.ForceNextParalysis and math.random() > triggerProb then
            -- Decide NO usar Parálisis en este encuentro para ser impredecible
            self.paralysis_rethink_until = now + math.Rand(VOID_CONFIG.paralysis_rethink_min, VOID_CONFIG.paralysis_rethink_max)
            return BT_FAILURE
        end

        self.ForceNextParalysis = false
        self.ParalysisState = {
            target = target,
            phase = "APPROACH",
            approachEndTime = now + VOID_CONFIG.duration_paralysis_sound,
            stareEndTime = 0,
            lostLosAccum = 0.0,
        }
        target:SetNWBool("VoidParalyzed", true)
        self:SetSpatialLoopMode("PARALYSIS")
        self:MoveTowardsGoal(st.player_pos, VOID_CONFIG.speed_paralysis, true)
        self:SetBehaviorBranch(3)
        return BT_RUNNING
    end

    return BT_FAILURE
end

-- RAMA 4: Reacción a Provocaciones (Hiperagresividad terrestre al llegar paciencia a 0)
function ENT:Branch4_ProvocationReaction(target, st)
    if self:GetIsHyper() then
        return BT_FAILURE
    end

    local now = CurTime()
    local penalizedAny = false
    local triggeredHyperPly = nil

    for _, ply in ipairs(player.GetAll()) do
        if IsValidTargetPlayer(ply) then
            local pst = self:GetPlayerMemory(ply)
            if pst and now >= pst.provoke_debounce_until then
                local penalty = 0
                if pst.crouch_count >= VOID_CONFIG.teabag_crouch_count then
                    penalty = VOID_CONFIG.penalty_teabag
                    pst.crouch_count = 0
                    pst.crouch_timestamps = {}
                elseif pst.is_orbiting then
                    penalty = VOID_CONFIG.penalty_orbit
                    pst.is_orbiting = false
                    pst.orbit_accum_time = 0
                end

                if penalty > 0 then
                    pst.patience_level = math.max(0, pst.patience_level - penalty)
                    pst.provoke_debounce_until = now + VOID_CONFIG.provoke_debounce
                    pst.stalk_phase = "HUNTING"
                    pst.hunt_started_at = now
                    pst.has_trail = true
                    pst.trail_until = now + VOID_CONFIG.trail_memory_duration
                    self.paralysis_rethink_until = 0
                    self.patience_level = math.min(self.patience_level, pst.patience_level)
                    penalizedAny = true

                    if pst.patience_level <= 0 then
                        triggeredHyperPly = ply
                    end
                end
            end
        end
    end

    if triggeredHyperPly then
        self:TriggerHyperAggressive(triggeredHyperPly)
        return self:Branch2_HyperAggressiveness(triggeredHyperPly, self:GetPlayerMemory(triggeredHyperPly))
    end

    if penalizedAny then
        local provTarget = self:SelectTarget()
        if IsValidTargetPlayer(provTarget) then
            local pst = self:GetPlayerMemory(provTarget)
            if pst and pst.stalk_phase == "HUNTING" then
                return self:Branch7_DynamicHunt(provTarget, pst)
            end
        end
        return BT_SUCCESS
    end

    return BT_FAILURE
end

-- RAMA 5: Acorralamiento (El Depredador Curioso)
function ENT:Branch5_Cornering(target, st)
    if not IsValidTargetPlayer(target) or not st or self:GetIsHyper() then
        return BT_FAILURE
    end

    if not st.is_cornered or st.is_AFK then
        return BT_FAILURE
    end

    -- Impedir que el jugador acorralado cruce caminando a través del cuerpo de VØID sin recibir ataque
    if self:IsTargetInMeleeReach(target) then
        self:ExecuteTarget(target)
        return BT_SUCCESS
    end

    if st.is_panicking then
        self:TriggerHyperAggressive(target)
        self:SetBehaviorBranch(2)
        return BT_SUCCESS
    end

    local now = CurTime()
    if not st.corner_started_at or st.corner_started_at <= 0 then
        st.corner_started_at = now
    end

    -- Límite anti-bloqueo (24s): si nadie se mueve, cerrar distancia pasando limpiamente a Caza Dinámica
    if (now - st.corner_started_at) >= (VOID_CONFIG.timer_corner_max_stare or 24.0) then
        st.is_cornered = false
        st.corner_started_at = 0.0
        st.stalk_phase = "HUNTING"
        st.hunt_started_at = now
        st.has_trail = true
        st.trail_until = now + VOID_CONFIG.trail_memory_duration
        return self:Branch7_DynamicHunt(target, st)
    end

    self:SetBehaviorBranch(5)
    self:SetSpatialLoopMode("IDLE")
    local blockPos = st.corner_choke_pos or self:GetPos()
    local distToBlock = self:GetPos():Distance(blockPos)

    if distToBlock > 45 and st.distance_to_void > 125 then
        self:MoveTowardsGoal(blockPos, VOID_CONFIG.speed_patrol, false)
    else
        self:StopMotionAndLookAt(st.player_pos)
    end

    return BT_RUNNING
end

-- RAMA 6: Interacción AFK tras 30s — Aparición Literalmente ENFRENTE del Jugador (#3)
function ENT:Branch6_AFKInteraction(target, st)
    if not IsValidTargetPlayer(target) or not st or self:GetIsHyper() then
        return BT_FAILURE
    end

    if not st.is_AFK or st.stalk_phase == "RETREATING" then
        self.AFKTargetFrontPos = nil
        return BT_FAILURE
    end

    local now = CurTime()
    self:SetBehaviorBranch(6)
    self:SetSpatialLoopMode("IDLE")

    -- Si aún estaba como no descubierto, pasar a observación para reaccionar natural cuando despierte
    if st.stalk_phase == "UNDISCOVERED" then
        st.stalk_phase = "OBSERVING"
        st.observe_accum_time = 0.0
        st.observe_target_duration = RollObservationDuration()
        st.player_stare_accum = 0.0
        st.shy_stare_limit = RollShyStareDuration()
    end

    local botPos = self:GetPos()
    local plyPos = target:GetPos()
    local flatFwd = Angle(0, target:EyeAngles().y, 0):Forward()
    local toBot2D = Vector(botPos.x - plyPos.x, botPos.y - plyPos.y, 0)
    local dist2D = toBot2D:Length()
    local frontDot = (dist2D > 1.0) and flatFwd:Dot(toBot2D / dist2D) or -1.0

    local minSafe = (VOID_CONFIG.range_afk_min_safe or 120) - 12
    local maxSafe = (VOID_CONFIG.range_afk_observe or 300) + 45
    -- Umbral alineado con ComputeAFKFrontSpot (gDot >= 0.88 -> +-25°) con margen de histéresis para cero parpadeo
    local alreadyCenteredInFront = (frontDot >= 0.87)
        and (math.abs(botPos.z - plyPos.z) <= 140)
        and (dist2D >= minSafe)
        and (dist2D <= maxSafe)
        and CheckLineOfSight(self, target)

    if alreadyCenteredInFront then
        self.AFKTargetFrontPos = botPos
        self:StopMotionAndLookAt(target:EyePos())
        return BT_RUNNING
    end

    local frontSpot = self:ComputeAFKFrontSpot(target)
    if frontSpot then
        self.AFKTargetFrontPos = frontSpot
        local distToFrontSqr = botPos:DistToSqr(frontSpot)
        if distToFrontSqr <= (36 * 36) then
            self:StopMotionAndLookAt(target:EyePos())
        elseif now >= (self.NextAFKSnapAt or 0) then
            self.NextAFKSnapAt = now + 3.0
            self:PerformMaskedTeleport(frontSpot, false)
            self:StopMotionAndLookAt(target:EyePos())
        else
            self:MoveTowardsGoal(frontSpot, VOID_CONFIG.speed_patrol, false)
        end
    else
        -- Respaldo si el jugador AFK está pegado contra una esquina cerrada
        if st.distance_to_void > VOID_CONFIG.range_afk_observe then
            self:MoveTowardsGoal(st.player_pos, VOID_CONFIG.speed_patrol, false)
        else
            self:StopMotionAndLookAt(target:EyePos())
        end
    end

    return BT_RUNNING
end

-- SUB-RAMA TÁCTICA (#1, #5 y #7): Huida Ocultando 100% la Silueta + Espera 1-2s + Contra-Burla si lo Siguen
function ENT:StartRetreatState(target, st, now)
    st.stalk_phase = "RETREATING"
    st.retreat_cover_pos = self:FindCoverHideNavPos(target)
    st.retreat_unseen_accum = 0.0
    st.retreat_target_wait = RollHideWaitDuration()
    st.retreat_exposed_accum = 0.0
    st.retreat_follow_accum = 0.0
    st.retreat_respot_count = 1
    st.retreat_respot_limit = RollRetreatRespotLimit()
    st.retreat_was_hidden = false
    st.retreat_last_respot_at = now
    st.retreat_started_at = now
    st.retreat_repath_at = now + 1.4
end

function ENT:Branch_RetreatAndHide(target, st)
    if not IsValidTargetPlayer(target) or not st or self:GetIsHyper() then
        return BT_FAILURE
    end

    if st.stalk_phase ~= "RETREATING" then
        return BT_FAILURE
    end

    local now = CurTime()
    local dt = self.CurrentBrainDt or VOID_CONFIG.tick_rate_brain
    self:SetBehaviorBranch(10)
    self:SetSpatialLoopMode("IDLE")

    -- Comprobación volumétrica completa (6 puntos: frente +122 Z y costados +-66 HU contra MASK_OPAQUE)
    local anySeesVoid = self:DoesAnyAlivePlayerSeeVoidSilhouette(self:GetPos())

    -- ========================================================================
    -- DETECCIÓN DE JUGADOR SIGUIÉNDOLO / BURLÁNDOSE DURANTE LA HUIDA (#5)
    -- ========================================================================
    local vel = GetEffectivePlayerVelocity(target)
    local spd2D = vel:Length2D()
    local botPos = self:GetPos()
    local toBot = botPos - st.player_pos
    local dist = toBot:Length()
    local dirToBot = (dist > 1.0) and (toBot / dist) or Vector(1, 0, 0)
    local dirToBot2D = Vector(toBot.x, toBot.y, 0)
    if dirToBot2D:LengthSqr() > 1.0 then
        dirToBot2D:Normalize()
    end

    local moveDot = 0.0
    if spd2D > 10.0 then
        moveDot = Vector(vel.x, vel.y, 0):GetNormalized():Dot(dirToBot2D)
    end
    local aimDot = target:GetAimVector():Dot(dirToBot)
    local closingOrClose = (st.distance_to_void <= (st.prev_distance + 14.0)) or (dist <= 480.0)

    local isFollowingVoid = (spd2D > 85.0) and (
        (moveDot > 0.28 and dist <= 1550.0)
        or (aimDot > 0.35 and closingOrClose and dist <= 1250.0)
    )

    if isFollowingVoid then
        st.retreat_follow_accum = (st.retreat_follow_accum or 0.0) + dt
    else
        st.retreat_follow_accum = math.max(0.0, (st.retreat_follow_accum or 0.0) - (0.15 * dt))
    end

    -- Conteo de avistamientos repetidos (5 a 6 veces doblando esquinas/rampas para verlo esconderse)
    if not anySeesVoid then
        st.retreat_was_hidden = true
    elseif st.retreat_was_hidden and (now - (st.retreat_last_respot_at or 0)) >= 0.60 then
        if st.has_los and (st.is_player_looking or dist <= 900.0) then
            st.retreat_respot_count = (st.retreat_respot_count or 1) + 1
            st.retreat_was_hidden = false
            st.retreat_last_respot_at = now
        end
    end

    local followLimit = VOID_CONFIG.timer_retreat_follow_limit or 10.0
    local respotLimit = st.retreat_respot_limit or 5

    if (st.retreat_follow_accum >= followLimit) or ((st.retreat_respot_count or 0) >= respotLimit) then
        st.retreat_follow_accum = 0.0
        st.retreat_respot_count = 0
        st.retreat_was_hidden = false
        st.retreat_unseen_accum = 0.0
        st.retreat_exposed_accum = 0.0
        st.retreat_cover_pos = nil

        -- Decisión con sesgo favorable a agotar paciencia a 0 y atacar (~65% ataque vs ~35% teletransporte)
        if math.random() <= (VOID_CONFIG.chance_follow_punish_attack or 0.65) then
            st.patience_level = 0
            self:TriggerHyperAggressive(target)
            self:SetBehaviorBranch(2)
            return BT_SUCCESS
        else
            st.stalk_phase = "OBSERVING"
            st.observe_vantage_pos = nil
            st.shy_stare_limit = RollShyStareDuration()
            self.next_tactical_tp_at = now + VOID_CONFIG.cooldown_tactical_tp
            self:TeleportToHiddenVantage(950, 1950, false, target)
            return BT_SUCCESS
        end
    end

    -- ========================================================================
    -- OCULTACIÓN VOLUMÉTRICA COMPLETA + ESPERA ÁGIL DE 1 A 2 SEGUNDOS (#1 y #7)
    -- ========================================================================
    if anySeesVoid then
        -- Mientras se vea aunque sea un borde de la frente o del costado, NO detenerse: seguir corriendo a cobertura
        st.retreat_unseen_accum = 0.0
        st.retreat_exposed_accum = (st.retreat_exposed_accum or 0.0) + dt

        local needNewCover = (not st.retreat_cover_pos)
            or (now >= (st.retreat_repath_at or 0))
            or (botPos:DistToSqr(st.retreat_cover_pos) < 6400)

        if needNewCover then
            st.retreat_cover_pos = self:FindCoverHideNavPos(target)
            st.retreat_repath_at = now + 1.2
        end

        -- Válvula de escape solo en mapas 100% planos sin paredes tras 14s continuos expuesto
        if st.retreat_exposed_accum >= 14.0 and now >= (self.next_tactical_tp_at or 0) then
            self.next_tactical_tp_at = now + VOID_CONFIG.cooldown_tactical_tp
            st.stalk_phase = "OBSERVING"
            st.shy_stare_limit = RollShyStareDuration()
            st.retreat_unseen_accum = 0.0
            st.retreat_exposed_accum = 0.0
            st.retreat_cover_pos = nil
            self:TeleportToHiddenVantage(900, 1950, false, target)
            return BT_SUCCESS
        end

        if st.retreat_cover_pos then
            self:MoveTowardsGoal(st.retreat_cover_pos, VOID_CONFIG.speed_flee_hide, false)
        else
            self:RunIdlePatrolMovement(VOID_CONFIG.speed_flee_hide, true)
        end

        return BT_RUNNING
    end

    -- Silueta 100% oculta (!anySeesVoid): avanzar 0.35s extra de margen profundo y esperar 1.0 - 2.0s oculto
    st.retreat_exposed_accum = 0.0
    if st.retreat_cover_pos and botPos:DistToSqr(st.retreat_cover_pos) > (110 * 110) and (st.retreat_unseen_accum or 0) < 0.35 then
        self:MoveTowardsGoal(st.retreat_cover_pos, VOID_CONFIG.speed_flee_hide, false)
    else
        self:StopMotionAndLookAt(st.player_pos)
    end

    st.retreat_unseen_accum = (st.retreat_unseen_accum or 0.0) + dt
    local targetWait = st.retreat_target_wait or 1.5

    if st.retreat_unseen_accum >= targetWait then
        st.retreat_unseen_accum = 0.0
        st.retreat_exposed_accum = 0.0
        st.retreat_follow_accum = 0.0
        st.retreat_respot_count = 0
        st.retreat_was_hidden = false
        st.retreat_cover_pos = nil
        st.stalk_phase = "OBSERVING"
        st.observe_vantage_pos = nil
        st.shy_stare_limit = RollShyStareDuration()
        self.next_tactical_tp_at = now + VOID_CONFIG.cooldown_tactical_tp
        self:TeleportToHiddenVantage(900, 1950, false, target)
        return BT_SUCCESS
    end

    return BT_RUNNING
end

-- FASE DE ACECHO CURIOSO: Observación Prolongada desde Esquinas, Paredes y Rejas (#4 y #6)
function ENT:Branch_DistantObservation(target, st)
    if not IsValidTargetPlayer(target) or not st or self:GetIsHyper() then
        return BT_FAILURE
    end

    if st.stalk_phase ~= "OBSERVING" then
        return BT_FAILURE
    end

    local now = CurTime()
    local dt = self.CurrentBrainDt or VOID_CONFIG.tick_rate_brain

    if st.has_los and st.distance_to_void <= (VOID_CONFIG.range_observe_max * 1.18) then
        st.observe_accum_time = st.observe_accum_time + dt
        st.observe_lost_los_accum = 0.0
    else
        st.observe_accum_time = st.observe_accum_time + (dt * 0.15)
        st.observe_lost_los_accum = (st.observe_lost_los_accum or 0.0) + dt
    end

    if st.has_los and st.is_player_looking then
        st.player_stare_accum = st.player_stare_accum + dt
    else
        st.player_stare_accum = math.max(0.0, st.player_stare_accum - (dt * 0.45))
    end

    -- Escalar directamente a Caza Dinámica una vez completada la observación curiosa prolongada (32 - 52s)
    if st.observe_accum_time >= st.observe_target_duration then
        if (not st.is_player_looking) or (st.observe_accum_time >= st.observe_target_duration + 6.0) then
            st.stalk_phase = "HUNTING"
            st.hunt_started_at = now
            st.has_trail = true
            st.trail_until = now + VOID_CONFIG.trail_memory_duration
            self.paralysis_rethink_until = 0
            return self:Branch7_DynamicHunt(target, st)
        end
    end

    self:SetBehaviorBranch(9)
    self:SetSpatialLoopMode("IDLE")

    local stareLimit = st.shy_stare_limit or 3.8

    -- Tras sostener la mirada con curiosidad (3.2 - 4.8s) o si el jugador se acerca demasiado (< 420 HU), huir a esconderse
    if st.distance_to_void < VOID_CONFIG.range_shy_retreat
        or st.player_stare_accum >= stareLimit
    then
        st.player_stare_accum = 0.0
        st.shy_stare_limit = RollShyStareDuration()
        st.observe_vantage_pos = nil

        local canUseRareTp = (now >= (self.next_tactical_tp_at or 0))
            and (math.random() > (VOID_CONFIG.chance_run_hide_vs_tp or 0.85))

        if canUseRareTp then
            self.next_tactical_tp_at = now + VOID_CONFIG.cooldown_tactical_tp
            self:TeleportToHiddenVantage(900, 1900, false, target)
            return BT_RUNNING
        else
            self:StartRetreatState(target, st, now)
            if st.retreat_cover_pos then
                self:MoveTowardsGoal(st.retreat_cover_pos, VOID_CONFIG.speed_flee_hide, true)
            end
            self:SetBehaviorBranch(10)
            return BT_RUNNING
        end
    end

    -- Si ya tiene visión desde una distancia de acecho válida, quedarse inmóvil observando con curiosidad
    if st.has_los and st.distance_to_void <= (VOID_CONFIG.range_observe_max * 1.10) then
        self:StopMotionAndLookAt(st.player_pos)
        return BT_RUNNING
    end

    -- Si ya llegó a su esquina/pared/reja apostada y perdió LOS hace poco (< 6s), aguantar posición acechando sin patrullar
    if st.observe_vantage_pos
        and self:GetPos():DistToSqr(st.observe_vantage_pos) <= (52 * 52)
        and (st.observe_lost_los_accum or 0) < 6.0
        and now < (st.observe_vantage_expire or 0)
    then
        self:StopMotionAndLookAt(st.player_pos)
        return BT_RUNNING
    end

    if (not st.observe_vantage_pos)
        or (now >= (st.observe_vantage_expire or 0))
        or ((st.observe_lost_los_accum or 0) >= 6.0 and self:GetPos():DistToSqr(st.observe_vantage_pos) <= (60 * 60))
    then
        st.observe_vantage_pos = self:FindObservationVantageForTarget(target)
        local travelEta = st.observe_vantage_pos and math.min(self:GetPos():Distance(st.observe_vantage_pos) / 260.0, 18.0) or 0.0
        st.observe_vantage_expire = now + math.Rand(16.0, 26.0) + travelEta
        st.observe_lost_los_accum = 0.0
    end

    if st.observe_vantage_pos then
        if self:GetPos():DistToSqr(st.observe_vantage_pos) > (48 * 48) then
            local stalkSpd = self:ComputeAdaptiveStalkSpeed(st.observe_vantage_pos, VOID_CONFIG.speed_patrol)
            self:MoveTowardsGoal(st.observe_vantage_pos, stalkSpd, false)
        else
            self:StopMotionAndLookAt(st.player_pos)
        end
    else
        self:RunIdlePatrolMovement(VOID_CONFIG.speed_patrol, false)
    end

    return BT_RUNNING
end

-- RAMA 7: Caza Dinámica (510 HU/s Off-Screen / 420 HU/s Mirado — repliegue directo sin caer en Rama 8)
function ENT:Branch7_DynamicHunt(target, st)
    if not IsValidTargetPlayer(target) or not st or self:GetIsHyper() then
        return BT_FAILURE
    end

    if st.stalk_phase ~= "HUNTING" then
        return BT_FAILURE
    end

    local now = CurTime()
    local huntElapsed = now - (st.hunt_started_at or now)

    -- Si perdió el rastro o terminó el ciclo de caza, delegar en el mismo tick a Huida u Observación (sin caer a Rama 8)
    if (not st.has_trail)
        or (huntElapsed >= VOID_CONFIG.timer_hunt_max_duration and not st.has_los)
        or (huntElapsed >= (VOID_CONFIG.timer_hunt_max_duration + 14.0))
    then
        st.observe_accum_time = 0.0
        st.observe_target_duration = RollObservationDuration()
        st.player_stare_accum = 0.0
        st.shy_stare_limit = RollShyStareDuration()
        st.has_trail = false

        if self:DoesAnyAlivePlayerSeeVoidSilhouette(self:GetPos()) then
            self:StartRetreatState(target, st, now)
            return self:Branch_RetreatAndHide(target, st)
        else
            st.stalk_phase = "OBSERVING"
            st.observe_vantage_pos = nil
            return self:Branch_DistantObservation(target, st)
        end
    end

    self:SetBehaviorBranch(7)

    if self:IsTargetInMeleeReach(target) then
        self:ExecuteTarget(target)
        return BT_SUCCESS
    end

    self:SetSpatialLoopMode("CHASE")

    local desiredSpeed = st.is_player_looking and VOID_CONFIG.speed_chase or VOID_CONFIG.speed_offscreen
    self:MoveTowardsGoal(target:GetPos(), desiredSpeed, false)

    return BT_RUNNING
end

-- RAMA 8: Acecho Arquitectónico Prioritario (Esquinas/Paredes/Rejas ~68%) vs Patrulla Moderada (~32%) (#6)
function ENT:RunIdlePatrolMovement(speed, forceRoam)
    local now = CurTime()
    local refPly = IsValidTargetPlayer(self.current_target) and self.current_target or player.GetAll()[1]

    -- Si ya llegó a un punto de acecho arquitectónico (esquina/pared/reja), permanecer apostado en quietud
    if not forceRoam
        and self.IdleIsLurking
        and self.PatrolGoalPos
        and now < (self.PatrolExpireTime or 0)
        and self:GetPos():DistToSqr(self.PatrolGoalPos) <= (52 * 52)
    then
        if IsValidTargetPlayer(refPly) then
            self:StopMotionAndLookAt(refPly:GetPos())
        else
            self:StopMotionAndLookAt(nil)
        end
        return
    end

    local needNewGoal = (not self.PatrolGoalPos)
        or (now >= (self.PatrolExpireTime or 0))
        or (not self.IdleIsLurking and self:GetPos():DistToSqr(self.PatrolGoalPos) < 9000)
        or (self.ActivePath == nil and self.UnreachableStrikes > 0)

    if needNewGoal then
        local chosenPoint = nil
        local wantRoam = forceRoam or (math.random() <= (VOID_CONFIG.chance_patrol_roam or 0.32))

        -- ~68% de probabilidad: priorizar apostarse junto a una esquina, pared o detrás de una reja del sector actual
        if not wantRoam and IsValidTargetPlayer(refPly) then
            chosenPoint = self:FindObservationVantageForTarget(refPly)
            if chosenPoint then
                self.IdleIsLurking = true
                self.PatrolGoalPos = chosenPoint
                local eta = math.min(self:GetPos():Distance(chosenPoint) / 260.0, 16.0)
                self.PatrolExpireTime = now + math.Rand(13.0, 22.0) + eta
                local moveSpd = self:ComputeAdaptiveStalkSpeed(self.PatrolGoalPos, speed)
                self:MoveTowardsGoal(self.PatrolGoalPos, moveSpd, true)
                return
            end
        end

        -- ~32% de probabilidad (o respaldo): patrulla LOCAL en el sector conectado del jugador (evita perderse en gm_mallparking)
        self.IdleIsLurking = false
        if IsValidTargetPlayer(refPly) then
            local refPos = refPly:GetPos()
            local sameFloorZ = VOID_CONFIG.sector_same_floor_z or 240
            local sectorAreas = GetPlayerSectorNavAreas(refPly)
            local total = #sectorAreas
            for _ = 1, math.min(total, 28) do
                local a = sectorAreas[math.random(1, total)]
                if IsValid(a) and a:GetSizeX() >= 32 and a:GetSizeY() >= 32 then
                    local testPt = (a:GetSizeX() > 280 or a:GetSizeY() > 280) and a:GetRandomPoint() or a:GetCenter()
                    local d = testPt:Distance(refPos)
                    local dz = math.abs(testPt.z - refPos.z)
                    if d >= 550 and d <= 1750 and dz <= (sameFloorZ + 80) then
                        local hSpots = a:GetHidingSpots()
                        if hSpots and #hSpots > 0 and math.random() < 0.70 then
                            chosenPoint = hSpots[math.random(1, #hSpots)]
                        else
                            chosenPoint = testPt
                        end
                        break
                    end
                end
            end

            if not chosenPoint and total > 0 then
                local pick = sectorAreas[math.random(1, total)]
                if IsValid(pick) then
                    chosenPoint = pick:GetRandomPoint()
                end
            end
        end

        if not chosenPoint then
            local areas = GetCachedNavAreas()
            if areas and #areas > 0 then
                local pick = areas[math.random(1, #areas)]
                if IsValid(pick) then
                    chosenPoint = pick:GetRandomPoint()
                end
            end
        end

        if chosenPoint then
            self.PatrolGoalPos = chosenPoint
            local eta = math.min(self:GetPos():Distance(chosenPoint) / 260.0, 16.0)
            self.PatrolExpireTime = now + math.Rand(6.5, 11.5) + eta
            local moveSpd = self:ComputeAdaptiveStalkSpeed(self.PatrolGoalPos, speed)
            self:MoveTowardsGoal(self.PatrolGoalPos, moveSpd, true)
        end
    else
        local moveSpd = self:ComputeAdaptiveStalkSpeed(self.PatrolGoalPos, speed)
        self:MoveTowardsGoal(self.PatrolGoalPos, moveSpd, false)
    end
end

function ENT:Branch8_IdleAndParanoia()
    self:SetBehaviorBranch(8)
    self:SetSpatialLoopMode("IDLE")
    self:RunIdlePatrolMovement(VOID_CONFIG.speed_patrol, false)
    return BT_RUNNING
end

-- ============================================================================
-- DIRECTOR MACRO DE REUBICACIÓN EN SECTOR (Adaptación a Mapas Enormes / Multinivel)
-- ============================================================================
function ENT:UpdateMacroDirectorTether(target, st)
    if not IsValidTargetPlayer(target) or not st then
        return false
    end

    if self:GetIsHyper()
        or self:IsFlyingHyperMode()
        or self.ParalysisState
        or st.is_AFK
        or st.stalk_phase == "RETREATING"
        or (st.stalk_phase == "HUNTING" and st.has_trail)
    then
        return false
    end

    local now = CurTime()
    if now < (self.NextDirectorRelocateAt or 0) or now < (self.DiscoveryGraceUntil or 0) then
        return false
    end

    local tetherMaxDist = VOID_CONFIG.sector_tether_max_dist or 3200
    local noLosLimit = VOID_CONFIG.timer_director_no_los_relocate or 22.0
    local noLosElapsed = now - (st.last_los_contact_at or now)
    local unreachableFar = ((self.UnreachableStrikes or 0) >= 3) and (st.distance_to_void > 1200)

    if (st.distance_to_void <= tetherMaxDist) and (noLosElapsed < noLosLimit) and (not unreachableFar) then
        return false
    end

    -- Jamás reubicarse si algún jugador vivo ve cualquier extremo de la silueta de VØID
    if self:DoesAnyAlivePlayerSeeVoidSilhouette(self:GetPos()) then
        return false
    end

    local relocated = self:TeleportToHiddenVantage(
        VOID_CONFIG.sector_relocate_min or 850,
        VOID_CONFIG.sector_relocate_max or 1850,
        false,
        target
    )

    if relocated then
        self.NextDirectorRelocateAt = now + (VOID_CONFIG.cooldown_director_relocate or 14.0)
        st.last_los_contact_at = now
        st.stalk_phase = "OBSERVING"
        st.observe_vantage_pos = nil
        self.PatrolGoalPos = nil
        self.UnreachableStrikes = 0
        return true
    end

    return false
end

-- ============================================================================
-- EVALUADOR MAESTRO DEL CEREBRO (Monitoreado por debajo de 1.5 ms con SysTime)
-- ============================================================================
function ENT:EvaluateBehaviorTree()
    local startTime = SysTime()
    local now = CurTime()

    -- Si hay un pre-ocultamiento de teletransporte en curso (70 ms), esperar a que se complete sin mover
    if now < (self.PendingTeleportUntil or 0) then
        return
    end

    local rawDt = now - (self.LastBrainEvalAt or (now - VOID_CONFIG.tick_rate_brain))
    self.LastBrainEvalAt = now
    self.CurrentBrainDt = math.Clamp(rawDt, 0.05, 0.50)

    self:UpdateAllPlayersPerception()

    if not self:GetIsHyper() and now >= self.next_paranoia_timer then
        self:EmitParanoiaSound()
        self.next_paranoia_timer = now + math.Rand(VOID_CONFIG.timer_paranoia_min, VOID_CONFIG.timer_paranoia_max)
    end

    local target = self:SelectTarget()
    local st = IsValidTargetPlayer(target) and self:GetPlayerMemory(target) or nil

    -- Reubicación sigilosa del Director Macro si el jugador cambió de piso/sector o cruzó un mapa enorme
    if self:UpdateMacroDirectorTether(target, st) then
        self.LastBrainExecMs = (SysTime() - startTime) * 1000.0
        return
    end

    repeat
        if self:Branch1_FallbackAntiStuck(target, st) ~= BT_FAILURE then break end
        if self:Branch2_HyperAggressiveness(target, st) ~= BT_FAILURE then break end
        if self:Branch3_StalkingParalysis(target, st) ~= BT_FAILURE then break end
        if self:Branch4_ProvocationReaction(target, st) ~= BT_FAILURE then break end
        if self:Branch5_Cornering(target, st) ~= BT_FAILURE then break end
        if self:Branch6_AFKInteraction(target, st) ~= BT_FAILURE then break end
        if self:Branch_RetreatAndHide(target, st) ~= BT_FAILURE then break end
        if self:Branch_DistantObservation(target, st) ~= BT_FAILURE then break end
        if self:Branch7_DynamicHunt(target, st) ~= BT_FAILURE then break end
        self:Branch8_IdleAndParanoia()
    until true

    local execTimeMs = (SysTime() - startTime) * 1000.0
    self.LastBrainExecMs = execTimeMs
    if execTimeMs > 1.5 then
        print(string.format("[VØID WARNING] Cerebro lento: %.3f ms", execTimeMs))
    end
end

-- ============================================================================
-- CORRUTINA PRINCIPAL: VUELO 3D ANTI-NOCLIP + PERSECUCIÓN TERMINAL + XPCALL
-- ============================================================================
function ENT:BodyUpdate()
end

function ENT:StepMotorAndBrain(now)
    if now >= (self.NextMicroSample or 0) then
        self.NextMicroSample = now + 0.06
        self:SampleCameraAndAFK()

        if not self:GetIsHyper() and self:GetBehaviorBranch() == 7 and IsValidTargetPlayer(self.current_target) then
            local hasLos = CheckLineOfSight(self, self.current_target)
            local looking = false
            if hasLos then
                local dirToBot = ((self:GetPos() + Vector(0, 0, 64)) - self.current_target:EyePos()):GetNormalized()
                looking = (self.current_target:GetAimVector():Dot(dirToBot) >= VOID_CONFIG.fov_dot_threshold)
            end
            self.loco:SetDesiredSpeed(looking and VOID_CONFIG.speed_chase or VOID_CONFIG.speed_offscreen)
        elseif not self:GetIsHyper() and self.PhantomSprintActive and self:DoesAnyAlivePlayerSeeVoidSilhouette(self:GetPos()) then
            -- Freno instantáneo (< 60 ms) de Sprint Fantasma a paso normal si algún jugador gana visión de su silueta
            self.PhantomSprintActive = false
            if self.loco then
                self.loco:SetDesiredSpeed(VOID_CONFIG.speed_patrol)
            end
        end
    end

    if now >= self.NextBrainTick then
        self.NextBrainTick = now + VOID_CONFIG.tick_rate_brain
        self:EvaluateBehaviorTree()
    end

    -- Si está esperando 70 ms de pre-ocultación antes de SetPos, mantener quietud absoluta
    if now < (self.PendingTeleportUntil or 0) then
        return
    end

    local curBranch = self:GetBehaviorBranch()

    -- MODO EXCLUSIVO DE VUELO 3D ("NOCLIP") EN HIPERAGRESIVIDAD ANTI-NOCLIP (#6)
    if self:GetIsHyper() and self:IsFlyingHyperMode() and IsValidTargetPlayer(self.current_target) then
        local tgt = self.current_target
        if self.loco then
            self.loco:SetGravity(0)
            self.loco:SetDesiredSpeed(0)
            self.loco:SetVelocity(vector_origin)
        end

        if self:IsTargetInMeleeReach(tgt) then
            self:ExecuteTarget(tgt)
        else
            local dt = engine.TickInterval()
            local botPos = self:GetPos()
            -- Alinear el centro vertical de VØID (+40 HU) con el centro del jugador en pleno vuelo 3D
            local goalPos = tgt:WorldSpaceCenter() - Vector(0, 0, 40)
            local delta = goalPos - botPos
            local dist = delta:Length()

            if dist > 0.01 then
                local tgtSpd = GetEffectivePlayerVelocity(tgt):Length()
                local flySpeed = math.max(VOID_CONFIG.speed_hyper_noclip_min or 1450, tgtSpd + 380)
                local step = math.min(dist, flySpeed * dt)
                self:SetPos(botPos + (delta / dist) * step)
            end

            if IsValid(self.current_target) and self:IsTargetInMeleeReach(self.current_target) then
                self:ExecuteTarget(self.current_target)
            end
        end
        return
    end

    -- Frenado exacto en barreras psicológicas no letales: Parálisis (90 HU) y AFK (300 HU)
    if curBranch == 3 and self.ParalysisState and self.ParalysisState.phase == "APPROACH" and IsValidTargetPlayer(self.ParalysisState.target) then
        local pPos = self.ParalysisState.target:GetPos()
        if self:GetPos():Distance(pPos) <= (VOID_CONFIG.range_paralysis_stop + 2) then
            self.ParalysisState.phase = "STARE"
            self.ParalysisState.stareEndTime = now + VOID_CONFIG.timer_paralysis_stare
            self:StopMotionAndLookAt(pPos)
            self.loco:SetVelocity(vector_origin)
            self:SetSpatialLoopMode("NONE")
        end
    elseif curBranch == 6 and IsValidTargetPlayer(self.current_target) and self.ActivePath then
        if self.AFKTargetFrontPos then
            if self:GetPos():DistToSqr(self.AFKTargetFrontPos) <= (26 * 26) then
                self:StopMotionAndLookAt(self.current_target:EyePos())
                self.loco:SetVelocity(vector_origin)
            end
        elseif self:GetPos():Distance(self.current_target:GetPos()) <= VOID_CONFIG.range_afk_observe then
            self:StopMotionAndLookAt(self.current_target:EyePos())
            self.loco:SetVelocity(vector_origin)
        end
    end

    -- Persecución terrestre en tiempo real sin paradas en seco (Ramas 2 y 7)
    local chasingActively = (curBranch == 2 or curBranch == 7) and IsValidTargetPlayer(self.current_target)
    if chasingActively then
        local tgt = self.current_target
        local livePos = tgt:GetPos()

        if curBranch == 2 then
            self.loco:SetAcceleration(VOID_CONFIG.acceleration_hyper)
            self.loco:SetDesiredSpeed(VOID_CONFIG.speed_hyper)
        end

        if self:IsTargetInMeleeReach(tgt) then
            self:ExecuteTarget(tgt)
        elseif self:CanDirectRushTarget(livePos) then
            local botPos = self:GetPos()
            local rushDir = livePos - botPos
            rushDir.z = 0
            if rushDir:LengthSqr() > 0.01 then
                rushDir:Normalize()
            else
                rushDir = self:GetForward()
            end
            local overshootGoal = livePos + rushDir * 65 + GetEffectivePlayerVelocity(tgt) * 0.08
            self.loco:FaceTowards(overshootGoal)
            self.loco:Approach(overshootGoal, 1)
            self:HandleNearbyDoorsAndObstacles()
        else
            if (not self.ActivePath)
                or (not self.ActivePath:IsValid())
                or (self.ActiveGoalPos and self.ActiveGoalPos:DistToSqr(livePos) > 1600 and now >= self.NextPathRecompute)
            then
                self:MoveTowardsGoal(livePos, self.loco:GetDesiredSpeed(), true)
            end
            if self.ActivePath and self.ActivePath:IsValid() then
                self.ActivePath:Update(self)
                self:HandleNearbyDoorsAndObstacles()
            else
                self.loco:FaceTowards(livePos)
                self.loco:Approach(livePos, 1)
            end
        end

        if IsValid(self.current_target) and self:IsTargetInMeleeReach(self.current_target) then
            self:ExecuteTarget(self.current_target)
        end
    else
        if self.ActivePath and self.ActivePath:IsValid() then
            self.ActivePath:Update(self)
            self:HandleNearbyDoorsAndObstacles()
        elseif IsValidTargetPlayer(self.current_target) then
            if curBranch == 1 or curBranch == 3 or curBranch == 5 or curBranch == 6 or curBranch == 9 or curBranch == 10 then
                self.loco:FaceTowards(self.current_target:GetPos())
            end
        end
    end
end

function ENT:RunBehaviour()
    while true do
        local now = CurTime()
        local ok, err = xpcall(function()
            self:StepMotorAndBrain(now)
        end, debug.traceback)

        if not ok and now >= (self.NextErrorLogAt or 0) then
            self.NextErrorLogAt = now + 5.0
            ErrorNoHalt("[VØID] Excepción capturada y recuperada en RunBehaviour:\n" .. tostring(err) .. "\n")
        end

        coroutine.yield()
    end
end

-- ============================================================================
-- LIMPIEZA DETERMINISTA DE RECURSOS AL ELIMINAR LA ENTIDAD
-- ============================================================================
function ENT:OnRemove()
    self.TeleportToken = (self.TeleportToken or 0) + 1
    self:AbortParalysis()

    local remainingBots = 0
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) and bot ~= self then
            remainingBots = remainingBots + 1
        end
    end
    if remainingBots == 0 then
        for _, ply in ipairs(player.GetAll()) do
            if IsValid(ply) then
                if ply:GetNWBool("VoidParalyzed", false) then
                    ply:SetNWBool("VoidParalyzed", false)
                end
                local shared = SharedPlayerState[ply]
                if shared then
                    shared.is_panicking = false
                    shared.panic_hold_until = 0
                end
            end
        end
    end

    self:SyncNetworkAudioMode(VOID_AUDIO_NONE)

    net.Start("Void_StopGlobalAudio")
    net.WriteUInt(self:EntIndex(), 16)
    net.WriteBool(true)
    net.Broadcast()
end

-- ============================================================================
-- COMANDOS DE CONSOLA PARA AUDITORÍA Y VALIDACIÓN QA
-- ============================================================================
concommand.Add("void_debug_status", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local bots = ents.FindByClass("npc_void")
    local now = CurTime()
    print(string.format("=== [VØID QA STATUS] Instancias activas: %d ===", #bots))
    for i, bot in ipairs(bots) do
        local bId = bot:GetBehaviorBranch()
        local tgt = IsValid(bot.current_target) and bot.current_target:Nick() or "NINGUNO"
        print(string.format(
            "  #%d [EntIndex=%d] Rama='%s' | IsHyper=%s | Flying=%s | PhantomSprint=%s | Target=%s | Audio=%s | Brain=%.3f ms",
            i,
            bot:EntIndex(),
            BRANCH_NAMES[bId] or tostring(bId),
            tostring(bot:GetIsHyper()),
            tostring(bot:IsFlyingHyperMode()),
            tostring(bot.PhantomSprintActive == true),
            tgt,
            tostring(bot.CurrentSpatialMode),
            bot.LastBrainExecMs or 0
        ))
        for _, p in ipairs(player.GetAll()) do
            if IsValid(p) then
                local st = bot:GetPlayerMemory(p)
                local shared = EnsureSharedPlayerState(p)
                if st and shared then
                    local afkSec = now - (shared.afk_idle_since or now)
                    local noLosSec = now - (st.last_los_contact_at or now)
                    local dz = math.abs(p:GetPos().z - bot:GetPos().z)
                    local sectorCount = shared.sector_nav_areas and #shared.sector_nav_areas or 0
                    print(string.format(
                        "    -> [Player '%s'] phase=%s (obs=%.1f/%.1fs, hide=%.1f/%.1fs, follow=%.1f/10s, respots=%d/%d, noclip=%.1f/10s, afk=%.1f/30s) | dist=%.1f (dZ=%.0f, noLOS=%.1fs, sectorAreas=%d) | mov=%s | patience=%d | LOS=%s | Looking=%s",
                        p:Nick(),
                        tostring(st.stalk_phase),
                        st.observe_accum_time or 0,
                        st.observe_target_duration or 0,
                        st.retreat_unseen_accum or 0,
                        st.retreat_target_wait or 1.5,
                        st.retreat_follow_accum or 0,
                        st.retreat_respot_count or 0,
                        st.retreat_respot_limit or 5,
                        st.noclip_abuse_accum or 0,
                        afkSec,
                        st.distance_to_void,
                        dz,
                        noLosSec,
                        sectorCount,
                        tostring(st.movement_state),
                        st.patience_level,
                        tostring(st.has_los),
                        tostring(st.is_player_looking)
                    ))
                end
            end
        end
    end
end)

concommand.Add("void_force_paralysis_ready", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) then
            bot.paralysis_cooldown_timer = 0
            bot.paralysis_rethink_until = 0
            bot.ForceNextParalysis = true
            print("[VØID QA] Cooldown y decisión de Parálisis forzados listos para EntIndex " .. bot:EntIndex())
        end
    end
end)

concommand.Add("void_force_paranoia", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) then
            bot:EmitParanoiaSound()
            print("[VØID QA] Sonido aleatorio de Paranoia emitido cerca del jugador.")
        end
    end
end)

concommand.Add("void_force_noclip_hyper", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local victim = IsValid(ply) and ply or player.GetAll()[1]
    if not IsValidTargetPlayer(victim) then return end
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) then
            bot:TriggerFlyingNoclipHyper(victim)
            print("[VØID QA] Hiperagresividad Aérea Anti-Noclip activada hacia " .. victim:Nick())
        end
    end
end)

-- ============================================================================
-- SANEAMIENTO EN CALIENTE (Lua AutoRefresh en sesiones activas)
-- ============================================================================
do
    for _, bot in ipairs(ents.FindByClass("npc_void")) do
        if IsValid(bot) then
            bot.PlayerMemories = bot.PlayerMemories or {}
            if not bot:GetIsHyper() then
                for _, ply in ipairs(player.GetAll()) do
                    if IsValid(ply) then
                        local st = bot:GetPlayerMemory(ply)
                        if st and st.patience_level <= 0 then
                            bot:ResetPlayerMemory(ply, true)
                        end
                    end
                end
            end
        end
    end
end
