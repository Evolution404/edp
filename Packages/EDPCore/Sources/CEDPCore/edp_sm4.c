#include "edp_core.h"

#include <stdlib.h>
#include <string.h>

struct edp_sm4_context {
    uint32_t enc_rk[32];
    uint32_t dec_rk[32];
};

static const uint8_t SBOX[256] = {
    0xd6,0x90,0xe9,0xfe,0xcc,0xe1,0x3d,0xb7,0x16,0xb6,0x14,0xc2,0x28,0xfb,0x2c,0x05,
    0x2b,0x67,0x9a,0x76,0x2a,0xbe,0x04,0xc3,0xaa,0x44,0x13,0x26,0x49,0x86,0x06,0x99,
    0x9c,0x42,0x50,0xf4,0x91,0xef,0x98,0x7a,0x33,0x54,0x0b,0x43,0xed,0xcf,0xac,0x62,
    0xe4,0xb3,0x1c,0xa9,0xc9,0x08,0xe8,0x95,0x80,0xdf,0x94,0xfa,0x75,0x8f,0x3f,0xa6,
    0x47,0x07,0xa7,0xfc,0xf3,0x73,0x17,0xba,0x83,0x59,0x3c,0x19,0xe6,0x85,0x4f,0xa8,
    0x68,0x6b,0x81,0xb2,0x71,0x64,0xda,0x8b,0xf8,0xeb,0x0f,0x4b,0x70,0x56,0x9d,0x35,
    0x1e,0x24,0x0e,0x5e,0x63,0x58,0xd1,0xa2,0x25,0x22,0x7c,0x3b,0x01,0x21,0x78,0x87,
    0xd4,0x00,0x46,0x57,0x9f,0xd3,0x27,0x52,0x4c,0x36,0x02,0xe7,0xa0,0xc4,0xc8,0x9e,
    0xea,0xbf,0x8a,0xd2,0x40,0xc7,0x38,0xb5,0xa3,0xf7,0xf2,0xce,0xf9,0x61,0x15,0xa1,
    0xe0,0xae,0x5d,0xa4,0x9b,0x34,0x1a,0x55,0xad,0x93,0x32,0x30,0xf5,0x8c,0xb1,0xe3,
    0x1d,0xf6,0xe2,0x2e,0x82,0x66,0xca,0x60,0xc0,0x29,0x23,0xab,0x0d,0x53,0x4e,0x6f,
    0xd5,0xdb,0x37,0x45,0xde,0xfd,0x8e,0x2f,0x03,0xff,0x6a,0x72,0x6d,0x6c,0x5b,0x51,
    0x8d,0x1b,0xaf,0x92,0xbb,0xdd,0xbc,0x7f,0x11,0xd9,0x5c,0x41,0x1f,0x10,0x5a,0xd8,
    0x0a,0xc1,0x31,0x88,0xa5,0xcd,0x7b,0xbd,0x2d,0x74,0xd0,0x12,0xb8,0xe5,0xb4,0xb0,
    0x89,0x69,0x97,0x4a,0x0c,0x96,0x77,0x7e,0x65,0xb9,0xf1,0x09,0xc5,0x6e,0xc6,0x84,
    0x18,0xf0,0x7d,0xec,0x3a,0xdc,0x4d,0x20,0x79,0xee,0x5f,0x3e,0xd7,0xcb,0x39,0x48
};

static const uint32_t FK[4] = {0xa3b1bac6U,0x56aa3350U,0x677d9197U,0xb27022dcU};
static const uint32_t CK[32] = {
    0x00070e15U,0x1c232a31U,0x383f464dU,0x545b6269U,0x70777e85U,0x8c939aa1U,0xa8afb6bdU,0xc4cbd2d9U,
    0xe0e7eef5U,0xfc030a11U,0x181f262dU,0x343b4249U,0x50575e65U,0x6c737a81U,0x888f969dU,0xa4abb2b9U,
    0xc0c7ced5U,0xdce3eaf1U,0xf8ff060dU,0x141b2229U,0x30373e45U,0x4c535a61U,0x686f767dU,0x848b9299U,
    0xa0a7aeb5U,0xbcc3cad1U,0xd8dfe6edU,0xf4fb0209U,0x10171e25U,0x2c333a41U,0x484f565dU,0x646b7279U
};

static uint32_t T0[256], T1[256], T2[256], T3[256];
static int tables_ready = 0;

static inline uint32_t rol32(uint32_t x, unsigned n) { return (x << n) | (x >> (32U - n)); }
static inline uint32_t load_be32(const uint8_t *p) {
    uint32_t value;
    __builtin_memcpy(&value, p, sizeof(value));
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    value = __builtin_bswap32(value);
#endif
    return value;
}
static inline void store_be32(uint8_t *p, uint32_t x) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    x = __builtin_bswap32(x);
#endif
    __builtin_memcpy(p, &x, sizeof(x));
}
static inline uint32_t tau(uint32_t x) {
    return ((uint32_t)SBOX[(x>>24)&0xffU]<<24) | ((uint32_t)SBOX[(x>>16)&0xffU]<<16) |
           ((uint32_t)SBOX[(x>>8)&0xffU]<<8) | (uint32_t)SBOX[x&0xffU];
}
static inline uint32_t lp(uint32_t x) { uint32_t b=tau(x); return b ^ rol32(b,13) ^ rol32(b,23); }
static inline uint32_t l(uint32_t b) { return b ^ rol32(b,2) ^ rol32(b,10) ^ rol32(b,18) ^ rol32(b,24); }

