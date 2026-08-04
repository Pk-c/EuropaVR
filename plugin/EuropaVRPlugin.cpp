// EuropaVR - UEVR C++ plugin.
//
// Owns everything rotational. The Lua script could not: the rotation handed to the
// stereo callback never contains the headset, K2_SetActorRotation is not exposed to
// script, and delegating to UEVR's own aim system fights our view override and kills
// head tracking. From C++ the HMD pose is directly readable, so the world yaw can be
// derived rather than guessed.
//
// Split with the Lua script, which still runs:
//   Lua  -> view POSITION (capsule anchor, filtered eye height), head hiding, boom
//   C++  -> view ROTATION, snap turn, HMD yaw, body yaw, forward eye offset
// They write different fields of different structs, so callback ordering cannot make
// them collide.
//
// Two independent ways of measuring the head yaw are computed and logged, because the
// mapping between OpenXR space and UE world space is a convention that must be
// measured, not assumed:
//   quat     - yaw extracted from the HMD pose quaternion
//   eyedelta - from the vector between the two eye positions UEVR itself produced,
//              which is already in world space and therefore convention-free
//
// Every engine property goes through get_property_data + a null check: API.hpp warns
// that get_property dereferences blindly.

#include <uevr/Plugin.hpp>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using API = uevr::API;

namespace {

constexpr float kPi = 3.14159265358979323846f;
constexpr float kRadToDeg = 180.0f / kPi;
constexpr float kDegToRad = kPi / 180.0f;

float normalize_deg(float deg) {
    while (deg > 180.0f) {
        deg -= 360.0f;
    }
    while (deg < -180.0f) {
        deg += 360.0f;
    }
    return deg;
}

struct Config {
    // 0 = quaternion, 1 = eye delta. Measured in game: the quaternion tracks the head
    // faithfully, while the eye delta stays at zero — UEVR evidently does not apply
    // the per-eye separation to the position handed to this callback. Quaternion it is.
    int   yaw_method     = 0;
    // OpenXR is right-handed with +Y up; UE is left-handed with +Z up, so a head turn
    // maps to the opposite sign of yaw.
    float yaw_sign       = -1.0f;
    float yaw_offset     = 0.0f;
    bool  apply_body_yaw = true;
    bool  write_view_rot = true;
    // Pushes the eye out of the skull. Both are hot-reloaded from the ini.
    float forward_offset = 12.0f;
    float up_offset      = 0.0f;

    // 0 = snap, 1 = smooth. Snap is the default: it is the comfortable choice for most
    // people, and smooth turning is the classic way to make someone sick in VR.
    int   turn_mode      = 0;
    float smooth_speed   = 90.0f; // degrees per second at full stick
    float turn_deadzone  = 0.2f;

    bool  snap_turn      = true;
    float snap_angle     = 45.0f;
    float snap_threshold = 0.5f;
    float snap_release   = 0.3f;
    // Seconds, not frames. A frame count turns into a much longer wait the moment the
    // framerate drops, which is exactly when snap turning already feels worst.
    float snap_cooldown  = 0.3f;

    // The game binds Pause to Gamepad_Special_Right, which is XInput START, and nothing
    // on a Touch controller reaches it. Since we already rewrite the XInput state, we
    // can press START ourselves when a VR button is held.
    // 0 = off, 1 = left menu button, 2 = left stick click, 3 = right stick click.
    // Defaults to the right stick click: the menu button resolves but SteamVR keeps it
    // for its own dashboard, so a press never reaches the game.
    int   pause_button   = 3;

    // The in-game book places itself with a DistanceInfrontOfCamera Blueprint variable,
    // tuned for a third person camera sitting well behind the character. With the eye at
    // the character's head that same distance lands the book on your nose.
    // 0 keeps whatever the game chose. 300 was picked in the headset; the game's own
    // value is 145, which lands the book on your face from a first person viewpoint.
    float book_distance  = 300.0f;
    // Watches every VR button and logs the ones a press actually reaches. The map is
    // already known (A buttons and both stick clicks); this stays off because it costs
    // twelve VR queries a frame, which is not free.
    bool  action_probe   = false;

