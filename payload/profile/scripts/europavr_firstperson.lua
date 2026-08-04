--- EuropaVR - first person VR for Europa (UE4.27, ALS V4 mannequin skeleton).
---
--- Europa never frames the pawn: gameplay is shot through a dedicated camera actor,
--- BP_LakituCam, which recomputes its transform every frame from a dozen curves.
--- Fighting that is pointless, so we do not: the game's shot is discarded wholesale in
--- the stereo view callback, which runs after the game is done and before UEVR applies
--- its VR transforms. Seeing BP_LakituCam as the view target is also what tells us the
--- player is in control; a cutscene swaps in another camera and we hand the shot back.
---
--- Nothing the engine exposes is assumed: every call is guarded, because this sandbox
--- has no io library and a stubbed os, so a silent failure is invisible otherwise.

local api = uevr.api

local config = {
    bone            = "head",
    gameplay_camera = "BP_LakituCam",

    -- HANDOVER: the C++ plugin (EuropaVR.dll) owns everything rotational - view
    -- rotation, snap turn, HMD yaw, body yaw, and the forward eye offset, which needs
    -- the headset yaw this side cannot see. What is left here is the view POSITION and
    -- the cosmetics. The two write different fields of different structs, so callback
    -- ordering between them cannot matter.

    -- Anchor the view to the capsule instead of the animated bone. The bone carries
    -- the walk cycle, and head bob is a reliable way to make people sick in VR. The
    -- bone still sets the eye *height*, but heavily filtered, so crouching still
    -- reads while the ~5 Hz bob does not.
    stabilize        = true,
    height_smoothing = 3.0,

    -- ALS_RotationMode: 1 = LookingDirection, so the character strafes and backpedals
    -- rather than pivoting to face its velocity. The plugin also sets this; kept here
    -- because this script still owns what the body looks like.
    rotation_mode   = 1,

    hide_head     = true,
    -- "bone" | "mesh" | "none" — see set_head_hidden for the trade-off each carries.
    -- "mesh" is the default: from a viewpoint inside the head, a visible body reads
    -- worse than no body at all, while a headless shadow is noticed constantly.
    hide_mode     = "mesh",
    collapse_boom = true,
}

local state = {
    pawn        = nil,
    mesh        = nil,
    boom        = nil,
    head_hidden = false,
    gameplay    = false,

    eye_height  = nil,  -- filtered head-above-capsule offset
    hide_list   = nil,  -- cached skeletal mesh components, rebuilt when the pawn changes
}

local d = {
    ticks       = 0,
    pawn_class  = "-",
    socket      = "-",
    actor_loc   = "-",
    view_target = "-",
    xinput      = "-",
    control_rot = "-",
    readback    = "-",
    hide_bone   = "-",
    boom_write  = "-",
}

local emit = { count = 0, max = 10, last = "", next_beat = 1 }


