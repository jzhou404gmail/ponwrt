/* aes-check: probe ARMv8 Crypto Extensions availability and OpenSSL throughput.
 * Static aarch64 binary, linked against the target libcrypto.a built by ponwrt.
 * Mirrors the AN7581 (XG-140G-MD) OPENSSL_armcap analysis in
 * docs/an7581-armv8-crypto-guide.md, applied to AN7583 (XG-040G-MF).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/auxv.h>
#include <openssl/evp.h>
#include <openssl/crypto.h>

/* OpenSSL 3.x arm_arch.h values */
#define ARMV7_NEON   (1u << 0)
#define ARMV8_AES    (1u << 2)
#define ARMV8_SHA1   (1u << 3)
#define ARMV8_SHA256 (1u << 4)
#define ARMV8_PMULL  (1u << 5)
#define ARMV8_SHA512 (1u << 6)

#ifndef NO_ARMCAP
/* defined in libcrypto (crypto/armcap.c); hidden in the shared library build */
extern unsigned int OPENSSL_armcap_P;
#endif

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static double bench(const EVP_CIPHER *c, const char *label, int iters, int len)
{
	unsigned char *in  = calloc(1, len);
	unsigned char *out = calloc(1, len + 64);
	unsigned char key[32] = { 0 }, iv[16] = { 0 };
	EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
	int outl = 0, i;
	double t0, t1;

	if (!in || !out || !ctx)
		return -1;

	if (EVP_EncryptInit_ex(ctx, c, NULL, key, iv) != 1) {
		printf("%-12s : init failed\n", label);
		return -1;
	}
	/* warm-up, then timed loop on the same context (bulk throughput) */
	EVP_EncryptUpdate(ctx, out, &outl, in, len);
	t0 = now();
	for (i = 0; i < iters; i++)
		EVP_EncryptUpdate(ctx, out, &outl, in, len);
	t1 = now();

	EVP_CIPHER_CTX_free(ctx);
	free(in);
	free(out);
	return (double)iters * (double)len / (t1 - t0) / 1e6;
}

int main(void)
{
	unsigned long hw = getauxval(AT_HWCAP);
#ifndef NO_ARMCAP
	unsigned int cap = OPENSSL_armcap_P;
#endif
	const int L = 16384, N = 30000;

	printf("OpenSSL      : %s\n", OpenSSL_version(OPENSSL_VERSION));
	printf("AT_HWCAP     : 0x%lx  asimd=%d aes=%d pmull=%d sha1=%d sha2=%d\n",
	       hw, !!(hw & (1UL << 1)), !!(hw & (1UL << 3)), !!(hw & (1UL << 4)),
	       !!(hw & (1UL << 5)), !!(hw & (1UL << 6)));
#ifndef NO_ARMCAP
	printf("OPENSSL_armcap_P : 0x%x  neon=%d aes=%d sha1=%d sha256=%d pmull=%d\n",
	       cap, !!(cap & ARMV7_NEON), !!(cap & ARMV8_AES), !!(cap & ARMV8_SHA1),
	       !!(cap & ARMV8_SHA256), !!(cap & ARMV8_PMULL));
#else
	printf("linked against: the shared libcrypto.so.3 installed on the device\n");
#endif
	printf("%-12s : %8.1f MB/s\n", "aes-128-gcm", bench(EVP_aes_128_gcm(), "aes-128-gcm", N, L));
	printf("%-12s : %8.1f MB/s\n", "aes-256-gcm", bench(EVP_aes_256_gcm(), "aes-256-gcm", N, L));
	printf("%-12s : %8.1f MB/s\n", "aes-128-cbc", bench(EVP_aes_128_cbc(), "aes-128-cbc", N, L));
	printf("%-12s : %8.1f MB/s\n", "aes-128-ctr", bench(EVP_aes_128_ctr(), "aes-128-ctr", N, L));
	printf("%-12s : %8.1f MB/s\n", "chacha20-poly1305", bench(EVP_chacha20_poly1305(), "chacha20-poly1305", N, L));

	return 0;
}
