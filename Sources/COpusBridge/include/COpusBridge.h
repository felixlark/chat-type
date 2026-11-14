#ifndef CHATTYPE_OPUS_BRIDGE_H
#define CHATTYPE_OPUS_BRIDGE_H
// Keep the variadic opus_encoder_ctl ABI in C, including arm64 stack arguments.
int chattype_opus_ctl_int(void *function, void *encoder, int request, int value);
#endif
