#ifndef VEIL_H
#define VEIL_H
#include <stdint.h>

typedef struct Engine VeilEngine;
VeilEngine *veil_engine_new(const char *config_json, const uint8_t key[32]);
char *veil_config_validate(const char *config_json);
char *veil_engine_scan(const VeilEngine *, const char *text, const char *context_json);
char *veil_engine_hash(const VeilEngine *, const char *value);
void veil_string_free(char *value);
// Call free only after all scans finish; all input strings must be valid UTF-8.
void veil_engine_free(VeilEngine *);
#endif
