#include "common.hpp"

namespace europavr {
void start_bootstrap();
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        // Nothing that touches the loader may happen here. The thread body only
        // starts running once the loader lock is released, which is still well
        // before the engine gets anywhere near its VR plugins.
        europavr::start_bootstrap();
    }
    return TRUE;
}
