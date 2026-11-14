#include "COpusBridge.h"
int chattype_opus_ctl_int(void *function, void *encoder, int request, int value) {
    if (!function || !encoder) return -1;
    return ((int (*)(void *, int, ...))function)(encoder, request, value);
}
