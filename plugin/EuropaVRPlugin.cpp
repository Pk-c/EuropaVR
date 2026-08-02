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
    float forward_offset = 12.0f;

    bool  snap_turn      = true;
    float snap_angle     = 45.0f;
    float snap_threshold = 0.5f;
    float snap_release   = 0.3f;
    int   snap_cooldown  = 18;

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

    void on_pre_engine_tick(API::UGameEngine*, float) override {
        if (m_snap_wait > 0) {
            --m_snap_wait;
        }
        m_gameplay.store(compute_gameplay());
    }

    void on_post_engine_tick(API::UGameEngine*, float) override {
        if (!m_gameplay.load()) {
            return;
        }

        update_final_yaw();
        apply_body_orientation();

        if (++m_frames >= m_config.log_every) {
            m_frames = 0;
            log_state();
        }
    }

    void on_xinput_get_state(uint32_t*, uint32_t user_index, XINPUT_STATE* state) override {
        if (state == nullptr || !m_config.snap_turn) {
            return;
        }

        // Only pad 0 drives the snap. Evaluating every index was what made the Lua
        // version spin: the empty pads read as centred and re-armed the trigger
        // between two real samples.
        if (user_index == 0 && m_gameplay.load()) {
            const float axis = state->Gamepad.sThumbRX / 32767.0f;
            const float mag = std::fabs(axis);

            if (mag < m_config.snap_release) {
                m_snap_armed = true;
            } else if (m_snap_armed && m_snap_wait <= 0 && mag >= m_config.snap_threshold) {
                const float step = axis > 0.0f ? m_config.snap_angle : -m_config.snap_angle;
                m_snap_yaw.store(normalize_deg(m_snap_yaw.load() + step));
                m_snap_armed = false;
                m_snap_wait = m_config.snap_cooldown;
                ++m_snap_count;
            }
        }

        // The game must never see the right stick, or its own TurnRate fights us.
        state->Gamepad.sThumbRX = 0;
        state->Gamepad.sThumbRY = 0;
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

        if (m_config.forward_offset != 0.0f && m_gameplay.load()) {
            const float r = m_final_yaw.load() * kDegToRad;
            position->x += std::cos(r) * m_config.forward_offset;
            position->y += std::sin(r) * m_config.forward_offset;
        }
    }

private:
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

        m_view_target_name = target->get_full_name();
        return m_view_target_name.find(L"LakituCam") != std::wstring::npos;
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

        auto* pc = API::get()->get_player_controller(0);
        if (pc != nullptr) {
            if (auto* cr = pc->get_property_data<UEVR_Rotatorf>(L"ControlRotation")) {
                // Pitch stays flat: tipping the character because the player looked up
                // is exactly what breaks VR comfort.
                cr->pitch = 0.0f;
                cr->yaw = m_final_yaw.load();
                cr->roll = 0.0f;
                m_control_ok = true;
            } else {
                m_control_ok = false;
            }
        }

        auto* pawn = API::get()->get_local_pawn(0);
        if (pawn == nullptr) {
            return;
        }

        pawn->set_bool_property(L"bUseControllerRotationYaw", true);

        // ALS_RotationMode: 1 = LookingDirection, which strafes and backpedals instead
        // of pivoting to face the direction of travel.
        if (auto* mode = pawn->get_property_data<uint8_t>(L"RotationMode")) {
            *mode = 1;
            m_rot_mode_ok = true;
        } else {
            m_rot_mode_ok = false;
        }

        if (auto* cmc = deref_object(pawn, L"CharacterMovement")) {
            cmc->set_bool_property(L"bOrientRotationToMovement", false);
            cmc->set_bool_property(L"bUseControllerDesiredRotation", true);
            m_cmc_ok = true;
        } else {
            m_cmc_ok = false;
        }
    }

    void log_state() {
        char target[256]{};
        WideCharToMultiByte(CP_UTF8, 0, m_view_target_name.c_str(), -1, target,
                            (int)sizeof(target) - 1, nullptr, nullptr);

        API::get()->log_info(
            "[EuropaVR] quat_yaw=%.1f eye_yaw=%.1f offset_yaw=%.1f snap_yaw=%.1f final_yaw=%.1f "
            "snaps=%d | control=%d rot_mode=%d cmc=%d | target=%s",
            m_quat_yaw.load(), m_eye_yaw.load(), m_offset_yaw.load(), m_snap_yaw.load(),
            m_final_yaw.load(), m_snap_count, (int)m_control_ok, (int)m_rot_mode_ok,
            (int)m_cmc_ok, target);
    }

    void load_config() {
        const auto path = API::get()->get_persistent_dir(L"EuropaVR_plugin.ini");
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
            else if (key == "SnapTurn")      m_config.snap_turn = std::atoi(value.c_str()) != 0;
            else if (key == "SnapAngle")     m_config.snap_angle = (float)std::atof(value.c_str());
            else if (key == "SnapThreshold") m_config.snap_threshold = (float)std::atof(value.c_str());
            else if (key == "SnapRelease")   m_config.snap_release = (float)std::atof(value.c_str());
            else if (key == "SnapCooldown")  m_config.snap_cooldown = std::atoi(value.c_str());
            else if (key == "LogEvery")      m_config.log_every = std::atoi(value.c_str());
        }
    }

    Config m_config{};

    std::atomic<bool>  m_gameplay{false};
    std::atomic<float> m_snap_yaw{0.0f};
    std::atomic<float> m_quat_yaw{0.0f};
    std::atomic<float> m_eye_yaw{0.0f};
    std::atomic<float> m_offset_yaw{0.0f};
    std::atomic<float> m_final_yaw{0.0f};

    UEVR_Vector3f m_left_eye{};
    bool m_have_left{false};

    bool m_snap_armed{true};
    int  m_snap_wait{0};
    int  m_snap_count{0};

    int  m_frames{0};
    bool m_control_ok{false};
    bool m_rot_mode_ok{false};
    bool m_cmc_ok{false};

    std::wstring m_view_target_name{};
};

// Plugin.hpp picks this up through uevr::detail::g_plugin.
static EuropaVR g_europavr_plugin{};
