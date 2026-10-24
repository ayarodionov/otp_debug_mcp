/* The native half of native_shop: two NIFs, each with a classic bug.
 *
 * checksum/1 does about 80 ms of work on a normal scheduler without
 * yielding: every other process on that scheduler waits for it.
 * parse/1 copies its input into a buffer it never frees: 256 KB of native
 * memory per call, which erlang:memory() never shows. */
#include <erl_nif.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static ERL_NIF_TERM checksum(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
    /* The bug: 80 ms of rounds over the input, in one go. */
    unsigned long sum = 0;
    double until = now_ms() + 80.0;
    while (now_ms() < until)
        for (size_t i = 0; i < bin.size; i++) sum = sum * 31 + bin.data[i];
    return enif_make_ulong(env, sum);
}

static ERL_NIF_TERM parse(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
    /* The bug: a working buffer that's never freed. It's filled with
     * pseudo-random bytes, as parsed data usually is, so the OS can't
     * compress it away the way it would zeros. */
    size_t size = 256 * 1024;
    unsigned char *buffer = malloc(size);
    if (buffer == NULL) return enif_make_badarg(env);
    unsigned int x = 2463534242u;
    for (size_t i = 0; i < size; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        buffer[i] = (unsigned char)x;
    }
    memcpy(buffer, bin.data, bin.size < size ? bin.size : size);
    return enif_make_ulong(env, (unsigned long)bin.size);
}

static ErlNifFunc funcs[] = {{"checksum", 1, checksum, 0}, {"parse", 1, parse, 0}};
ERL_NIF_INIT(native_nif, funcs, NULL, NULL, NULL, NULL)