    int   log_every      = 240;    // frames between diagnostic lines
};

} // namespace

class EuropaVR final : public uevr::Plugin {
public:
    void on_initialize() override {
        load_config();
        API::get()->log_info(
            "[EuropaVR] plugin up | yaw_method=%d yaw_sign=%.0f yaw_offset=%.1f "
            "apply_body_yaw=%d write_view_rot=%d forward=%.1f snap=%d/%.0fdeg",
            m_config.yaw_method, m_config.yaw_sign, m_config.yaw_offset,
            (int)m_config.apply_body_yaw, (int)m_config.write_view_rot,
            m_config.forward_offset, (int)m_config.snap_turn, m_config.snap_angle);
    }

    void on_pre_engine_tick(API::UGameEngine*, float delta) override {
        if (m_snap_wait > 0.0f) {
            m_snap_wait -= delta;
        }

        if (m_config.turn_mode == 1 && m_gameplay.load()) {
            const float axis = m_turn_axis.load();
            if (axis != 0.0f) {
                m_snap_yaw.store(
                    normalize_deg(m_snap_yaw.load() + axis * m_config.smooth_speed * delta));
            }
        }

        // Re-read the ini roughly once a second so the camera can be dialled in
        // without restarting the game.
        if (++m_config_age >= 60) {
            m_config_age = 0;
            reload_config_if_changed();
        }

        m_gameplay.store(compute_gameplay());
    }

    void on_post_engine_tick(API::UGameEngine*, float) override {
        if (!m_gameplay.load()) {
            return;
        }

        update_final_yaw();
        apply_body_orientation();
        if (m_config.action_probe) {
            sample_actions();
        }
        handle_books();

        if (++m_frames >= m_config.log_every) {
            m_frames = 0;
            log_state();
        }
    }

    void on_xinput_get_state(uint32_t*, uint32_t user_index, XINPUT_STATE* state) override {
        if (state == nullptr) {
            return;
        }

        // Only pad 0 drives turning. Evaluating every index was what made the Lua
        // version spin: the empty pads read as centred and re-armed the trigger
        // between two real samples.
        if (m_config.snap_turn && user_index == 0 && m_gameplay.load()) {
            const float axis = state->Gamepad.sThumbRX / 32767.0f;
            const float mag = std::fabs(axis);

            if (m_config.turn_mode == 1) {
                // Smooth turning is integrated on the game thread, which is the only
                // place with a delta time. XInput is polled several times per frame, so
                // integrating here would turn faster the more often the game asks.
                m_turn_axis.store(mag < m_config.turn_deadzone ? 0.0f : axis);
            } else if (mag < m_config.snap_release) {
                m_snap_armed = true;
            } else if (m_snap_armed && m_snap_wait <= 0.0f && mag >= m_config.snap_threshold) {
                const float step = axis > 0.0f ? m_config.snap_angle : -m_config.snap_angle;
                m_snap_yaw.store(normalize_deg(m_snap_yaw.load() + step));
                m_snap_armed = false;
                m_snap_wait = m_config.snap_cooldown;
                ++m_snap_count;
            }
        }

        // The game must never see the right stick, or its own TurnRate fights us.
        if (m_config.snap_turn) {
            state->Gamepad.sThumbRX = 0;
            state->Gamepad.sThumbRY = 0;
        }

        if (user_index == 0 && pause_button_held()) {
            state->Gamepad.wButtons |= XINPUT_GAMEPAD_START;
        }
    }

    void on_pre_calculate_stereo_view_offset(UEVR_StereoRenderingDeviceHandle, int, float,
                                             UEVR_Vector3f*, UEVR_Rotatorf* rotation,
                                             bool) override {
        if (rotation == nullptr || !m_config.write_view_rot || !m_gameplay.load()) {
            return;
        }

        // Discard the game's camera orientation. BP_LakituCam decides it every frame,
        // and keeping it as a base meant the headset only ever added to whatever the
        // game had chosen. UEVR lays the HMD rotation on top of this.
        rotation->pitch = 0.0f;
        rotation->yaw = m_snap_yaw.load();
        rotation->roll = 0.0f;
    }

