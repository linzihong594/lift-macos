#include "ProcessIdentity.h"
#include <ApplicationServices/ApplicationServices.h>

int32_t LiftRegisterBackgroundIdentity(void) {
    ProcessSerialNumber process;
    // This public Process Manager check-in associates a faceless app with its
    // bundle/icon. Its AppKit replacement would load UI frameworks in the agent.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSErr result = GetCurrentProcess(&process);
#pragma clang diagnostic pop
    return result;
}