static void init_tables(void) {
    if (tables_ready) return;
    for (unsigned i=0;i<256;i++) {
        uint32_t b=(uint32_t)SBOX[i];
        T0[i]=l(b<<24); T1[i]=l(b<<16); T2[i]=l(b<<8); T3[i]=l(b);
    }
    tables_ready=1;
}

static inline uint32_t round_t(uint32_t x) {
    return T0[(x>>24)&0xffU]^T1[(x>>16)&0xffU]^T2[(x>>8)&0xffU]^T3[x&0xffU];
}

edp_sm4_context *edp_sm4_create(const uint8_t *key, size_t key_len) {
    if (!key || key_len!=16) return NULL;
    init_tables();
    edp_sm4_context *ctx=(edp_sm4_context *)calloc(1,sizeof(*ctx));
    if (!ctx) return NULL;
    uint32_t k0=load_be32(key)^FK[0], k1=load_be32(key+4)^FK[1];
    uint32_t k2=load_be32(key+8)^FK[2], k3=load_be32(key+12)^FK[3];
    for (unsigned i=0;i<32;i++) {
        uint32_t n=k0^lp(k1^k2^k3^CK[i]);
        ctx->enc_rk[i]=n; k0=k1; k1=k2; k2=k3; k3=n;
    }
    for (unsigned i=0;i<32;i++) ctx->dec_rk[i]=ctx->enc_rk[31-i];
    return ctx;
}

void edp_sm4_destroy(edp_sm4_context *ctx) {
    if (!ctx) return;
    volatile uint8_t *p=(volatile uint8_t *)ctx;
    for (size_t i=0;i<sizeof(*ctx);i++) p[i]=0;
    free(ctx);
}

#define R4(x0,x1,x2,x3,rk,r) do { \
    (x0) ^= round_t((x1) ^ (x2) ^ (x3) ^ (rk)[(r)]); \
    (x1) ^= round_t((x2) ^ (x3) ^ (x0) ^ (rk)[(r)+1]); \
    (x2) ^= round_t((x3) ^ (x0) ^ (x1) ^ (rk)[(r)+2]); \
    (x3) ^= round_t((x0) ^ (x1) ^ (x2) ^ (rk)[(r)+3]); \
} while (0)

static inline void crypt1(const uint32_t *rk,const uint8_t *in,uint8_t *out) {
    uint32_t x0=load_be32(in),x1=load_be32(in+4),x2=load_be32(in+8),x3=load_be32(in+12);
    for (unsigned r=0;r<32;r+=4) R4(x0,x1,x2,x3,rk,r);
    store_be32(out,x3);store_be32(out+4,x2);store_be32(out+8,x1);store_be32(out+12,x0);
}

static inline void crypt4(const uint32_t *rk,const uint8_t *in,uint8_t *out) {
    uint32_t a0=load_be32(in),a1=load_be32(in+4),a2=load_be32(in+8),a3=load_be32(in+12);
    uint32_t b0=load_be32(in+16),b1=load_be32(in+20),b2=load_be32(in+24),b3=load_be32(in+28);
    uint32_t c0=load_be32(in+32),c1=load_be32(in+36),c2=load_be32(in+40),c3=load_be32(in+44);
    uint32_t d0=load_be32(in+48),d1=load_be32(in+52),d2=load_be32(in+56),d3=load_be32(in+60);
    for (unsigned r=0;r<32;r+=4) {
        R4(a0,a1,a2,a3,rk,r);
        R4(b0,b1,b2,b3,rk,r);
        R4(c0,c1,c2,c3,rk,r);
        R4(d0,d1,d2,d3,rk,r);
    }
    store_be32(out,a3);store_be32(out+4,a2);store_be32(out+8,a1);store_be32(out+12,a0);
    store_be32(out+16,b3);store_be32(out+20,b2);store_be32(out+24,b1);store_be32(out+28,b0);
    store_be32(out+32,c3);store_be32(out+36,c2);store_be32(out+40,c1);store_be32(out+44,c0);
    store_be32(out+48,d3);store_be32(out+52,d2);store_be32(out+56,d1);store_be32(out+60,d0);
}

#undef R4

static int crypt(const edp_sm4_context *ctx,const uint8_t *in,uint8_t *out,size_t len,const uint32_t *rk) {
    if (!ctx || (!in && len) || (!out && len) || (len&15U)) return -1;
    size_t off=0;
    for (; off+64<=len; off+=64) crypt4(rk,in+off,out+off);
    for (; off<len; off+=16) crypt1(rk,in+off,out+off);
    return 0;
}
int edp_sm4_encrypt(const edp_sm4_context *ctx,const uint8_t *in,uint8_t *out,size_t len) { return crypt(ctx,in,out,len,ctx?ctx->enc_rk:NULL); }
int edp_sm4_decrypt(const edp_sm4_context *ctx,const uint8_t *in,uint8_t *out,size_t len) { return crypt(ctx,in,out,len,ctx?ctx->dec_rk:NULL); }

const char *edp_sm4_backend_name(void) { return "sm4-tables-4way-unrolled-c"; }