    void on_post_calculate_stereo_view_offset(UEVR_StereoRenderingDeviceHandle, int view_index,
                                              float, UEVR_Vector3f* position, UEVR_Rotatorf*,
                                              bool) override {
        if (position == nullptr) {
            return;
        }

        // Sample both eyes: the vector between them is the head's right axis, already
        // in world space, which yields a yaw with no convention to guess at.
        if (view_index == 0) {
            m_left_eye = *position;
            m_have_left = true;
        } else if (view_index == 1 && m_have_left) {
            const float dx = position->x - m_left_eye.x;
            const float dy = position->y - m_left_eye.y;
            if (std::fabs(dx) > 1e-4f || std::fabs(dy) > 1e-4f) {
                // Forward is the right axis turned back by 90 degrees.
                m_eye_yaw.store(normalize_deg(std::atan2(dy, dx) * kRadToDeg - 90.0f));
            }
        }

        if (m_gameplay.load()) {
            const float r = m_final_yaw.load() * kDegToRad;
            position->x += std::cos(r) * m_config.forward_offset;
            position->y += std::sin(r) * m_config.forward_offset;
            position->z += m_config.up_offset;
        }
    }

private:
    static std::string narrow(const std::wstring& w) {
        if (w.empty()) {
            return {};
        }
        const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
        std::string out(n > 0 ? n - 1 : 0, '\0');
        if (n > 0) {
            WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, out.data(), n, nullptr, nullptr);
        }
        return out;
    }

    static API::UObject* deref_object(API::UObject* owner, const wchar_t* name) {
        if (owner == nullptr) {
            return nullptr;
        }
        auto** slot = owner->get_property_data<API::UObject*>(name);
        return slot != nullptr ? *slot : nullptr;
    }

    // Europa never frames the pawn: gameplay runs through BP_LakituCam. A cutscene
    // swaps in another camera, which is our cue to leave the shot alone.
    bool compute_gameplay() {
        auto* pc = API::get()->get_player_controller(0);
        if (pc == nullptr) {
            return false;
        }

        auto* pcm = deref_object(pc, L"PlayerCameraManager");
        if (pcm == nullptr) {
            return false;
        }

        // FTViewTarget begins with AActor* Target.
        auto* view_target = pcm->get_property_data<API::UObject*>(L"ViewTarget");
        auto* target = view_target != nullptr ? *view_target : nullptr;
        if (target == nullptr) {
            return false;
        }

        // Comparing class pointers rather than names. get_full_name walks the outer
        // chain and builds a string, which was happening every single frame just to
        // look for a substring; now it happens only when the view target actually
        // changes class, which is a handful of times in a session.
        auto* klass = target->get_class();
        if (klass != m_view_class) {
            m_view_class = klass;
            m_view_target_name = klass != nullptr ? klass->get_full_name() : L"";
            m_view_is_gameplay = m_view_target_name.find(L"LakituCam") != std::wstring::npos;
        }
        return m_view_is_gameplay;
    }

    // True while the chosen VR button is held. Action paths come from UEVR's own
    // manifest; the handle is resolved once, since a bad path would otherwise be
    // retried on every poll and stay invisible.
    bool pause_button_held() {
        if (m_config.pause_button == 0) {
            return false;
        }

        const auto* vr = API::get()->param()->vr;
        if (vr == nullptr) {
            return false;
        }

        // Stick click is the fallback rather than a grip: grips are held constantly
        // while playing, so pausing would fire by accident. The game does map L3/R3 to
        // its camera zoom, which is meaningless once we own the camera.
        const char* path = nullptr;
        bool left = true;
        switch (m_config.pause_button) {
        case 1: path = "/actions/default/in/SystemButton";   left = true;  break;
        case 2: path = "/actions/default/in/JoystickClick";  left = true;  break;
        case 3: path = "/actions/default/in/JoystickClick";  left = false; break;
        default: return false;
        }

        if (!m_pause_resolved) {
            m_pause_resolved = true;
            m_pause_action = vr->get_action_handle(path);
            m_pause_ok = m_pause_action != nullptr;

            // get_action_handle is case sensitive, and the lowercase spellings in
            // UEVR's binary come from its OpenVR json manifest rather than from the API.
            // Measured in game: systembutton returns null, SystemButton resolves.
            // The sweep stays as a diagnostic for anyone porting this to another build.
            if (!m_pause_ok) {
                for (const char* candidate : {
                         "/actions/default/in/systembutton", "/actions/default/in/SystemButton",
                         "/actions/default/in/joystickclick", "/actions/default/in/JoystickClick",
                         "/actions/default/in/Grip", "/actions/default/in/squeeze",
                         "/actions/default/in/trigger", "/actions/default/in/abuttonleft",
                         "/actions/default/in/BButtonLeft", "/actions/default/in/DPad_Up",
                         "/actions/default/in/Teleport", "/actions/default/in/joystick"}) {
                    API::get()->log_info("[EuropaVR] action %s -> %s", candidate,
                                         vr->get_action_handle(candidate) != nullptr ? "ok" : "null");
                }
            }
        }
        if (!m_pause_ok) {
            return false;
        }

        const auto source = left ? vr->get_left_joystick_source() : vr->get_right_joystick_source();
        const bool held = vr->is_action_active(m_pause_action, source);
        if (held) {
            m_pause_seen = true;
        }
        return held;
    }

    // SystemButton resolves but never goes active - SteamVR keeps the menu button for
    // its own dashboard, so it never reaches the game. Rather than guess a third time,
    // watch every candidate and report which ones a real press actually reaches.
    struct Candidate {
        const char* label;
        const char* path;
        bool right;
    };

    void sample_actions() {
        static const Candidate candidates[] = {
            {"SystemL",  "/actions/default/in/SystemButton",  false},
            {"SystemR",  "/actions/default/in/SystemButton",  true},
            {"StickL",   "/actions/default/in/JoystickClick", false},
            {"StickR",   "/actions/default/in/JoystickClick", true},
            {"GripL",    "/actions/default/in/Grip",          false},
            {"GripR",    "/actions/default/in/Grip",          true},
            {"AL",       "/actions/default/in/AButtonLeft",   false},
            {"AR",       "/actions/default/in/AButtonRight",  true},
            {"BL",       "/actions/default/in/BButtonLeft",   false},
            {"BR",       "/actions/default/in/BButtonRight",  true},
            {"DPadUp",   "/actions/default/in/DPad_Up",       false},
            {"DPadDown", "/actions/default/in/DPad_Down",     false},
        };
        constexpr size_t count = sizeof(candidates) / sizeof(candidates[0]);

        const auto* vr = API::get()->param()->vr;
        if (vr == nullptr) {
            return;
        }

        static UEVR_ActionHandle handles[count]{};
        static bool resolved = false;
        if (!resolved) {
            resolved = true;
            for (size_t i = 0; i < count; ++i) {
                handles[i] = vr->get_action_handle(candidates[i].path);
            }
        }

        for (size_t i = 0; i < count; ++i) {
            if (handles[i] == nullptr || m_action_seen[i]) {
                continue;
            }
            const auto source =
                candidates[i].right ? vr->get_right_joystick_source() : vr->get_left_joystick_source();
            if (vr->is_action_active(handles[i], source)) {
                m_action_seen[i] = true;
                API::get()->log_info("[EuropaVR] VR button reachable: %s", candidates[i].label);
            }
        }
    }

    // Europa's readable books are actors that park themselves DistanceInfrontOfCamera
    // units ahead of the view. That distance was chosen for a camera several metres
    // behind the character; from inside her head the book ends up against your face.
    // Rewriting the variable is enough - the Blueprint re-reads it as it positions
    // itself, so there is nothing to fight.
    void handle_books() {
        if (m_config.book_distance <= 0.0f) {
            return;
        }

        // Twice a second is ample for an object the player opens and reads. Running this
        // every frame is what wrecked the framerate: find_uobject is a linear search by
        // name over the whole object array, and API.hpp warns against calling it often -
        // five of them per frame, plus a class scan each, was the cost.
        if (++m_book_age < 30) {
            return;
        }
        m_book_age = 0;

        for (auto* klass : book_classes()) {
            for (auto* book : API::UObjectHook::get_objects_by_class(klass, false)) {
                auto* distance = book->get_property_data<float>(L"DistanceInfrontOfCamera");
                if (distance == nullptr) {
                    continue;
                }

                if (!m_book_logged) {
                    m_book_logged = true;
                    API::get()->log_info("[EuropaVR] book %s | distance=%.1f",
                                         narrow(book->get_full_name()).c_str(), *distance);
                }

                if (m_config.book_distance > 0.0f) {
                    *distance = m_config.book_distance;
                }
            }
        }
    }

    // Resolved once and kept. These names never change while the game runs.
    static const std::vector<API::UClass*>& book_classes() {
        static const std::vector<API::UClass*> cached = [] {
            static const wchar_t* const paths[] = {
                L"BlueprintGeneratedClass /Game/Effects/Book/BP_BookUI_multipage.BP_BookUI_multipage_C",
                L"BlueprintGeneratedClass /Game/Effects/Book/BP_BookUI_multipage_beast.BP_BookUI_multipage_beast_C",
                L"BlueprintGeneratedClass /Game/Effects/Book/BP_BookUI_PagePickup.BP_BookUI_PagePickup_C",
                L"BlueprintGeneratedClass /Game/Effects/Book/BP_BookUI_BeastPickup.BP_BookUI_BeastPickup_C",
                L"BlueprintGeneratedClass /Game/Effects/Book/BP_Bestiary_BookPickup.BP_Bestiary_BookPickup_C",
            };
            std::vector<API::UClass*> out;
            for (const wchar_t* path : paths) {
                if (auto* k = API::get()->find_uobject<API::UClass>(path)) {
                    out.push_back(k);
                }
            }
            API::get()->log_info("[EuropaVR] book classes resolved: %d", (int)out.size());
            return out;
        }();
        return cached;
    }


    // Yaw about the OpenXR up axis (Y).
    static float quat_yaw(const UEVR_Quaternionf& q) {
        const float siny = 2.0f * (q.w * q.y + q.x * q.z);
        const float cosy = 1.0f - 2.0f * (q.y * q.y + q.z * q.z);
        return std::atan2(siny, cosy) * kRadToDeg;
    }

    float hmd_quat_yaw() {
        const auto* vr = API::get()->param()->vr;
        if (vr == nullptr) {
            return 0.0f;
        }

        UEVR_Vector3f pos{};
        UEVR_Quaternionf q{};
        vr->get_pose(vr->get_hmd_index(), &pos, &q);

        // Recentering shifts UEVR's world rotation offset. Logged only for now, so the
        // effect can be measured before anything depends on it.
        UEVR_Quaternionf offset{};
        vr->get_rotation_offset(&offset);
        m_offset_yaw.store(quat_yaw(offset));

        return quat_yaw(q);
    }

    void update_final_yaw() {
        m_quat_yaw.store(hmd_quat_yaw());

        const float head = (m_config.yaw_method == 0)
            ? m_quat_yaw.load() * m_config.yaw_sign + m_snap_yaw.load()
            : m_eye_yaw.load();

        m_final_yaw.store(normalize_deg(head + m_config.yaw_offset));
    }

    void apply_body_orientation() {
        if (!m_config.apply_body_yaw) {
            return;
        }

        // Property lookups go by name and walk the class chain, so they are resolved
        // once per controller and per pawn rather than sixty times a second. The
        // pointers stay valid for the life of the object they point into.
        auto* pc = API::get()->get_player_controller(0);
        if (pc != m_pc) {
            m_pc = pc;
            m_control_rotation = pc != nullptr
                ? pc->get_property_data<UEVR_Rotatorf>(L"ControlRotation")
                : nullptr;
            m_control_ok = m_control_rotation != nullptr;
        }

        if (m_control_rotation != nullptr) {
            // Pitch stays flat: tipping the character because the player looked up is
            // exactly what breaks VR comfort.
            m_control_rotation->pitch = 0.0f;
            m_control_rotation->yaw = m_final_yaw.load();
            m_control_rotation->roll = 0.0f;
        }

        auto* pawn = API::get()->get_local_pawn(0);
        if (pawn == nullptr) {
            return;
        }

        if (pawn != m_pawn) {
            m_pawn = pawn;
            // ALS_RotationMode: 1 = LookingDirection, which strafes and backpedals
            // instead of pivoting to face the direction of travel.
            m_rotation_mode = pawn->get_property_data<uint8_t>(L"RotationMode");
            m_cmc = deref_object(pawn, L"CharacterMovement");
            m_rot_mode_ok = m_rotation_mode != nullptr;
            m_cmc_ok = m_cmc != nullptr;
            m_flag_age = 0; // re-assert the flags immediately on a new pawn
        }

        if (m_rotation_mode != nullptr) {
            *m_rotation_mode = 1;
        }

        // These are mode flags, not per-frame state. Six times a second is responsive
        // enough, and set_bool_property has to find the property by name every call.
        if (--m_flag_age > 0) {
            return;
        }
        m_flag_age = 10;

        pawn->set_bool_property(L"bUseControllerRotationYaw", true);

        if (m_cmc != nullptr) {
            m_cmc->set_bool_property(L"bOrientRotationToMovement", false);
            m_cmc->set_bool_property(L"bUseControllerDesiredRotation", true);
        }
    }

    void log_state() {
        char target[256]{};
        WideCharToMultiByte(CP_UTF8, 0, m_view_target_name.c_str(), -1, target,
                            (int)sizeof(target) - 1, nullptr, nullptr);

        API::get()->log_info(
            "[EuropaVR] quat_yaw=%.1f eye_yaw=%.1f offset_yaw=%.1f snap_yaw=%.1f final_yaw=%.1f "
            "snaps=%d | control=%d rot_mode=%d cmc=%d pause=%d/%d | target=%s",
            m_quat_yaw.load(), m_eye_yaw.load(), m_offset_yaw.load(), m_snap_yaw.load(),
            m_final_yaw.load(), m_snap_count, (int)m_control_ok, (int)m_rot_mode_ok,
            (int)m_cmc_ok, (int)m_pause_ok, (int)m_pause_seen, target);
    }

    // Reloads the ini and reports only when something actually moved, so tuning the
    // camera from the file shows up in the log without spamming it.

    // Reloads the ini and reports only when something actually moved, so tuning the
    // camera from the file shows up in the log without spamming it.
    void reload_config_if_changed() {
        // Only reopen the file when it has actually been written to. Parsing it once a
        // second regardless is a pointless disk hit for a value that changes twice in a
        // session, if at all.
        std::error_code ec;
        const auto stamp = std::filesystem::last_write_time(settings_path(), ec);
        if (ec) {
            return;
        }
        if (stamp == m_config_stamp) {
            return;
        }
        m_config_stamp = stamp;

        const Config before = m_config;
        load_config();

        if (before.forward_offset != m_config.forward_offset ||
            before.up_offset != m_config.up_offset ||
            before.yaw_sign != m_config.yaw_sign ||
            before.yaw_offset != m_config.yaw_offset ||
            before.snap_angle != m_config.snap_angle ||
            before.turn_mode != m_config.turn_mode ||
            before.smooth_speed != m_config.smooth_speed) {
            API::get()->log_info(
                "[EuropaVR] config reloaded | forward=%.1f up=%.1f yaw_sign=%.0f "
                "yaw_offset=%.1f snap_angle=%.0f",
                m_config.forward_offset, m_config.up_offset, m_config.yaw_sign,
                m_config.yaw_offset, m_config.snap_angle);
        }
    }

    // One settings file, in the game folder, next to everything else the player
    // unpacked. The plugin lives in the UEVR profile but that is an implementation
    // detail; nobody should have to know it to change a number.
    static std::filesystem::path settings_path() {
        wchar_t buf[MAX_PATH * 2]{};
        if (GetModuleFileNameW(nullptr, buf, static_cast<DWORD>(std::size(buf))) == 0) {
            return {};
        }
        return std::filesystem::path{buf}.parent_path() / L"EuropaVR" / L"EuropaVR.ini";
    }

    void load_config() {
        const auto path = settings_path();
        std::ifstream in{path};
        if (!in) {
            return;
        }

        std::string line;
        while (std::getline(in, line)) {
            const auto eq = line.find('=');
            if (eq == std::string::npos || line.empty() || line[0] == ';') {
                continue;
            }
            const auto key = line.substr(0, eq);
            const auto value = line.substr(eq + 1);

            if (key == "YawMethod")          m_config.yaw_method = std::atoi(value.c_str());
            else if (key == "YawSign")       m_config.yaw_sign = (float)std::atof(value.c_str());
            else if (key == "YawOffset")     m_config.yaw_offset = (float)std::atof(value.c_str());
            else if (key == "ApplyBodyYaw")  m_config.apply_body_yaw = std::atoi(value.c_str()) != 0;
            else if (key == "WriteViewRot")  m_config.write_view_rot = std::atoi(value.c_str()) != 0;
            else if (key == "ForwardOffset") m_config.forward_offset = (float)std::atof(value.c_str());
            else if (key == "UpOffset")      m_config.up_offset = (float)std::atof(value.c_str());
            else if (key == "SnapTurn")      m_config.snap_turn = std::atoi(value.c_str()) != 0;
            else if (key == "SnapAngle")     m_config.snap_angle = (float)std::atof(value.c_str());
            else if (key == "SnapThreshold") m_config.snap_threshold = (float)std::atof(value.c_str());
            else if (key == "SnapRelease")   m_config.snap_release = (float)std::atof(value.c_str());
            else if (key == "SnapCooldown")  m_config.snap_cooldown = (float)std::atof(value.c_str());
            else if (key == "TurnMode")      m_config.turn_mode = std::atoi(value.c_str());
            else if (key == "SmoothTurnSpeed") m_config.smooth_speed = (float)std::atof(value.c_str());
            else if (key == "TurnDeadzone")  m_config.turn_deadzone = (float)std::atof(value.c_str());
            else if (key == "LogEvery")      m_config.log_every = std::atoi(value.c_str());
            else if (key == "PauseButton")   m_config.pause_button = std::atoi(value.c_str());
            else if (key == "BookDistance")  m_config.book_distance = (float)std::atof(value.c_str());
            else if (key == "ActionProbe")   m_config.action_probe = std::atoi(value.c_str()) != 0;
        }
    }

    Config m_config{};

    std::atomic<bool>  m_gameplay{false};
    std::atomic<float> m_snap_yaw{0.0f};
    std::atomic<float> m_turn_axis{0.0f};
    std::atomic<float> m_quat_yaw{0.0f};
    std::atomic<float> m_eye_yaw{0.0f};
    std::atomic<float> m_offset_yaw{0.0f};
    std::atomic<float> m_final_yaw{0.0f};

    UEVR_Vector3f m_left_eye{};
    bool m_have_left{false};

    UEVR_ActionHandle m_pause_action{};
    bool m_pause_resolved{false};
    bool m_pause_ok{false};
    bool m_pause_seen{false};
    bool m_action_seen[12]{};
    API::UObject* m_pc{nullptr};
    API::UObject* m_pawn{nullptr};
    API::UClass*  m_view_class{nullptr};
    UEVR_Rotatorf* m_control_rotation{nullptr};
    uint8_t*       m_rotation_mode{nullptr};
    API::UObject*  m_cmc{nullptr};
    bool m_view_is_gameplay{false};
    int  m_flag_age{0};

    bool m_book_logged{false};
    int  m_book_age{0};

    bool m_snap_armed{true};
    float m_snap_wait{0.0f};
    int  m_snap_count{0};

    int  m_frames{0};
    int  m_config_age{0};
    std::filesystem::file_time_type m_config_stamp{};
    bool m_control_ok{false};
    bool m_rot_mode_ok{false};
    bool m_cmc_ok{false};

    std::wstring m_view_target_name{};
};

// Plugin.hpp picks this up through uevr::detail::g_plugin.
static EuropaVR g_europavr_plugin{};