local function try(fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then
        return res
    end
    return nil
end

local function object_name(o)
    if o == nil then
        return "nil"
    end
    return try(function() return o:get_full_name() end) or "<unnamed>"
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- UE structs use X/Y/Z, UEVR's own vector userdata uses lowercase. Accept either.
local function xyz(v)
    if v == nil then
        return nil
    end
    local x, y, z = try(function() return v.X end), try(function() return v.Y end), try(function() return v.Z end)
    if x ~= nil and y ~= nil and z ~= nil then
        return x, y, z, "upper"
    end
    x, y, z = try(function() return v.x end), try(function() return v.y end), try(function() return v.z end)
    if x ~= nil and y ~= nil and z ~= nil then
        return x, y, z, "lower"
    end
    return nil
end

local function set_xyz(v, x, y, z)
    return try(function()
        local _, _, _, casing = xyz(v)
        if casing == "upper" then
            v.X, v.Y, v.Z = x, y, z
        else
            v.x, v.y, v.z = x, y, z
        end
        return true
    end)
end

local function same_object(a, b)
    if a == nil or b == nil then
        return false
    end
    if rawequal(a, b) then
        return true
    end
    local na, nb = try(function() return a:get_full_name() end), try(function() return b:get_full_name() end)
    if na ~= nil and nb ~= nil then
        return na == nb
    end
    return a == b
end

local function head_location()
    local mesh = state.mesh
    if mesh == nil then
        return nil
    end

    local loc = try(function() return mesh:GetSocketLocation(config.bone) end)
    local x, y, z = xyz(loc)
    if x ~= nil then
        d.socket = "GetSocketLocation"
        return x, y, z
    end

    loc = try(function() return mesh:GetBoneLocation(config.bone, 0) end)
    x, y, z = xyz(loc)
    if x ~= nil then
        d.socket = "GetBoneLocation"
        return x, y, z
    end

    d.socket = "NONE"
    return nil
end

--- The capsule location: unlike the head bone it carries no animation, so it is the
--- stable anchor we want the view riding on.
local function actor_location()
    local pawn = state.pawn
    if pawn == nil then
        return nil
    end

    local loc = try(function() return pawn:K2_GetActorLocation() end)
    local x, y, z = xyz(loc)
    if x ~= nil then
        d.actor_loc = "K2_GetActorLocation"
        return x, y, z
    end

    local root = try(function() return pawn.RootComponent end)
    if root ~= nil then
        loc = try(function() return root:K2_GetComponentLocation() end)
        x, y, z = xyz(loc)
        if x ~= nil then
            d.actor_loc = "RootComponent"
            return x, y, z
        end
    end

    d.actor_loc = "NONE"
    return nil
end



local function player_controller()
    return try(function() return api:get_player_controller(0) end)
end


local function current_view_target()
    local pc = player_controller()
    if pc == nil then
        return nil
    end
    local pcm = try(function() return pc.PlayerCameraManager end)
    if pcm == nil then
        return nil
    end
    local vt = try(function() return pcm.ViewTarget end)
    if vt == nil then
        return nil
    end
    return try(function() return vt.Target end)
end

local function compute_gameplay()
    if state.pawn == nil or state.mesh == nil then
        d.view_target = "no pawn/mesh"
        return false
    end

    local target = current_view_target()
    if target == nil then
        d.view_target = "UNAVAILABLE -> assume gameplay"
        return true
    end

    local class_name = object_name(try(function() return target:get_class() end))
    d.view_target = class_name
    return class_name:find(config.gameplay_camera, 1, true) ~= nil
end

--- Last path segment of a UObject name, so the log stays readable.
local function short_name(o)
    local full = object_name(o)
    return full:match("([^%.]+)$") or full
end

--- Every skeletal mesh the pawn owns. pawn.Mesh returns CharacterMesh0, but BP_Zee
--- also carries a MeshHolder and a SkeletalMesh, and there was no evidence the visible
--- character was the one being addressed. Enumerating settles it instead of guessing.
local function hide_targets()
    if state.hide_list ~= nil then
        return state.hide_list
    end

    local list = {}
    local pawn = state.pawn
    if pawn == nil then
        return list
    end

    local cls = try(function()
        return api:find_uobject("Class /Script/Engine.SkeletalMeshComponent")
    end)
    local found = cls ~= nil and try(function() return pawn:K2_GetComponentsByClass(cls) end) or nil

    if found ~= nil then
        for i in ipairs(found) do
            local c = try(function() return found[i] end)
            if c ~= nil then
                list[#list + 1] = c
            end
        end
    end

    if #list == 0 then
        for _, name in ipairs({"Mesh", "SkeletalMesh", "MeshHolder"}) do
            local c = try(function() return pawn[name] end)
            if c ~= nil then
                list[#list + 1] = c
            end
        end
    end

    local names = {}
    for _, c in ipairs(list) do
        names[#names + 1] = short_name(c)
    end
    d.components = ("%d{%s}"):format(#list, table.concat(names, ","))

    state.hide_list = list
    return list
end

--- Hiding the head is a compromise, because UE4 visibility is per primitive, never per
--- bone. HideBoneByName collapses the bone in the skinning itself, so every pass sees
--- the change alike — the shadow loses its head along with the view. There is no way to
--- drop one bone from the base pass only.
---
---   "bone" : head hidden, body still visible, shadow is headless
---   "mesh" : whole mesh hidden from every view, but bCastHiddenShadow keeps it casting
---            a complete and correct shadow. Nothing of the body is visible.
---   "none" : leave the mesh alone
local function set_head_hidden(hidden)
    if state.mesh == nil or config.hide_mode == "none" then
        return
    end

    local mesh = state.mesh
    local ok

    if config.hide_mode == "mesh" then
        -- Re-applied every frame, never latched: the calls reported success yet the
        -- body stayed on screen, which is the same thing that happened with the
        -- character rotation — the game reasserts its own state on its tick, so this
        -- has to run after it and keep running.
        --
        -- Several levers are tried because they fail differently. SetRenderInMainPass
        -- is the one that matches the intent exactly: the primitive keeps feeding the
        -- shadow depth pass while dropping out of the main pass.
        local worked = {}
        for _, component in ipairs(hide_targets()) do
            if try(function() component:SetCastHiddenShadow(true) return true end) then
                worked.shadow = true
            end
            if try(function() component:SetRenderInMainPass(not hidden) return true end) then
                worked.mainpass = true
            end
            if try(function() component:SetVisibility(not hidden, true) return true end) then
                worked.visibility = true
            end
            if try(function() component:SetOwnerNoSee(hidden) return true end) then
                worked.ownernosee = true
            end
            if try(function() component:SetHiddenInGame(hidden, true) return true end) then
                worked.hiddeningame = true
            end
        end

        local levers = {}
        for _, k in ipairs({"mainpass", "visibility", "ownernosee", "hiddeningame", "shadow"}) do
            levers[#levers + 1] = k .. "=" .. (worked[k] and "1" or "0")
        end
        d.hide_bone = "mesh[" .. table.concat(levers, ",") .. "]"

        state.head_hidden = hidden
        return
    end

    if state.head_hidden == hidden then
        return
    end

    do
        if hidden then
            ok = try(function() mesh:HideBoneByName(config.bone, 0) return true end)
        else
            ok = try(function() mesh:UnHideBoneByName(config.bone) return true end)
        end
    end

    d.hide_bone = ok and (config.hide_mode .. ":ok") or (config.hide_mode .. ":NONE")
    if ok then
        state.head_hidden = hidden
    end
end

local function collapse_boom()
    if state.boom == nil then
        return
    end
    local ok = try(function()
        state.boom.TargetArmLength = 0.0
        state.boom.bEnableCameraLag = false
        state.boom.bEnableCameraRotationLag = false
        return true
    end)
    d.boom_write = ok and "ok" or "NONE"
end

--- Keeps the eye at a filtered height above the capsule. Returns nil until it has
--- something to work with.
local function update_eye_height(delta)
    local _, _, az = actor_location()
    local _, _, hz = head_location()
    if az == nil or hz == nil then
        return
    end

    local target = hz - az
    if state.eye_height == nil then
        state.eye_height = target
        return
    end

    local alpha = clamp((delta or 0.016) * config.height_smoothing, 0.0, 1.0)
    state.eye_height = state.eye_height + (target - state.eye_height) * alpha
end


--- Makes the body behave like an FPS: face the control rotation, and strafe or walk
--- backwards rather than pivoting to face the direction of travel.
local function apply_character_orientation()
    local pawn = state.pawn
    if pawn == nil then
        return
    end

    if config.rotation_mode ~= nil then
        local how = nil
        if try(function() pawn.RotationMode = config.rotation_mode return true end) then
            how = "property"
        elseif try(function() pawn:set_property("RotationMode", config.rotation_mode) return true end) then
            how = "set_property"
        elseif try(function() pawn:BPI_Set_RotationMode(config.rotation_mode) return true end) then
            how = "BPI"
        end
        d.rot_mode = how or "NONE"
    end

    -- Native pawn flag: makes the engine itself keep the pawn yaw on the control
    -- rotation, independently of whatever the Blueprint decides.
    try(function() pawn.bUseControllerRotationYaw = true return true end)

    local cmc = try(function() return pawn.CharacterMovement end)
    if cmc ~= nil then
        local ok = try(function()
            cmc.bOrientRotationToMovement = false
            cmc.bUseControllerDesiredRotation = true
            return true
        end)
        d.move_flags = ok and "ok" or "NONE"
    else
        d.move_flags = "no CMC"
    end
end


local function refresh_pawn()
    local pawn = try(function() return api:get_local_pawn(0) end)

    if pawn == nil then
        state.pawn, state.mesh, state.boom = nil, nil, nil
        state.head_hidden = false
        state.eye_height = nil
        d.pawn_class = "no pawn"
        return
    end

    if same_object(pawn, state.pawn) then
        return
    end

    state.pawn = pawn
    state.hide_list = nil
    state.mesh = try(function() return pawn.Mesh end)
    state.boom = try(function() return pawn.CameraBoom end)
    state.head_hidden = false
    state.eye_height = nil
    d.pawn_class = object_name(try(function() return pawn:get_class() end))
end

local function report()
    return table.concat({
        "### EuropaVR DIAG ###",
        "ticks=" .. d.ticks,
        "pawn=" .. d.pawn_class,
        "gameplay=" .. tostring(state.gameplay),
        "view_target=" .. d.view_target,
        "socket=" .. d.socket,
        "actor_loc=" .. d.actor_loc,
        "eye_height=" .. (state.eye_height and ("%.1f"):format(state.eye_height) or "nil"),
        "rot_mode=" .. tostring(d.rot_mode),
        "move_flags=" .. tostring(d.move_flags),
        "readback=" .. d.readback,
        "hide_bone=" .. d.hide_bone,
        "components=" .. tostring(d.components),
        "boom_write=" .. d.boom_write,
    }, " ~ ")
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    d.ticks = d.ticks + 1

    refresh_pawn()
    state.gameplay = compute_gameplay()

    if state.gameplay then
        if config.collapse_boom then
            collapse_boom()
        end
        if config.stabilize then
            update_eye_height(delta)
        end
    end

    if emit.count < emit.max then
        local sig = table.concat({d.pawn_class, tostring(state.gameplay), d.actor_loc,
                                  d.xinput, d.control_rot, d.readback}, "|")
        if sig ~= emit.last or d.ticks >= emit.next_beat then
            emit.last = sig
            emit.next_beat = d.ticks + 3600
            emit.count = emit.count + 1
            error(report())
        end
    end
end)

--- Everything that decides where the body faces runs here, after the game has ticked.
--- Applying it before the tick meant ALS overwrote all of it every single frame, which
--- is why the character ignored both the headset and the snap turn.
uevr.sdk.callbacks.on_post_engine_tick(function()
    if not state.gameplay then
        if config.hide_head then
            set_head_hidden(false) -- give the body back for cutscenes
        end
        return
    end

    -- After the game's tick, so its own visibility handling has already run.
    if config.hide_head then
        set_head_hidden(true)
    end

    apply_character_orientation()
end)

uevr.sdk.callbacks.on_pre_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not state.gameplay then
        d.readback = "skipped: not gameplay"
        return
    end

    local hx, hy, hz = head_location()
    if hx == nil then
        d.readback = "skipped: no head location"
        return
    end

    local x, y, z = hx, hy, hz
    if config.stabilize then
        local ax, ay, az = actor_location()
        if ax ~= nil and state.eye_height ~= nil then
            x, y, z = ax, ay, az + state.eye_height
        end
    end

    -- Position only. The plugin owns the view rotation and the forward eye offset,
    -- because it is the only side that knows the headset yaw.
    if set_xyz(position, x, y, z) then
        d.readback = ("z=%.1f"):format(z)
    else
        d.readback = "POS WRITE FAILED"
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    set_head_hidden(false)
    state.pawn, state.mesh, state.boom = nil, nil, nil
end)
