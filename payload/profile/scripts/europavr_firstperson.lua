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

    -- HANDOVER: the C++ plugin (EuropaVR.dll) now owns everything rotational — the
    -- view rotation, the snap turn, the HMD yaw and the body yaw. This script keeps
    -- the view POSITION and the cosmetics. The two write different fields of
    -- different structs, so callback ordering between them cannot matter.
    -- The forward eye offset moved to the plugin, which is the only side that knows
    -- the final yaw.
    forward_offset  = 0.0,
    up_offset       = 0.0,
    write_view_rotation = false,

    -- Anchor the view to the capsule instead of the animated bone. The bone carries
    -- the walk cycle, and head bob is a reliable way to make people sick in VR. The
    -- bone still sets the eye *height*, but heavily filtered, so crouching still
    -- reads while the ~5 Hz bob does not.
    stabilize        = true,
    height_smoothing = 3.0,

    -- Turn the character to face where the player is looking, so walking direction
    -- follows the head.
    turn_with_head  = false, -- taken over by the C++ plugin

    -- ALS_RotationMode: 0 = VelocityDirection (the character turns to face wherever
    -- it is moving, which is why pushing back made it turn around), 1 = LookingDirection
    -- (it faces the control rotation and strafes/backpedals instead), 2 = Aiming.
    rotation_mode   = 1,

    -- Stamp the actor yaw directly after the game's tick. This is the bypass: it wins
    -- over ALS's own rotation logic instead of negotiating with it.
    force_actor_yaw = false, -- taken over by the C++ plugin

    -- Let UEVR own the yaw. Its Aim Method drives the game's control rotation from
    -- the headset, and its snap turn applies a world rotation offset that the same
    -- system sees. Hand-rolling this meant reimplementing it without access to the
    -- HMD yaw, which is why the body never followed the head: the rotation read back
    -- from the stereo callback does not contain the headset at all.
    -- REVERTED: turning this on locked the view to the game camera and killed head
    -- tracking outright. UEVR's aim system and our own view override fight over the
    -- same rotation, and the result is nauseating. Left here, off, so the mechanism
    -- is documented rather than silently deleted.
    use_uevr_aim    = false,

    snap_turn           = false, -- taken over by the C++ plugin
    snap_angle          = 45.0,
    snap_threshold      = 0.5, -- fraction of stick travel that triggers a snap
    snap_release        = 0.3, -- must fall back below this before the next snap
    snap_cooldown       = 18,  -- frames to wait before another snap can fire
    consume_right_stick = true, -- keep the game from also applying TurnRate/LookUpRate

    hide_head     = true,
    collapse_boom = true,
}

local state = {
    pawn        = nil,
    mesh        = nil,
    boom        = nil,
    head_hidden = false,
    gameplay    = false,

    eye_height  = nil,  -- filtered head-above-capsule offset
    snap_yaw    = 0.0,  -- accumulated snap turn, degrees
    snap_armed  = true,
    snap_wait   = 0,    -- cooldown frames left
    view_yaw    = nil,  -- final yaw incl. HMD, sampled post-transform
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

--- Formats whatever fields an engine value happens to expose, for diagnostics.
local function describe(o)
    if o == nil then
        return "nil"
    end
    local fields = {}
    for _, k in ipairs({"w", "x", "y", "z", "W", "X", "Y", "Z", "Pitch", "Yaw", "Roll"}) do
        local v = try(function() return o[k] end)
        if type(v) == "number" then
            fields[#fields + 1] = k .. "=" .. ("%.3f"):format(v)
        end
    end
    if #fields == 0 then
        return "opaque(" .. type(o) .. ")"
    end
    return table.concat(fields, ",")
end

--- REMOVED. This probe called native VR bindings with argument lists that were never
--- verified: get_pose takes out-parameters, so invoking it with a bare index made the
--- native side write through null pointers and took the process down. pcall does not
--- catch a native access violation, so "read-only Lua" was never a safety guarantee.
--- Any future probing of this API has to start from its real signatures.
local function probe_hmd()
    d.hmd = "disabled"
end

local function player_controller()
    return try(function() return api:get_player_controller(0) end)
end

--- The control rotation is the one place the final yaw is readable from the game side
--- once UEVR's aim system is driving it.
local function control_yaw()
    local pc = player_controller()
    if pc == nil then
        return nil
    end

    local rot = try(function() return pc.ControlRotation end)
    local y = rot ~= nil and try(function() return rot.Yaw end) or nil
    if y ~= nil then
        d.ctrl_yaw = "ControlRotation"
        return y
    end

    rot = try(function() return pc:GetControlRotation() end)
    y = rot ~= nil and try(function() return rot.Yaw end) or nil
    if y ~= nil then
        d.ctrl_yaw = "GetControlRotation"
        return y
    end

    d.ctrl_yaw = "NONE"
    return nil
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

local function set_head_hidden(hidden)
    if state.mesh == nil or state.head_hidden == hidden then
        return
    end
    local ok
    if hidden then
        ok = try(function() state.mesh:HideBoneByName(config.bone, 0) return true end)
    else
        ok = try(function() state.mesh:UnHideBoneByName(config.bone) return true end)
    end
    d.hide_bone = ok and "ok" or "NONE"
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

local function apply_control_rotation()
    if not config.turn_with_head or state.view_yaw == nil then
        return
    end

    local pc = player_controller()
    if pc == nil then
        return
    end

    -- Pitch stays flat: leaning the character back because the player looked up is
    -- exactly the kind of thing that breaks VR comfort.
    local ok = try(function()
        pc:SetControlRotation({Pitch = 0.0, Yaw = state.view_yaw, Roll = 0.0})
        return true
    end)
    d.control_rot = ok and "ok" or "NONE"
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

--- Last resort, and the reason this runs post-tick: ALS drives the character's
--- rotation from its own Blueprint logic every frame, so anything we set before the
--- game ticks is simply overwritten. Stamping the yaw after the tick is what makes it
--- stick, whatever the state machine wanted.
local function force_actor_yaw()
    if not config.force_actor_yaw or state.view_yaw == nil or state.pawn == nil then
        return
    end

    local ok = try(function()
        state.pawn:K2_SetActorRotation({Pitch = 0.0, Yaw = state.view_yaw, Roll = 0.0}, false)
        return true
    end)
    d.actor_yaw = ok and "ok" or "NONE"
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
        "snap_yaw=" .. ("%.0f"):format(state.snap_yaw),
        "snaps=" .. tostring(d.snaps or 0),
        "xinput=" .. d.xinput,
        "rot_mode=" .. tostring(d.rot_mode),
        "move_flags=" .. tostring(d.move_flags),
        "actor_yaw=" .. tostring(d.actor_yaw),
        "ctrl_yaw_src=" .. tostring(d.ctrl_yaw),
        "final_yaw=" .. (state.final_yaw and ("%.0f"):format(state.final_yaw) or "nil"),
        "control_rot=" .. d.control_rot,
        "HMD[" .. tostring(d.hmd) .. "]",
        "readback=" .. d.readback,
        "hide_bone=" .. d.hide_bone,
        "boom_write=" .. d.boom_write,
    }, " ~ ")
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    d.ticks = d.ticks + 1

    if state.snap_wait > 0 then
        state.snap_wait = state.snap_wait - 1
    end

    refresh_pawn()
    state.gameplay = compute_gameplay()
    probe_hmd()

    if state.gameplay then
        if config.collapse_boom then
            collapse_boom()
        end
        if config.stabilize then
            update_eye_height(delta)
        end
    end

    if config.hide_head then
        set_head_hidden(state.gameplay)
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
        return
    end

    apply_character_orientation()

    if config.use_uevr_aim then
        -- UEVR sets the control rotation itself; we only read it back, for the eye
        -- offset and for diagnostics.
        state.final_yaw = control_yaw()
    else
        apply_control_rotation()
        force_actor_yaw()
        state.final_yaw = state.view_yaw
    end
end)

--- Snap turn, driven straight off the raw pad so the game never sees the stick.
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, xstate)
    if not config.snap_turn then
        return
    end

    local pad = try(function() return xstate.Gamepad end)
    if pad == nil then
        d.xinput = "NO Gamepad"
        return
    end

    -- XInput is polled for every pad index and several times per frame. Evaluating
    -- the stick on all of them was the bug behind the runaway snapping: the empty
    -- pads read as centred and re-armed the trigger between two real samples.
    if user_index == 0 then
        local rx = try(function() return pad.sThumbRX end)
        if rx == nil then
            d.xinput = "NO sThumbRX"
            return
        end
        d.xinput = "ok"

        local axis = rx / 32767.0
        if math.abs(axis) < config.snap_release then
            state.snap_armed = true
        elseif state.snap_armed and state.snap_wait <= 0 and math.abs(axis) >= config.snap_threshold then
            local step = axis > 0 and config.snap_angle or -config.snap_angle
            state.snap_yaw = (state.snap_yaw + step) % 360.0
            state.snap_armed = false
            state.snap_wait = config.snap_cooldown
            d.snaps = (d.snaps or 0) + 1
        end
    end

    if config.consume_right_stick then
        try(function()
            pad.sThumbRX = 0
            pad.sThumbRY = 0
            return true
        end)
    end
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

    -- The whole point: discard the game's camera orientation outright. Keeping it as
    -- a base meant BP_LakituCam decided where "forward" was and the headset merely
    -- added to it, so the player's gaze never chose the direction. With a constant
    -- base, UEVR's HMD rotation lands on top of nothing but our snap offset, and the
    -- view becomes purely head driven.
    if config.write_view_rotation then
        local base_yaw = config.use_uevr_aim and 0.0 or state.snap_yaw
        if not set_xyz(rotation, 0.0, base_yaw, 0.0) then
            d.readback = "ROT WRITE FAILED"
        end
    end

    if config.forward_offset ~= 0.0 then
        local r = math.rad(state.final_yaw or 0.0)
        x = x + math.cos(r) * config.forward_offset
        y = y + math.sin(r) * config.forward_offset
    end
    z = z + config.up_offset

    if set_xyz(position, x, y, z) then
        d.readback = ("z=%.1f yaw=%.0f"):format(z, state.view_yaw or state.snap_yaw)
    else
        d.readback = "POS WRITE FAILED"
    end
end)

--- After UEVR's transforms the rotation carries the HMD, which is the yaw we want the
--- character to face.
uevr.sdk.callbacks.on_post_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    if state.gameplay then
        state.view_yaw = try(function() return rotation.y end)
    end
end)

uevr.sdk.callbacks.on_script_reset(function()
    set_head_hidden(false)
    state.pawn, state.mesh, state.boom = nil, nil, nil
end)
