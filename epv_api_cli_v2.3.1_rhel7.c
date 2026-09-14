#define _POSIX_C_SOURCE 200112L
#define _XOPEN_SOURCE 700

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <limits.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/md5.h>
#include <openssl/x509v3.h>

#ifdef _WIN32
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "psapi.lib")
typedef SOCKET socket_handle_t;
#define close_socket closesocket
#ifndef PATH_MAX
#define PATH_MAX MAX_PATH
#endif
#else
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <libgen.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
typedef int socket_handle_t;
#define close_socket close
#endif

/* defaults */
#define EPV_CLIENT_VERSION         "2.3.1"
#define SERVER_PORT                6666
#define DEFAULT_CLIENT_CERT        "/opt/epm_certs/client.crt"
#define DEFAULT_CLIENT_KEY         "/opt/epm_certs/client.key"
#define DEFAULT_CA_FILE            "/opt/epm_certs/ca.crt"
#define DEFAULT_SERVER_FILE        "/opt/epm_certs/epv_servers.ini"

#define MAX_SERVERS                32
#define MAX_SERVER_LEN             128
#define MAX_TRIED_SERVERS          64
#define MAX_MESSAGE_LEN            4096
#define MAX_RESPONSE_LEN           8192
#define MAX_PATH_BUF               512
#define MAX_JSON_ESCAPED           (MAX_RESPONSE_LEN * 2)
#define MAX_ANCESTOR_DEPTH         4
#define TOKEN_ORIGIN_TTL_SEC        900
#define DEFAULT_PRIORITY_RECHECK_SEC 30
#define MAX_PRIORITY_RECHECK_SEC     3600

#define DEFAULT_CONNECT_TIMEOUT    3
#define DEFAULT_IO_TIMEOUT         5
#define DEFAULT_RETRIES            2
#define DEFAULT_RETRY_BACKOFF_MS   200

#define MIN_TIMEOUT_SEC            1
#define MAX_TIMEOUT_SEC            300
#define MIN_RETRIES                1
#define MAX_RETRIES                10

typedef enum {
    MODE_UNKNOWN = 0,
    MODE_AD,
    MODE_APP_MD5,
    MODE_APP_SHA256,
    MODE_APP_CHECKSUM,
    MODE_DB,
    MODE_HEALTH
} RunMode;

typedef enum {
    EXIT_OK = 0,
    EXIT_USAGE = 1,
    EXIT_SECURITY = 2,
    EXIT_TLS = 3,
    EXIT_IO = 4,
    EXIT_CONNECT = 5,
    EXIT_CONFIG = 6
} ExitCode;

typedef enum {
    TOKEN_AFFINITY_OFF = 0,
    TOKEN_AFFINITY_PREFER = 1,
    TOKEN_AFFINITY_STRICT = 2
} TokenAffinityMode;

typedef struct {
    int no_verify;                 /* 0 = verify enabled, 1 = insecure */
    int debug;
    int json_output;
    int connect_timeout_sec;
    int io_timeout_sec;
    int retries_per_server;
    unsigned int retry_backoff_ms;
    TokenAffinityMode token_affinity;
    int priority_recheck_sec;
    char server_file[MAX_PATH_BUF];
    char client_cert[MAX_PATH_BUF];
    char client_key[MAX_PATH_BUF];
    char ca_file[MAX_PATH_BUF];
} AppConfig;

static const char *builtin_servers[] = {
    "192.168.167.223",
    "192.168.178.199",
    "192.168.178.200",
    NULL
};

static void secure_bzero(void *ptr, size_t len)
{
    volatile unsigned char *p = (volatile unsigned char *)ptr;
    while (len > 0U) {
        *p++ = 0U;
        --len;
    }
}

static void msleep_unsigned(unsigned int ms)
{
#ifdef _WIN32
    Sleep(ms);
#else
    struct timespec req;
    req.tv_sec = (time_t)(ms / 1000U);
    req.tv_nsec = (long)((ms % 1000U) * 1000000U);
    while (nanosleep(&req, &req) != 0 && errno == EINTR) {
        /* retry */
    }
#endif
}

static int is_hex_n(const char *s, int n)
{
    int i;
    if (s == NULL) return 0;
    if ((int)strlen(s) != n) return 0;

    for (i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (!((c >= (unsigned char)'0' && c <= (unsigned char)'9') ||
              (c >= (unsigned char)'a' && c <= (unsigned char)'f') ||
              (c >= (unsigned char)'A' && c <= (unsigned char)'F'))) {
            return 0;
        }
    }
    return 1;
}

static void print_usage(RunMode mode)
{
    const char *prog = "epv_api";

    (void)fprintf(stderr, "Usage:\n");
    switch (mode) {
        case MODE_AD:
            (void)fprintf(stderr, "  %s [options] [--ad] <AD-User> <AD-Password>\n", prog);
            break;
        case MODE_APP_MD5:
            (void)fprintf(stderr, "  %s [options] <AppFilePath> --md5\n", prog);
            (void)fprintf(stderr, "  %s [options] <AppFilePath> AUTO\n", prog);
            (void)fprintf(stderr, "  %s [options] <AppFilePath> -\n", prog);
            break;
        case MODE_APP_SHA256:
            (void)fprintf(stderr, "  %s [options] <AppFilePath> --sha256\n", prog);
            break;
        case MODE_APP_CHECKSUM:
            (void)fprintf(stderr, "  %s [options] <AppFilePath> <AppChecksum>\n", prog);
            (void)fprintf(stderr, "    <AppChecksum> may be 32-hex (MD5) or 64-hex (SHA256)\n");
            break;
        case MODE_DB:
            (void)fprintf(stderr, "  %s [options] <Token> <DbType> <DbUser> <DbName>\n", prog);
            (void)fprintf(stderr, "  %s [options] --health\n", prog);
            break;
        case MODE_HEALTH:
            (void)fprintf(stderr, "  %s [options] --health\n", prog);
            break;
        case MODE_UNKNOWN:
        default:
            (void)fprintf(stderr, "  %s [options] [--ad] <AD-User> <AD-Password>\n", prog);
            (void)fprintf(stderr, "  %s [options] <AppFilePath> --md5\n", prog);
            (void)fprintf(stderr, "  %s [options] <AppFilePath> --sha256\n", prog);
            (void)fprintf(stderr, "  %s [options] <Token> <DbType> <DbUser> <DbName>\n", prog);
            break;
    }

    (void)fprintf(stderr, "\nOptions:\n");
    (void)fprintf(stderr, "  --verify                  Enable TLS certificate verification (default)\n");
    (void)fprintf(stderr, "  --insecure                Disable TLS certificate verification\n");
    (void)fprintf(stderr, "  --debug                   Enable debug output\n");
    (void)fprintf(stderr, "  --json                    Print JSON result for scripts/PRTG integration\n");
    (void)fprintf(stderr, "  --health                  Query connector health without retrieving a secret\n");
    (void)fprintf(stderr, "  --token-affinity MODE     Token origin affinity: off|prefer|strict (default: off for active/standby)\n");
    (void)fprintf(stderr, "  --priority-recheck N      Recheck higher-priority recovered nodes every N sec (default: %d, 0=always top-down)\n",
                  DEFAULT_PRIORITY_RECHECK_SEC);
    (void)fprintf(stderr, "  --retries N               Retries per server (default: %d, range: %d-%d)\n",
                  DEFAULT_RETRIES, MIN_RETRIES, MAX_RETRIES);
    (void)fprintf(stderr, "  --connect-timeout N       Connect timeout seconds (default: %d)\n",
                  DEFAULT_CONNECT_TIMEOUT);
    (void)fprintf(stderr, "  --io-timeout N            Socket I/O timeout seconds (default: %d)\n",
                  DEFAULT_IO_TIMEOUT);
    (void)fprintf(stderr, "  --server-file PATH        External server list file (default: %s)\n",
                  DEFAULT_SERVER_FILE);
    (void)fprintf(stderr, "  --client-cert PATH        Client certificate file\n");
    (void)fprintf(stderr, "  --client-key PATH         Client private key file\n");
    (void)fprintf(stderr, "  --ca-file PATH            CA certificate file\n");
}

static int parse_positive_int(const char *s, int minv, int maxv, int *out)
{
    char *end = NULL;
    long v;

    if ((s == NULL) || (out == NULL)) return -1;
    errno = 0;
    v = strtol(s, &end, 10);
    if ((errno != 0) || (end == s) || (*end != '\0')) return -1;
    if ((v < (long)minv) || (v > (long)maxv)) return -1;
    *out = (int)v;
    return 0;
}

static int parse_nonnegative_int(const char *s, int maxv, int *out)
{
    char *end = NULL;
    long v;
    if ((s == NULL) || (out == NULL)) return -1;
    errno = 0;
    v = strtol(s, &end, 10);
    if ((errno != 0) || (end == s) || (*end != '\0')) return -1;
    if ((v < 0L) || (v > (long)maxv)) return -1;
    *out = (int)v;
    return 0;
}

static int copy_string_checked(char *dst, size_t dst_size, const char *src)
{
    int rc;
    if ((dst == NULL) || (src == NULL) || (dst_size == 0U)) return -1;
    rc = snprintf(dst, dst_size, "%s", src);
    if (rc < 0) return -1;
    if ((size_t)rc >= dst_size) return -1;
    return 0;
}

static const char *token_affinity_name(TokenAffinityMode mode)
{
    switch (mode) {
        case TOKEN_AFFINITY_OFF: return "off";
        case TOKEN_AFFINITY_STRICT: return "strict";
        case TOKEN_AFFINITY_PREFER:
        default: return "prefer";
    }
}

static int parse_token_affinity(const char *s, TokenAffinityMode *out)
{
    if ((s == NULL) || (out == NULL)) return -1;
    if (strcmp(s, "off") == 0) *out = TOKEN_AFFINITY_OFF;
    else if (strcmp(s, "prefer") == 0) *out = TOKEN_AFFINITY_PREFER;
    else if (strcmp(s, "strict") == 0) *out = TOKEN_AFFINITY_STRICT;
    else return -1;
    return 0;
}

static int token_sha256_hex(const char *token, char out_hex[65])
{
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int md_len = 0U;
    static const char hexdig[] = "0123456789abcdef";
    unsigned int i;

    if ((token == NULL) || (out_hex == NULL)) return -1;

    /* EVP_Digest() is available on both RHEL7/OpenSSL 1.0.2 and modern
       OpenSSL.  Using the one-shot API here avoids EVP_MD_CTX_new/free(),
       which were introduced in OpenSSL 1.1.0. */
    if ((EVP_Digest(token, strlen(token), md, &md_len, EVP_sha256(), NULL) != 1) ||
        (md_len != 32U)) {
        secure_bzero(md, sizeof(md));
        return -1;
    }

    for (i = 0U; i < 32U; ++i) {
        out_hex[i * 2U] = hexdig[(md[i] >> 4) & 0x0FU];
        out_hex[i * 2U + 1U] = hexdig[md[i] & 0x0FU];
    }
    out_hex[64] = '\0';
    secure_bzero(md, sizeof(md));
    return 0;
}

#ifndef _WIN32
static int token_origin_cache_path(char *path, size_t path_size)
{
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    struct stat st;
    if (xdg != NULL && *xdg != '\0' && stat(xdg, &st) == 0 && S_ISDIR(st.st_mode) && st.st_uid == geteuid()) {
        int n = snprintf(path, path_size, "%s/epv_api_token_origin.cache", xdg);
        return (n >= 0 && (size_t)n < path_size) ? 0 : -1;
    }
    {
        int n = snprintf(path, path_size, "/tmp/epv_api_token_origin_%lu.cache", (unsigned long)geteuid());
        return (n >= 0 && (size_t)n < path_size) ? 0 : -1;
    }
}

static int normalize_token_line(const char *src, char *dst, size_t dst_size)
{
    size_t n;
    if (!src || !dst || dst_size == 0U) return -1;
    n = strcspn(src, "\r\n");
    if (n == 0U || n >= dst_size) return -1;
    memcpy(dst, src, n);
    dst[n] = '\0';
    return 0;
}

static int token_origin_store(const char *token_response, const char *server, int debug)
{
    char token[4096];
    char digest[65];
    char path[MAX_PATH_BUF];
    int fd;
    time_t expires;
    struct stat st;
    char cache_line[256];

    if (!token_response || !server) return -1;
    if (normalize_token_line(token_response, token, sizeof(token)) != 0) return -1;
    if (strncmp(token, "s.", 2U) != 0) return 0;
    if (token_sha256_hex(token, digest) != 0 || token_origin_cache_path(path, sizeof(path)) != 0) {
        secure_bzero(token, sizeof(token));
        return -1;
    }
    fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        if (debug) perror("token origin cache open");
        secure_bzero(token, sizeof(token));
        return -1;
    }
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid()) {
        close(fd);
        secure_bzero(token, sizeof(token));
        return -1;
    }
    (void)fchmod(fd, 0600);
    if (flock(fd, LOCK_EX) != 0) {
        close(fd);
        secure_bzero(token, sizeof(token));
        return -1;
    }
    if (st.st_size > (off_t)(1024 * 1024)) {
        if (ftruncate(fd, 0) != 0 && debug) perror("token origin cache truncate");
    }
    expires = time(NULL) + TOKEN_ORIGIN_TTL_SEC;
    {
        int ln = snprintf(cache_line, sizeof(cache_line), "%ld %s %s\n", (long)expires, digest, server);
        if (ln <= 0 || (size_t)ln >= sizeof(cache_line) ||
            write(fd, cache_line, (size_t)ln) != (ssize_t)ln) {
            (void)flock(fd, LOCK_UN);
            close(fd);
            secure_bzero(token, sizeof(token));
            secure_bzero(digest, sizeof(digest));
            return -1;
        }
    }
    (void)flock(fd, LOCK_UN);
    close(fd);
    if (debug) (void)fprintf(stderr, "[DEBUG] token origin cached server=%s digest=%.12s...\n", server, digest);
    secure_bzero(token, sizeof(token));
    secure_bzero(digest, sizeof(digest));
    return 0;
}

static int token_origin_lookup(const char *token_arg, char *server, size_t server_size, int debug)
{
    char digest[65];
    char path[MAX_PATH_BUF];
    FILE *fp;
    char line[512];
    time_t now = time(NULL);
    long best_exp = 0;
    char best_server[MAX_SERVER_LEN] = {0};

    if (!token_arg || !server || server_size == 0U) return 0;
    if (token_sha256_hex(token_arg, digest) != 0 || token_origin_cache_path(path, sizeof(path)) != 0) return 0;
    fp = fopen(path, "r");
    if (fp == NULL) {
        secure_bzero(digest, sizeof(digest));
        return 0;
    }
    if (flock(fileno(fp), LOCK_SH) != 0) {
        (void)fclose(fp);
        secure_bzero(digest, sizeof(digest));
        return 0;
    }
    while (fgets(line, sizeof(line), fp) != NULL) {
        long exp = 0;
        char dg[65];
        char sv[MAX_SERVER_LEN];
        memset(dg, 0, sizeof(dg));
        memset(sv, 0, sizeof(sv));
        if (sscanf(line, "%ld %64s %127s", &exp, dg, sv) == 3 &&
            exp >= (long)now && strcmp(dg, digest) == 0 && exp >= best_exp) {
            best_exp = exp;
            (void)copy_string_checked(best_server, sizeof(best_server), sv);
        }
    }
    (void)flock(fileno(fp), LOCK_UN);
    (void)fclose(fp);
    secure_bzero(digest, sizeof(digest));
    if (best_server[0] == '\0') return 0;
    if (copy_string_checked(server, server_size, best_server) != 0) return 0;
    if (debug) (void)fprintf(stderr, "[DEBUG] token origin affinity server=%s\n", server);
    return 1;
}
#else
static int token_origin_store(const char *token_response, const char *server, int debug)
{
    (void)token_response; (void)server; (void)debug; return 0;
}
static int token_origin_lookup(const char *token_arg, char *server, size_t server_size, int debug)
{
    (void)token_arg; (void)server; (void)server_size; (void)debug; return 0;
}
#endif

static void init_config(AppConfig *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->no_verify = 0;
    cfg->debug = 0;
    cfg->json_output = 0;
    cfg->connect_timeout_sec = DEFAULT_CONNECT_TIMEOUT;
    cfg->io_timeout_sec = DEFAULT_IO_TIMEOUT;
    cfg->retries_per_server = DEFAULT_RETRIES;
    cfg->retry_backoff_ms = DEFAULT_RETRY_BACKOFF_MS;
    cfg->token_affinity = TOKEN_AFFINITY_OFF;
    cfg->priority_recheck_sec = DEFAULT_PRIORITY_RECHECK_SEC;

#ifdef _WIN32
    (void)copy_string_checked(cfg->server_file, sizeof(cfg->server_file), "C:\\opt\\epm_certs\\epv_servers.ini");
    (void)copy_string_checked(cfg->client_cert, sizeof(cfg->client_cert), "C:\\opt\\epm_certs\\client.crt");
    (void)copy_string_checked(cfg->client_key, sizeof(cfg->client_key), "C:\\opt\\epm_certs\\client.key");
    (void)copy_string_checked(cfg->ca_file, sizeof(cfg->ca_file), "C:\\opt\\epm_certs\\ca.crt");
#else
    (void)copy_string_checked(cfg->server_file, sizeof(cfg->server_file), DEFAULT_SERVER_FILE);
    (void)copy_string_checked(cfg->client_cert, sizeof(cfg->client_cert), DEFAULT_CLIENT_CERT);
    (void)copy_string_checked(cfg->client_key, sizeof(cfg->client_key), DEFAULT_CLIENT_KEY);
    (void)copy_string_checked(cfg->ca_file, sizeof(cfg->ca_file), DEFAULT_CA_FILE);
#endif
}

static int md5_file_hex(const char *filepath, char *out_hex)
{
    FILE *fp = NULL;
    unsigned char buf[8192];
    size_t n;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    EVP_MD_CTX ctx;
    EVP_MD_CTX_init(&ctx);
    if (EVP_DigestInit_ex(&ctx, EVP_md5(), NULL) != 1) {
        EVP_MD_CTX_cleanup(&ctx);
        return -1;
    }
#else
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (ctx == NULL) return -1;
    if (EVP_DigestInit_ex(ctx, EVP_md5(), NULL) != 1) {
        EVP_MD_CTX_free(ctx);
        return -1;
    }
#endif

    fp = fopen(filepath, "rb");
    if (fp == NULL) {
#if OPENSSL_VERSION_NUMBER < 0x10100000L
        EVP_MD_CTX_cleanup(&ctx);
#else
        EVP_MD_CTX_free(ctx);
#endif
        return -1;
    }

    while ((n = fread(buf, 1U, sizeof(buf), fp)) > 0U) {
#if OPENSSL_VERSION_NUMBER < 0x10100000L
        if (EVP_DigestUpdate(&ctx, buf, n) != 1) {
            (void)fclose(fp);
            EVP_MD_CTX_cleanup(&ctx);
            return -1;
        }
#else
        if (EVP_DigestUpdate(ctx, buf, n) != 1) {
            (void)fclose(fp);
            EVP_MD_CTX_free(ctx);
            return -1;
        }
#endif
    }

    if (ferror(fp) != 0) {
        (void)fclose(fp);
#if OPENSSL_VERSION_NUMBER < 0x10100000L
        EVP_MD_CTX_cleanup(&ctx);
#else
        EVP_MD_CTX_free(ctx);
#endif
        return -1;
    }
    (void)fclose(fp);

    {
        unsigned char md[MD5_DIGEST_LENGTH];
        unsigned int md_len = 0U;
        static const char hexdig[] = "0123456789abcdef";
        unsigned int i;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
        if (EVP_DigestFinal_ex(&ctx, md, &md_len) != 1) {
            EVP_MD_CTX_cleanup(&ctx);
            return -1;
        }
        EVP_MD_CTX_cleanup(&ctx);
#else
        if (EVP_DigestFinal_ex(ctx, md, &md_len) != 1) {
            EVP_MD_CTX_free(ctx);
            return -1;
        }
        EVP_MD_CTX_free(ctx);
#endif

        if (md_len != MD5_DIGEST_LENGTH) return -1;

        for (i = 0U; i < MD5_DIGEST_LENGTH; ++i) {
            out_hex[i * 2U] = hexdig[(md[i] >> 4) & 0x0FU];
            out_hex[i * 2U + 1U] = hexdig[md[i] & 0x0FU];
        }
        out_hex[32] = '\0';
    }

    return 0;
}

static int sha256_file_hex(const char *filepath, char *out_hex)
{
    FILE *fp = NULL;
    unsigned char buf[8192];
    size_t n;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    EVP_MD_CTX ctx;
    EVP_MD_CTX_init(&ctx);
    if (EVP_DigestInit_ex(&ctx, EVP_sha256(), NULL) != 1) {
        EVP_MD_CTX_cleanup(&ctx);
        return -1;
    }
#else
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (ctx == NULL) return -1;
    if (EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) != 1) {
        EVP_MD_CTX_free(ctx);
        return -1;
    }
#endif

    fp = fopen(filepath, "rb");
    if (fp == NULL) {
#if OPENSSL_VERSION_NUMBER < 0x10100000L
        EVP_MD_CTX_cleanup(&ctx);
#else
        EVP_MD_CTX_free(ctx);
#endif
        return -1;
    }

    while ((n = fread(buf, 1U, sizeof(buf), fp)) > 0U) {
#if OPENSSL_VERSION_NUMBER < 0x10100000L
        if (EVP_DigestUpdate(&ctx, buf, n) != 1) {
            (void)fclose(fp);
            EVP_MD_CTX_cleanup(&ctx);
            return -1;
        }
#else
        if (EVP_DigestUpdate(ctx, buf, n) != 1) {
            (void)fclose(fp);
            EVP_MD_CTX_free(ctx);
            return -1;
        }
#endif
    }

    if (ferror(fp) != 0) {
        (void)fclose(fp);
#if OPENSSL_VERSION_NUMBER < 0x10100000L
        EVP_MD_CTX_cleanup(&ctx);
#else
        EVP_MD_CTX_free(ctx);
#endif
        return -1;
    }
    (void)fclose(fp);

    {
        unsigned char md[EVP_MAX_MD_SIZE];
        unsigned int md_len = 0U;
        static const char hexdig[] = "0123456789abcdef";
        unsigned int i;

#if OPENSSL_VERSION_NUMBER < 0x10100000L
        if (EVP_DigestFinal_ex(&ctx, md, &md_len) != 1) {
            EVP_MD_CTX_cleanup(&ctx);
            return -1;
        }
        EVP_MD_CTX_cleanup(&ctx);
#else
        if (EVP_DigestFinal_ex(ctx, md, &md_len) != 1) {
            EVP_MD_CTX_free(ctx);
            return -1;
        }
        EVP_MD_CTX_free(ctx);
#endif

        if (md_len != 32U) return -1;

        for (i = 0U; i < 32U; ++i) {
            out_hex[i * 2U] = hexdig[(md[i] >> 4) & 0x0FU];
            out_hex[i * 2U + 1U] = hexdig[md[i] & 0x0FU];
        }
        out_hex[64] = '\0';
    }

    return 0;
}

static int validate_token(const char *s)
{
    size_t len;
    if (s == NULL) return 0;
    len = strlen(s);
    if (len < 16U || len > 2048U) return 0;
    if (strncmp(s, "s.", 2U) != 0) return 0;
    return 1;
}

static int validate_dbtype(const char *s)
{
    static const char *valid_types[] = {
        "sybase", "mssql", "oracle", "greenplum",
        "mongodb", "mysql", "postgresql", NULL
    };
    int i;
    if (s == NULL) return 0;
    for (i = 0; valid_types[i] != NULL; ++i) {
        if (strcasecmp(s, valid_types[i]) == 0) return 1;
    }
    return 0;
}

static int validate_dbuser(const char *s)
{
    static const char *valid_users[] = {
        "apusr1", "larry", "gojosatoru_epv",
        "pbusr1_epv", "pbusr2_epv", "pbusr3_epv",
        "pbusr1_epvrt", "pbusr2_epvrt", "pbusr3_epvrt",
        "apusr1_epv", "apusr1_epvrt", NULL
    };
    int i;
    if (s == NULL) return 0;
    for (i = 0; valid_users[i] != NULL; ++i) {
        if (strcasecmp(s, valid_users[i]) == 0) return 1;
    }
    return 0;
}

static int validate_dbname(const char *s)
{
    static const char *valid_dbs[] = {
        "bFUTURES","bFUTURESAH","bOPTIONS","bOPTIONSAH","bFUTURESRT","bOPTIONSRT",
        "bSVEL_MS","bSVEL_MSAH","bFMONIT","bMONIT64","bOMONIT","bSIRS","bSVEL","bTAIFEX2203",
        "CILAB","dgpdb01","dinfadb01","EPV_ASE","EPV_MS","EQDB","MONIT64","OMONIT",
        "FMONIT","FUTURES","FUTURESAH","FUTURESBQ","FUTURESRT",
        "HMONIT","OPTIONS","OPTIONSAH","OPTIONSBQ","OPTIONSRT",
        "PGP-SVEL","SIRS","SIRSAH","SVEL","SVEL_MS","SVEL_MSAH","TAIFEX2203",
        "TAIFEX2203AH","TAIFEX2203RT","TAIFEX_RPT","TAIFEX_RPT_BS",
        "pfdb","pfdb01","pfdb02","podb","podb01","podb02",
        "bfdb","bfdb01","bfdb02","bodb","bodb01","bodb02",
        "pfdba","pfdba1","pfdba2","podba","podba1","podba2",
        "bfdba","bfdba1","bfdba2","bodba","bodba1","bodba2",
        "pmdb","pmdb01","pmdb02","pmdba","pmdba1","pmdba2",
        "bmdb","bmdb01","bmdb02","bmdba","bmdba1","bmdba2",
        "psirsdb","psirsdba","bsirsdb","bsirsdba","peqsrvdb",
        "pgp1","pinfadb01","pinfadb02","binfadb01","binfadb02",
        "tgp1","TRADE_DEV_01","ugp1","vgp1","vinfadb01", NULL
    };
    int i;
    if (s == NULL) return 0;
    for (i = 0; valid_dbs[i] != NULL; ++i) {
        if (strcasecmp(s, valid_dbs[i]) == 0) return 1;
    }
    return 0;
}

static char *trim_ws(char *s)
{
    char *p = s;
    char *end;
    if (s == NULL) return NULL;

    while ((*p == ' ') || (*p == '\t') || (*p == '\r') || (*p == '\n')) {
        ++p;
    }
    if (*p == '\0') return p;

    end = p + strlen(p) - 1U;
    while ((end > p) && ((*end == ' ') || (*end == '\t') || (*end == '\r') || (*end == '\n'))) {
        *end = '\0';
        --end;
    }
    return p;
}

static int load_servers_from_file(const char *filename,
                                  char servers[][MAX_SERVER_LEN],
                                  int max_servers,
                                  int debug)
{
    FILE *fp;
    int count = 0;
    char line[256];

    fp = fopen(filename, "r");
    if (fp == NULL) return 0;

    while ((count < max_servers) && (fgets(line, (int)sizeof(line), fp) != NULL)) {
        char *s = trim_ws(line);
        if ((s == NULL) || (*s == '\0') || (*s == '#')) {
            continue;
        }

        if (copy_string_checked(servers[count], sizeof(servers[count]), s) != 0) {
            if (debug) {
                (void)fprintf(stderr, "[DEBUG] Skipping overlong server entry from %s: %s\n", filename, s);
            }
            continue;
        }
        ++count;
    }

    (void)fclose(fp);
    return count;
}

static int equals_ignore_case(const char *a, const char *b)
{
#ifdef _WIN32
    return (_stricmp(a, b) == 0) ? 1 : 0;
#else
    return (strcasecmp(a, b) == 0) ? 1 : 0;
#endif
}

static int is_ip_literal(const char *host)
{
    struct in_addr a4;
    struct in6_addr a6;
    if (host == NULL) return 0;
    if (inet_pton(AF_INET, host, &a4) == 1) return 1;
    if (inet_pton(AF_INET6, host, &a6) == 1) return 1;
    return 0;
}

static int set_nonblocking(socket_handle_t fd, int enable)
{
#ifdef _WIN32
    u_long mode = (enable != 0) ? 1UL : 0UL;
    return (ioctlsocket(fd, FIONBIO, &mode) == 0) ? 0 : -1;
#else
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (enable != 0) flags |= O_NONBLOCK;
    else flags &= ~O_NONBLOCK;
    return fcntl(fd, F_SETFL, flags);
#endif
}

static int configure_socket_options(socket_handle_t sock, const AppConfig *cfg)
{
    int enable = 1;
#ifdef _WIN32
    DWORD timeout_ms = (DWORD)(cfg->io_timeout_sec * 1000);
    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout_ms, (int)sizeof(timeout_ms)) < 0) {
        if (cfg->debug) (void)fprintf(stderr, "[DEBUG] setsockopt SO_RCVTIMEO failed\n");
        return -1;
    }
    if (setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout_ms, (int)sizeof(timeout_ms)) < 0) {
        if (cfg->debug) (void)fprintf(stderr, "[DEBUG] setsockopt SO_SNDTIMEO failed\n");
        return -1;
    }
#else
    struct timeval tv;
    tv.tv_sec = cfg->io_timeout_sec;
    tv.tv_usec = 0;
    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, (socklen_t)sizeof(tv)) < 0) {
        if (cfg->debug) perror("setsockopt SO_RCVTIMEO");
        return -1;
    }
    if (setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, (socklen_t)sizeof(tv)) < 0) {
        if (cfg->debug) perror("setsockopt SO_SNDTIMEO");
        return -1;
    }
#endif

    if (setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (const char *)&enable, (int)sizeof(enable)) < 0) {
        if (cfg->debug) {
#ifdef _WIN32
            (void)fprintf(stderr, "[DEBUG] setsockopt SO_KEEPALIVE failed\n");
#else
            perror("setsockopt SO_KEEPALIVE");
#endif
        }
        return -1;
    }

#ifdef TCP_NODELAY
    if (setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char *)&enable, (int)sizeof(enable)) < 0) {
        if (cfg->debug) {
#ifdef _WIN32
            (void)fprintf(stderr, "[DEBUG] setsockopt TCP_NODELAY failed\n");
#else
            perror("setsockopt TCP_NODELAY");
#endif
        }
        return -1;
    }
#endif
    return 0;
}

static int connect_with_timeout(socket_handle_t sock,
                                const struct sockaddr *addr,
                                socklen_t addrlen,
                                int timeout_sec)
{
    int rc;
    fd_set wfds;
    struct timeval tv;

    if (set_nonblocking(sock, 1) != 0) return -1;

    rc = connect(sock, addr, addrlen);
    if (rc == 0) {
        (void)set_nonblocking(sock, 0);
        return 0;
    }

#ifdef _WIN32
    {
        int wsae = WSAGetLastError();
        if ((wsae != WSAEWOULDBLOCK) && (wsae != WSAEINPROGRESS) && (wsae != WSAEINVAL)) {
            (void)set_nonblocking(sock, 0);
            return -1;
        }
    }
#else
    if (errno != EINPROGRESS) {
        (void)set_nonblocking(sock, 0);
        return -1;
    }
#endif

    FD_ZERO(&wfds);
    FD_SET(sock, &wfds);
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;

    rc = select((int)(sock + 1), NULL, &wfds, NULL, &tv);
    if (rc <= 0) {
        (void)set_nonblocking(sock, 0);
#ifndef _WIN32
        if (rc == 0) errno = ETIMEDOUT;
#endif
        return -1;
    }

    {
        int so_error = 0;
#ifdef _WIN32
        int so_error_len = (int)sizeof(so_error);
#else
        socklen_t so_error_len = (socklen_t)sizeof(so_error);
#endif
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR, (char *)&so_error, &so_error_len) < 0) {
            (void)set_nonblocking(sock, 0);
            return -1;
        }
        (void)set_nonblocking(sock, 0);
        if (so_error != 0) {
#ifndef _WIN32
            errno = so_error;
#endif
            return -1;
        }
    }

    return 0;
}

static int ssl_send_all(SSL *ssl, const char *buf, size_t len, int debug)
{
    size_t sent = 0U;
    while (sent < len) {
        int w = SSL_write(ssl, buf + sent, (int)(len - sent));
        if (w > 0) {
            sent += (size_t)w;
            continue;
        }

        {
            int err = SSL_get_error(ssl, w);
            if ((err == SSL_ERROR_WANT_READ) || (err == SSL_ERROR_WANT_WRITE)) {
                continue;
            }
            if (debug) {
                (void)fprintf(stderr, "[DEBUG] SSL_write failed: err=%d\n", err);
                ERR_print_errors_fp(stderr);
            }
            return -1;
        }
    }
    return 0;
}

static int ssl_read_response_line(SSL *ssl, char *response, size_t response_size, int debug)
{
    size_t total = 0U;

    if ((response == NULL) || (response_size < 2U)) return -1;
    response[0] = '\0';

    while (total + 1U < response_size) {
        int n = SSL_read(ssl, response + total, (int)(response_size - 1U - total));
        if (n > 0) {
            size_t i;
            total += (size_t)n;
            if (debug) {
                (void)fprintf(stderr, "[DEBUG] Received %d bytes from server (total=%lu)\n",
                              n, (unsigned long)total);
            }
            for (i = total - (size_t)n; i < total; ++i) {
                if (response[i] == '\n') {
                    /* Normalize CRLF to LF while preserving the original CLI newline contract. */
                    if ((i > 0U) && (response[i - 1U] == '\r')) {
                        response[i - 1U] = '\n';
                        response[i] = '\0';
                    } else {
                        response[i + 1U] = '\0';
                    }
                    return 0;
                }
            }
            continue;
        }

        if (n == 0) {
            if (debug) {
                (void)fprintf(stderr, "[DEBUG] SSL connection closed before complete newline-terminated response\n");
            }
            response[0] = '\0';
            return -1;
        }

        {
            int err = SSL_get_error(ssl, n);
            if ((err == SSL_ERROR_WANT_READ) || (err == SSL_ERROR_WANT_WRITE)) {
                continue;
            }
            if (err == SSL_ERROR_ZERO_RETURN) {
                if (debug) {
                    (void)fprintf(stderr, "[DEBUG] TLS close_notify received before complete newline-terminated response\n");
                }
                response[0] = '\0';
                return -1;
            }
            if (debug) {
                (void)fprintf(stderr, "[DEBUG] SSL_read failed: err=%d\n", err);
                ERR_print_errors_fp(stderr);
            }
            response[0] = '\0';
            return -1;
        }
    }

    if (debug) {
        (void)fprintf(stderr, "[DEBUG] Server response exceeded buffer or lacked newline terminator\n");
    }
    response[0] = '\0';
    return -1;
}

static int send_tls_message(const char *server_host,
                            const char *message,
                            char *response,
                            size_t response_size,
                            const AppConfig *cfg)
{
    SSL_CTX *ctx = NULL;
    SSL *ssl = NULL;
    socket_handle_t sock;
    int ret = -1;
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    struct addrinfo *rp;
    int gai_rc;
    char portbuf[16];

#ifdef _WIN32
    sock = INVALID_SOCKET;
#else
    sock = -1;
#endif

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();
#endif

#if OPENSSL_VERSION_NUMBER < 0x10100000L
    ctx = SSL_CTX_new(SSLv23_client_method());
#else
    ctx = SSL_CTX_new(TLS_client_method());
#endif
    if (ctx == NULL) {
        (void)fprintf(stderr, "SSL_CTX_new failed\n");
        goto cleanup;
    }

#if OPENSSL_VERSION_NUMBER >= 0x10101000L && defined(TLS1_2_VERSION)
    if (!SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) && cfg->debug) {
        (void)fprintf(stderr, "[DEBUG] SSL_CTX_set_min_proto_version(TLS1_2) failed\n");
    }
#else
    SSL_CTX_set_options(ctx, SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3
#ifdef SSL_OP_NO_TLSv1
                        | SSL_OP_NO_TLSv1
#endif
#ifdef SSL_OP_NO_TLSv1_1
                        | SSL_OP_NO_TLSv1_1
#endif
    );
#endif

    if ((SSL_CTX_use_certificate_file(ctx, cfg->client_cert, SSL_FILETYPE_PEM) <= 0) ||
        (SSL_CTX_use_PrivateKey_file(ctx, cfg->client_key, SSL_FILETYPE_PEM) <= 0)) {
        (void)fprintf(stderr, "Error loading client cert/key\n");
        ERR_print_errors_fp(stderr);
        goto cleanup;
    }

    if (SSL_CTX_check_private_key(ctx) != 1) {
        (void)fprintf(stderr, "Client private key does not match certificate\n");
        ERR_print_errors_fp(stderr);
        goto cleanup;
    }

    if (cfg->no_verify != 0) {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
        if (cfg->debug) {
            (void)fprintf(stderr, "[DEBUG] verify=0 (certificate validation disabled)\n");
        }
    } else {
        if (!SSL_CTX_load_verify_locations(ctx, cfg->ca_file, NULL)) {
            (void)fprintf(stderr, "Error loading CA file\n");
            ERR_print_errors_fp(stderr);
            goto cleanup;
        }
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        SSL_CTX_set_verify_depth(ctx, 4);
        if (cfg->debug) {
            (void)fprintf(stderr, "[DEBUG] verify=1 (strict certificate validation)\n");
        }
    }

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    (void)snprintf(portbuf, sizeof(portbuf), "%d", SERVER_PORT);

    gai_rc = getaddrinfo(server_host, portbuf, &hints, &res);
    if (gai_rc != 0) {
        if (cfg->debug) {
#ifdef _WIN32
            (void)fprintf(stderr, "[DEBUG] getaddrinfo(%s) failed: %d\n", server_host, gai_rc);
#else
            (void)fprintf(stderr, "[DEBUG] getaddrinfo(%s): %s\n", server_host, gai_strerror(gai_rc));
#endif
        }
        goto cleanup;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        sock = (socket_handle_t)socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
#ifdef _WIN32
        if (sock == INVALID_SOCKET) continue;
#else
        if (sock < 0) continue;
#endif

        if (configure_socket_options(sock, cfg) != 0) {
            (void)close_socket(sock);
#ifdef _WIN32
            sock = INVALID_SOCKET;
#else
            sock = -1;
#endif
            continue;
        }

        if (connect_with_timeout(sock, rp->ai_addr, (socklen_t)rp->ai_addrlen, cfg->connect_timeout_sec) != 0) {
            if (cfg->debug) {
#ifdef _WIN32
                (void)fprintf(stderr, "[DEBUG] connect_with_timeout failed: WSA=%d\n", WSAGetLastError());
#else
                perror("connect_with_timeout");
#endif
            }
            (void)close_socket(sock);
#ifdef _WIN32
            sock = INVALID_SOCKET;
#else
            sock = -1;
#endif
            continue;
        }
        break;
    }

#ifdef _WIN32
    if (sock == INVALID_SOCKET) {
#else
    if (sock < 0) {
#endif
        if (cfg->debug) {
            (void)fprintf(stderr, "[DEBUG] Could not connect to any addr for %s\n", server_host);
        }
        goto cleanup;
    }

    if (cfg->debug) {
        (void)fprintf(stderr, "[DEBUG] Connected to %s:%d\n", server_host, SERVER_PORT);
    }

    ssl = SSL_new(ctx);
    if (ssl == NULL) {
        (void)fprintf(stderr, "SSL_new failed\n");
        goto cleanup;
    }

    SSL_set_fd(ssl, (int)sock);

    if (is_ip_literal(server_host) == 0) {
        (void)SSL_set_tlsext_host_name(ssl, server_host);
    }

    if (cfg->no_verify == 0) {
        X509_VERIFY_PARAM *param = SSL_get0_param(ssl);
        if (param == NULL) {
            (void)fprintf(stderr, "SSL_get0_param failed\n");
            goto cleanup;
        }
        X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);

        if (is_ip_literal(server_host) != 0) {
#if OPENSSL_VERSION_NUMBER >= 0x10002000L
            if (X509_VERIFY_PARAM_set1_ip_asc(param, server_host) != 1) {
                (void)fprintf(stderr, "Failed to set IP verification target\n");
                goto cleanup;
            }
#endif
        } else {
            if (X509_VERIFY_PARAM_set1_host(param, server_host, 0) != 1) {
                (void)fprintf(stderr, "Failed to set hostname verification target\n");
                goto cleanup;
            }
        }
    }

    if (SSL_connect(ssl) <= 0) {
        if (cfg->debug) {
            (void)fprintf(stderr, "SSL_connect failed\n");
            ERR_print_errors_fp(stderr);
        }
        goto cleanup;
    }

    if (cfg->no_verify == 0) {
        long verify_rc = SSL_get_verify_result(ssl);
        if (verify_rc != X509_V_OK) {
            if (cfg->debug) {
                (void)fprintf(stderr, "[DEBUG] Certificate verify failed: %ld\n", verify_rc);
            }
            goto cleanup;
        }
    }

    if (cfg->debug) {
        size_t i;
        size_t msglen = strlen(message);
        (void)fprintf(stderr, "[DEBUG] SSL handshake successful\n");
        (void)fprintf(stderr, "[DEBUG] Cipher: %s\n", SSL_get_cipher(ssl));
        (void)fprintf(stderr, "[DEBUG] Sending (%lu bytes): ", (unsigned long)msglen);
        for (i = 0U; i < msglen; ++i) {
            unsigned char c = (unsigned char)message[i];
            if ((c != (unsigned char)'\r') && (c != (unsigned char)'\n')) {
                (void)fputc((int)c, stderr);
            }
        }
        (void)fputc('\n', stderr);
        (void)fflush(stderr);
    }

    if (ssl_send_all(ssl, message, strlen(message), cfg->debug) != 0) goto cleanup;
    if (ssl_read_response_line(ssl, response, response_size, cfg->debug) != 0) goto cleanup;

    ret = 0;

cleanup:
    if (ssl != NULL) {
        int shutdown_rc = SSL_shutdown(ssl);
        if (shutdown_rc == 0) (void)SSL_shutdown(ssl);
        SSL_free(ssl);
    }
#ifdef _WIN32
    if (sock != INVALID_SOCKET) (void)close_socket(sock);
#else
    if (sock >= 0) (void)close_socket(sock);
#endif
    if (ctx != NULL) SSL_CTX_free(ctx);
    if (res != NULL) freeaddrinfo(res);
    return ret;
}

static int server_already_tried(char tried[][MAX_SERVER_LEN], int tried_count, const char *server)
{
    int i;
    for (i = 0; i < tried_count; ++i) {
        if (equals_ignore_case(tried[i], server) != 0) return 1;
    }
    return 0;
}

static void mark_server_tried(char tried[][MAX_SERVER_LEN], int *tried_count, const char *server)
{
    if ((tried_count == NULL) || (server == NULL)) return;
    if (*tried_count >= MAX_TRIED_SERVERS) return;
    if (copy_string_checked(tried[*tried_count], sizeof(tried[*tried_count]), server) != 0) return;
    (*tried_count)++;
}

#ifdef _WIN32
static int verify_parent_matches_for_windows(const char *app_path, int debug)
{
    DWORD ppid = 0;
    HANDLE hProcessSnap = INVALID_HANDLE_VALUE;
    PROCESSENTRY32 pe32;
    HANDLE hParent = NULL;
    char parentPath[MAX_PATH];
    char app_sha256[65];
    char parent_sha256[65];

    memset(parentPath, 0, sizeof(parentPath));
    memset(app_sha256, 0, sizeof(app_sha256));
    memset(parent_sha256, 0, sizeof(parent_sha256));

    hProcessSnap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (hProcessSnap == INVALID_HANDLE_VALUE) {
        if (debug) (void)fprintf(stderr, "[DEBUG] CreateToolhelp32Snapshot failed\n");
        return -1;
    }

    pe32.dwSize = sizeof(PROCESSENTRY32);
    if (!Process32First(hProcessSnap, &pe32)) {
        CloseHandle(hProcessSnap);
        return -1;
    }

    {
        DWORD current_pid = GetCurrentProcessId();
        do {
            if (pe32.th32ProcessID == current_pid) {
                ppid = pe32.th32ParentProcessID;
                break;
            }
        } while (Process32Next(hProcessSnap, &pe32));
    }

    CloseHandle(hProcessSnap);

    if (ppid == 0U) {
        if (debug) (void)fprintf(stderr, "[DEBUG] Cannot find parent process\n");
        return -1;
    }

    hParent = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, ppid);
    if (hParent == NULL) {
        if (debug) (void)fprintf(stderr, "[DEBUG] OpenProcess(%lu) failed\n", (unsigned long)ppid);
        return -1;
    }

    if (GetModuleFileNameExA(hParent, NULL, parentPath, MAX_PATH) == 0U) {
        if (debug) (void)fprintf(stderr, "[DEBUG] GetModuleFileNameExA failed\n");
        CloseHandle(hParent);
        return -1;
    }
    CloseHandle(hParent);

    if (debug) (void)fprintf(stderr, "[DEBUG] Parent exe: %s\n", parentPath);

    (void)sha256_file_hex(app_path, app_sha256);
    (void)sha256_file_hex(parentPath, parent_sha256);

    if (_stricmp(parentPath, app_path) == 0) return 0;
    if ((app_sha256[0] != '\0') && (strcmp(parent_sha256, app_sha256) == 0)) return 0;

    if (debug) (void)fprintf(stderr, "[DEBUG] Parent process does NOT match\n");
    return -1;
}
#else
static pid_t get_parent_pid_of(pid_t pid)
{
    char path[64];
    FILE *fp;
    char line[512];
    pid_t ppid = -1;

    (void)snprintf(path, sizeof(path), "/proc/%d/status", (int)pid);
    fp = fopen(path, "r");
    if (fp == NULL) return -1;

    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        if (strncmp(line, "PPid:", 5U) == 0) {
            char *p = line + 5;
            while ((*p == ' ') || (*p == '\t')) ++p;
            ppid = (pid_t)strtol(p, NULL, 10);
            break;
        }
    }

    (void)fclose(fp);
    return ppid;
}

static int check_one_linux_ancestor(pid_t pid, const char *app_path, int debug)
{
    char proc_exe_path[PATH_MAX + 1];
    char proc_cmdline_path[4096];
    char real_app[PATH_MAX + 1];
    char tmp_copy[PATH_MAX + 1];
    char *app_basename = NULL;
    char app_sha256[65];

    memset(proc_exe_path, 0, sizeof(proc_exe_path));
    memset(proc_cmdline_path, 0, sizeof(proc_cmdline_path));
    memset(real_app, 0, sizeof(real_app));
    memset(tmp_copy, 0, sizeof(tmp_copy));
    memset(app_sha256, 0, sizeof(app_sha256));

    if (sha256_file_hex(app_path, app_sha256) != 0) {
        if (debug) (void)fprintf(stderr, "[DEBUG] sha256_file_hex failed for %s\n", app_path);
        app_sha256[0] = '\0';
    }

    if (realpath(app_path, real_app) == NULL) {
        (void)snprintf(real_app, sizeof(real_app), "%s", app_path);
    }

    {
        char exe_link[64];
        ssize_t r;
        (void)snprintf(exe_link, sizeof(exe_link), "/proc/%d/exe", (int)pid);
        r = readlink(exe_link, proc_exe_path, sizeof(proc_exe_path) - 1U);
        if (r > 0) proc_exe_path[r] = '\0';
    }

    {
        char cmdline_file[64];
        FILE *f;
        (void)snprintf(cmdline_file, sizeof(cmdline_file), "/proc/%d/cmdline", (int)pid);
        f = fopen(cmdline_file, "rb");
        if (f != NULL) {
            size_t n = fread(proc_cmdline_path, 1U, sizeof(proc_cmdline_path) - 1U, f);
            (void)fclose(f);
            if (n > 0U) proc_cmdline_path[n] = '\0';
        }
    }

    if (debug) {
        (void)fprintf(stderr, "[DEBUG] checking ancestor pid=%d exe=%s\n",
                      (int)pid,
                      (proc_exe_path[0] != '\0') ? proc_exe_path : "(none)");
    }

    if (proc_exe_path[0] != '\0') {
        char real_parent_exe[PATH_MAX + 1];
        char parent_sha256[65];
        memset(real_parent_exe, 0, sizeof(real_parent_exe));
        memset(parent_sha256, 0, sizeof(parent_sha256));

        if (realpath(proc_exe_path, real_parent_exe) != NULL) {
            if (strcmp(real_parent_exe, real_app) == 0) return 0;
            if ((sha256_file_hex(real_parent_exe, parent_sha256) == 0) &&
                (app_sha256[0] != '\0') &&
                (strcmp(parent_sha256, app_sha256) == 0)) return 0;
        } else if (strcmp(proc_exe_path, app_path) == 0) {
            return 0;
        }
    }

    if (proc_cmdline_path[0] != '\0') {
        const char *p;
        (void)snprintf(tmp_copy, sizeof(tmp_copy), "%s", real_app);
        app_basename = basename(tmp_copy);

        p = proc_cmdline_path;
        while (*p != '\0') {
            size_t arglen = strlen(p);
            char arg_sha256[65];
            memset(arg_sha256, 0, sizeof(arg_sha256));

            if (arglen > 0U) {
                if ((strcmp(p, app_path) == 0) ||
                    (strcmp(p, real_app) == 0) ||
                    ((app_basename != NULL) && (strcmp(p, app_basename) == 0))) {
                    return 0;
                }

                if ((sha256_file_hex(p, arg_sha256) == 0) &&
                    (app_sha256[0] != '\0') &&
                    (strcmp(arg_sha256, app_sha256) == 0)) {
                    return 0;
                }
            }
            p += arglen + 1U;
        }
    }

    return -1;
}

static int verify_parent_matches_for_linux(const char *app_path, int debug)
{
    pid_t pid = getppid();
    int depth;

    for (depth = 0; (depth < MAX_ANCESTOR_DEPTH) && (pid > 1); ++depth) {
        if (check_one_linux_ancestor(pid, app_path, debug) == 0) {
            if (debug) {
                (void)fprintf(stderr, "[DEBUG] matched ancestor pid=%d depth=%d\n", (int)pid, depth);
            }
            return 0;
        }
        pid = get_parent_pid_of(pid);
    }

    if (debug) {
        (void)fprintf(stderr, "[DEBUG] no matching ancestor found for AppFilePath: %s\n", app_path);
    }
    return -1;
}
#endif

static int verify_parent_matches(const char *app_path, int debug)
{
#ifdef _WIN32
    return verify_parent_matches_for_windows(app_path, debug);
#else
    return verify_parent_matches_for_linux(app_path, debug);
#endif
}

static int try_server_with_retries(const char *server,
                                   const char *message,
                                   char *response,
                                   size_t response_size,
                                   const AppConfig *cfg)
{
    int attempt;

    for (attempt = 0; attempt < cfg->retries_per_server; ++attempt) {
        if (cfg->debug) {
            (void)fprintf(stderr, "[DEBUG] Attempt %d/%d for server %s\n",
                          attempt + 1, cfg->retries_per_server, server);
        }

        if (send_tls_message(server, message, response, response_size, cfg) == 0) {
            return 0;
        }

        if (attempt + 1 < cfg->retries_per_server) {
            unsigned int backoff = cfg->retry_backoff_ms * (unsigned int)(attempt + 1);
            msleep_unsigned(backoff);
        }
    }

    return -1;
}

static int discover_token_origin(const char *token,
                                 char *server_out,
                                 size_t server_out_size,
                                 const AppConfig *cfg)
{
    char probe[MAX_MESSAGE_LEN];
    char response[MAX_RESPONSE_LEN];
    char tried_local[MAX_TRIED_SERVERS][MAX_SERVER_LEN];
    int tried_local_count = 0;

    if (!token || !server_out || server_out_size == 0U || !cfg) return 0;
    if (snprintf(probe, sizeof(probe), "__EPV2_OWNER__ %s\n", token) >= (int)sizeof(probe)) return 0;
    memset(tried_local, 0, sizeof(tried_local));

    {
        char servers[MAX_SERVERS][MAX_SERVER_LEN];
        int count;
        memset(servers, 0, sizeof(servers));
        count = load_servers_from_file(cfg->server_file, servers, MAX_SERVERS, cfg->debug);
        for (int i = 0; i < count; ++i) {
            if (server_already_tried(tried_local, tried_local_count, servers[i]) != 0) continue;
            mark_server_tried(tried_local, &tried_local_count, servers[i]);
            memset(response, 0, sizeof(response));
            if (cfg->debug) (void)fprintf(stderr, "[DEBUG] Probing token owner at %s...\n", servers[i]);
            if (try_server_with_retries(servers[i], probe, response, sizeof(response), cfg) == 0 &&
                strncmp(response, "owner ", 6U) == 0) {
                if (copy_string_checked(server_out, server_out_size, servers[i]) == 0) return 1;
                return 0;
            }
        }
    }

    {
        const char *const *bp;
        for (bp = builtin_servers; *bp != NULL; ++bp) {
            if (server_already_tried(tried_local, tried_local_count, *bp) != 0) continue;
            mark_server_tried(tried_local, &tried_local_count, *bp);
            memset(response, 0, sizeof(response));
            if (cfg->debug) (void)fprintf(stderr, "[DEBUG] Probing token owner at builtin %s...\n", *bp);
            if (try_server_with_retries(*bp, probe, response, sizeof(response), cfg) == 0 &&
                strncmp(response, "owner ", 6U) == 0) {
                if (copy_string_checked(server_out, server_out_size, *bp) == 0) return 1;
                return 0;
            }
        }
    }

    return 0;
}

static int response_is_nonactive(const char *response)
{
    if (response == NULL) return 0;
    if (strncmp(response, "error: standby", 14U) == 0) return 1;
    if (strncmp(response, "error: maintenance", 18U) == 0) return 1;
    if (strstr(response, " role=STANDBY") != NULL) return 1;
    if (strstr(response, " role=MAINTENANCE") != NULL) return 1;
    return 0;
}

static int append_server_unique(char servers[][MAX_SERVER_LEN], int count, int max_servers, const char *server)
{
    int i;
    if (server == NULL || *server == '\0' || count >= max_servers) return count;
    for (i = 0; i < count; ++i) {
        if (equals_ignore_case(servers[i], server) != 0) return count;
    }
    if (copy_string_checked(servers[count], sizeof(servers[count]), server) != 0) return count;
    return count + 1;
}

static int build_ordered_servers(const AppConfig *cfg, char servers[][MAX_SERVER_LEN], int max_servers)
{
    char external[MAX_SERVERS][MAX_SERVER_LEN];
    int ext_count;
    int count = 0;
    const char *const *p;

    memset(external, 0, sizeof(external));
    ext_count = load_servers_from_file(cfg->server_file, external, MAX_SERVERS, cfg->debug);
    for (int i = 0; i < ext_count && count < max_servers; ++i) {
        count = append_server_unique(servers, count, max_servers, external[i]);
    }
    for (p = builtin_servers; *p != NULL && count < max_servers; ++p) {
        count = append_server_unique(servers, count, max_servers, *p);
    }
    return count;
}

static int server_rank(char servers[][MAX_SERVER_LEN], int count, const char *server)
{
    for (int i = 0; i < count; ++i) {
        if (equals_ignore_case(servers[i], server) != 0) return i;
    }
    return -1;
}

#ifndef _WIN32
static int priority_cache_path(char *path, size_t path_size)
{
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    struct stat st;
    int n;
    if (xdg != NULL && *xdg != '\0' && stat(xdg, &st) == 0 && S_ISDIR(st.st_mode) &&
        st.st_uid == geteuid() && access(xdg, W_OK) == 0) {
        n = snprintf(path, path_size, "%s/epv_api_active_server.cache", xdg);
    } else {
        n = snprintf(path, path_size, "/tmp/epv_api_active_server_%lu.cache", (unsigned long)geteuid());
    }
    return (n > 0 && (size_t)n < path_size) ? 0 : -1;
}

static int priority_cache_open_secure(const char *path, int debug)
{
    int fd;
    struct stat st;

    if (path == NULL || *path == '\0') return -1;
    fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        if (debug) perror("priority cache open");
        return -1;
    }
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid()) {
        if (debug) (void)fprintf(stderr, "[DEBUG] priority cache rejected: not a regular file owned by current uid\n");
        close(fd);
        return -1;
    }
    if (fchmod(fd, 0600) != 0 && debug) perror("priority cache chmod");
    return fd;
}

static int priority_cache_write_locked(int fd, time_t next_recheck, const char *server)
{
    char line[256];
    int n = snprintf(line, sizeof(line), "%ld %s\n", (long)next_recheck, server ? server : "");
    if (n <= 0 || (size_t)n >= sizeof(line)) return -1;
    if (ftruncate(fd, 0) != 0 || lseek(fd, 0, SEEK_SET) < 0) return -1;
    if (write(fd, line, (size_t)n) != (ssize_t)n) return -1;
    return 0;
}

/*
 * Return 1 when a recently-working lower-priority node should be tried first.
 * When its recovery recheck is due, atomically lease the recheck window so only
 * one concurrent CLI invocation probes higher-priority nodes.
 */
static int priority_cache_plan(char servers[][MAX_SERVER_LEN], int count,
                               int recheck_sec, char *cached, size_t cached_size,
                               int debug)
{
    char path[MAX_PATH_BUF];
    char line[256] = {0};
    long next_recheck = 0;
    char server[MAX_SERVER_LEN] = {0};
    time_t now = time(NULL);
    int fd;
    ssize_t nr;
    int rank;

    if (recheck_sec <= 0 || count <= 0 || priority_cache_path(path, sizeof(path)) != 0) return 0;
    fd = priority_cache_open_secure(path, debug);
    if (fd < 0) return 0;
    if (flock(fd, LOCK_EX) != 0) { close(fd); return 0; }
    nr = read(fd, line, sizeof(line) - 1U);
    if (nr > 0) line[nr] = '\0';
    if (sscanf(line, "%ld %127s", &next_recheck, server) != 2) {
        (void)flock(fd, LOCK_UN); close(fd); return 0;
    }
    rank = server_rank(servers, count, server);
    if (rank < 0) {
        if (ftruncate(fd, 0) != 0 && debug) perror("priority cache truncate");
        (void)flock(fd, LOCK_UN); close(fd); return 0;
    }
    if (rank == 0 || now < (time_t)next_recheck) {
        int ok = (copy_string_checked(cached, cached_size, server) == 0) ? 1 : 0;
        (void)flock(fd, LOCK_UN); close(fd);
        if (ok && debug) fprintf(stderr, "[DEBUG] priority cache selects %s rank=%d next_recheck=%ld\n", server, rank, next_recheck);
        return ok;
    }
    /* Lease the recovery probe now. Other concurrent clients keep using cached standby. */
    (void)priority_cache_write_locked(fd, now + (time_t)recheck_sec, server);
    (void)flock(fd, LOCK_UN); close(fd);
    if (debug) fprintf(stderr, "[DEBUG] priority recovery recheck due; probing top-down above cached server %s\n", server);
    return 0;
}

static void priority_cache_store(const char *server, int recheck_sec, int debug)
{
    char path[MAX_PATH_BUF];
    int fd;
    time_t now;
    if (server == NULL || *server == '\0' || recheck_sec <= 0 || priority_cache_path(path, sizeof(path)) != 0) return;
    fd = priority_cache_open_secure(path, debug);
    if (fd < 0) return;
    if (flock(fd, LOCK_EX) != 0) { close(fd); return; }
    now = time(NULL);
    (void)priority_cache_write_locked(fd, now + (time_t)recheck_sec, server);
    (void)flock(fd, LOCK_UN);
    close(fd);
    if (debug) fprintf(stderr, "[DEBUG] active server cached=%s recheck_in=%d sec\n", server, recheck_sec);
}
#else
static int priority_cache_plan(char servers[][MAX_SERVER_LEN], int count,
                               int recheck_sec, char *cached, size_t cached_size,
                               int debug)
{
    (void)servers; (void)count; (void)recheck_sec; (void)cached; (void)cached_size; (void)debug;
    return 0;
}
static void priority_cache_store(const char *server, int recheck_sec, int debug)
{
    (void)server; (void)recheck_sec; (void)debug;
}
#endif

static int json_escape_string(const char *src, char *dst, size_t dst_size)
{
    size_t si = 0U;
    size_t di = 0U;

    if ((src == NULL) || (dst == NULL) || (dst_size == 0U)) return -1;

    while (src[si] != '\0') {
        unsigned char c = (unsigned char)src[si];
        const char *rep = NULL;
        char tmp[7];

        switch (c) {
            case '\"': rep = "\\\""; break;
            case '\\': rep = "\\\\"; break;
            case '\b': rep = "\\b"; break;
            case '\f': rep = "\\f"; break;
            case '\n': rep = "\\n"; break;
            case '\r': rep = "\\r"; break;
            case '\t': rep = "\\t"; break;
            default:
                if (c < 0x20U) {
                    (void)snprintf(tmp, sizeof(tmp), "\\u%04x", (unsigned int)c);
                    rep = tmp;
                }
                break;
        }

        if (rep != NULL) {
            size_t rl = strlen(rep);
            if (di + rl + 1U > dst_size) return -1;
            memcpy(dst + di, rep, rl);
            di += rl;
        } else {
            if (di + 2U > dst_size) return -1;
            dst[di++] = (char)c;
        }
        ++si;
    }

    if (di >= dst_size) return -1;
    dst[di] = '\0';
    return 0;
}

static void print_result(const AppConfig *cfg,
                         ExitCode code,
                         const char *status,
                         const char *message,
                         const char *server)
{
    if (cfg->json_output == 0) {
        if (message != NULL) {
            (void)printf("%s", message);
        }
        return;
    }

    {
        char esc_msg[MAX_JSON_ESCAPED];
        char esc_server[MAX_SERVER_LEN * 2];
        char esc_status[64];

        if ((json_escape_string(message != NULL ? message : "", esc_msg, sizeof(esc_msg)) != 0) ||
            (json_escape_string(server != NULL ? server : "", esc_server, sizeof(esc_server)) != 0) ||
            (json_escape_string(status != NULL ? status : "", esc_status, sizeof(esc_status)) != 0)) {
            (void)printf("{\"ok\":false,\"code\":%d,\"status\":\"json_error\",\"message\":\"json escape failed\"}\n",
                         (int)code);
            return;
        }

        (void)printf("{\"ok\":%s,\"code\":%d,\"status\":\"%s\",\"server\":\"%s\",\"message\":\"%s\"}\n",
                     (code == EXIT_OK) ? "true" : "false",
                     (int)code,
                     esc_status,
                     esc_server,
                     esc_msg);
    }
}

#ifdef _WIN32
static int platform_init(void)
{
    WSADATA wsa_data;
    return (WSAStartup(MAKEWORD(2, 2), &wsa_data) == 0) ? 0 : -1;
}

static void platform_cleanup(void)
{
    WSACleanup();
}
#else
static int platform_init(void)
{
    (void)signal(SIGPIPE, SIG_IGN);
    return 0;
}

static void platform_cleanup(void)
{
}
#endif

int main(int argc, char *argv[])
{
    char message[MAX_MESSAGE_LEN];
    char response[MAX_RESPONSE_LEN];
    char chosen_server[MAX_SERVER_LEN];
    char tried[MAX_TRIED_SERVERS][MAX_SERVER_LEN];
    AppConfig cfg;
    int is_ad_mode = 0;
    int health_mode = 0;
    int i;
    int j;
    RunMode mode = MODE_UNKNOWN;
    int success = 0;
    int tried_count = 0;
    ExitCode exit_code = EXIT_OK;

    init_config(&cfg);
    memset(message, 0, sizeof(message));
    memset(response, 0, sizeof(response));
    memset(chosen_server, 0, sizeof(chosen_server));
    memset(tried, 0, sizeof(tried));

    if (platform_init() != 0) {
        (void)fprintf(stderr, "Platform initialization failed\n");
        return (int)EXIT_CONFIG;
    }

    for (i = 1; i < argc; ) {
        if (strcmp(argv[i], "--verify") == 0) {
            cfg.no_verify = 0;
            for (j = i; j < argc - 1; ++j) argv[j] = argv[j + 1];
            --argc;
        } else if (strcmp(argv[i], "--insecure") == 0) {
            cfg.no_verify = 1;
            for (j = i; j < argc - 1; ++j) argv[j] = argv[j + 1];
            --argc;
        } else if (strcmp(argv[i], "--debug") == 0) {
            cfg.debug = 1;
            for (j = i; j < argc - 1; ++j) argv[j] = argv[j + 1];
            --argc;
        } else if (strcmp(argv[i], "--json") == 0) {
            cfg.json_output = 1;
            for (j = i; j < argc - 1; ++j) argv[j] = argv[j + 1];
            --argc;
        } else if (strcmp(argv[i], "--ad") == 0) {
            is_ad_mode = 1;
            for (j = i; j < argc - 1; ++j) argv[j] = argv[j + 1];
            --argc;
        } else if (strcmp(argv[i], "--health") == 0) {
            health_mode = 1;
            for (j = i; j < argc - 1; ++j) argv[j] = argv[j + 1];
            --argc;
        } else if (strcmp(argv[i], "--token-affinity") == 0) {
            if ((i + 1 >= argc) || parse_token_affinity(argv[i + 1], &cfg.token_affinity) != 0) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--priority-recheck") == 0) {
            if ((i + 1 >= argc) ||
                (parse_nonnegative_int(argv[i + 1], MAX_PRIORITY_RECHECK_SEC, &cfg.priority_recheck_sec) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--retries") == 0) {
            if ((i + 1 >= argc) ||
                (parse_positive_int(argv[i + 1], MIN_RETRIES, MAX_RETRIES, &cfg.retries_per_server) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--connect-timeout") == 0) {
            if ((i + 1 >= argc) ||
                (parse_positive_int(argv[i + 1], MIN_TIMEOUT_SEC, MAX_TIMEOUT_SEC, &cfg.connect_timeout_sec) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--io-timeout") == 0) {
            if ((i + 1 >= argc) ||
                (parse_positive_int(argv[i + 1], MIN_TIMEOUT_SEC, MAX_TIMEOUT_SEC, &cfg.io_timeout_sec) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--server-file") == 0) {
            if ((i + 1 >= argc) ||
                (copy_string_checked(cfg.server_file, sizeof(cfg.server_file), argv[i + 1]) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--client-cert") == 0) {
            if ((i + 1 >= argc) ||
                (copy_string_checked(cfg.client_cert, sizeof(cfg.client_cert), argv[i + 1]) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--client-key") == 0) {
            if ((i + 1 >= argc) ||
                (copy_string_checked(cfg.client_key, sizeof(cfg.client_key), argv[i + 1]) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else if (strcmp(argv[i], "--ca-file") == 0) {
            if ((i + 1 >= argc) ||
                (copy_string_checked(cfg.ca_file, sizeof(cfg.ca_file), argv[i + 1]) != 0)) {
                print_usage(MODE_UNKNOWN);
                platform_cleanup();
                return (int)EXIT_USAGE;
            }
            for (j = i; j < argc - 2; ++j) argv[j] = argv[j + 2];
            argc -= 2;
        } else {
            ++i;
        }
    }

    if ((health_mode == 0) && (argc < 3)) {
        print_usage(MODE_UNKNOWN);
        exit_code = EXIT_USAGE;
        print_result(&cfg, exit_code, "usage_error", "invalid arguments", "");
        goto out;
    }

    if (health_mode != 0) {
        mode = MODE_HEALTH;
    } else if (is_ad_mode != 0) {
        mode = MODE_AD;
    } else if (argc == 3) {
        int first_is_file =
#ifdef _WIN32
            (_access(argv[1], 0) == 0) ? 1 : 0;
#else
            (access(argv[1], F_OK) == 0) ? 1 : 0;
#endif

        if (first_is_file != 0) {
            if ((strcmp(argv[2], "--md5") == 0) ||
                (equals_ignore_case(argv[2], "AUTO") != 0) ||
                (strcmp(argv[2], "-") == 0)) {
                mode = MODE_APP_MD5;
            } else if (strcmp(argv[2], "--sha256") == 0) {
                mode = MODE_APP_SHA256;
            } else if ((is_hex_n(argv[2], 32) != 0) || (is_hex_n(argv[2], 64) != 0)) {
                mode = MODE_APP_CHECKSUM;
            } else {
                mode = MODE_AD;
            }
        } else {
            mode = MODE_AD;
        }
    } else if (argc == 5) {
        mode = MODE_DB;
    } else {
        mode = MODE_UNKNOWN;
    }

    if (cfg.debug) {
        switch (mode) {
            case MODE_AD: (void)fprintf(stderr, "[DEBUG] Detected mode: AD-User + AD-Password\n"); break;
            case MODE_APP_MD5: (void)fprintf(stderr, "[DEBUG] Detected mode: AppFilePath + MD5(auto)\n"); break;
            case MODE_APP_SHA256: (void)fprintf(stderr, "[DEBUG] Detected mode: AppFilePath + SHA256\n"); break;
            case MODE_APP_CHECKSUM: (void)fprintf(stderr, "[DEBUG] Detected mode: AppFilePath + checksum(32|64)\n"); break;
            case MODE_DB: (void)fprintf(stderr, "[DEBUG] Detected mode: DB Login token_affinity=%s\n", token_affinity_name(cfg.token_affinity)); break;
            case MODE_HEALTH: (void)fprintf(stderr, "[DEBUG] Detected mode: HEALTH\n"); break;
            default: (void)fprintf(stderr, "[DEBUG] Detected mode: UNKNOWN\n"); break;
        }
    }

    switch (mode) {
        case MODE_AD:
            if (snprintf(message, sizeof(message), "%s %s\n", argv[1], argv[2]) >= (int)sizeof(message)) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "request_too_long", "request too long", "");
                goto out;
            }
            break;

        case MODE_APP_MD5:
        {
            if (verify_parent_matches(argv[1], cfg.debug) != 0) {
                exit_code = EXIT_SECURITY;
                print_result(&cfg, exit_code, "security_error",
                             "parent process does not match AppFilePath", "");
                goto out;
            }

            {
                char md5hex[33];
                memset(md5hex, 0, sizeof(md5hex));
                if (md5_file_hex(argv[1], md5hex) != 0) {
                    exit_code = EXIT_IO;
                    print_result(&cfg, exit_code, "md5_error", "md5 calculation failed", "");
                    goto out;
                }
                if (snprintf(message, sizeof(message), "%s %s\n", argv[1], md5hex) >= (int)sizeof(message)) {
                    exit_code = EXIT_USAGE;
                    print_result(&cfg, exit_code, "request_too_long", "request too long", "");
                    secure_bzero(md5hex, sizeof(md5hex));
                    goto out;
                }
                secure_bzero(md5hex, sizeof(md5hex));
            }
            break;
        }

        case MODE_APP_SHA256:
        {
            if (verify_parent_matches(argv[1], cfg.debug) != 0) {
                exit_code = EXIT_SECURITY;
                print_result(&cfg, exit_code, "security_error",
                             "parent process does not match AppFilePath", "");
                goto out;
            }

            {
                char sha256hex[65];
                memset(sha256hex, 0, sizeof(sha256hex));
                if (sha256_file_hex(argv[1], sha256hex) != 0) {
                    exit_code = EXIT_IO;
                    print_result(&cfg, exit_code, "sha256_error", "sha256 calculation failed", "");
                    goto out;
                }
                if (snprintf(message, sizeof(message), "%s %s\n", argv[1], sha256hex) >= (int)sizeof(message)) {
                    exit_code = EXIT_USAGE;
                    print_result(&cfg, exit_code, "request_too_long", "request too long", "");
                    secure_bzero(sha256hex, sizeof(sha256hex));
                    goto out;
                }
                secure_bzero(sha256hex, sizeof(sha256hex));
            }
            break;
        }

        case MODE_APP_CHECKSUM:
            if (verify_parent_matches(argv[1], cfg.debug) != 0) {
                exit_code = EXIT_SECURITY;
                print_result(&cfg, exit_code, "security_error",
                             "parent process does not match AppFilePath", "");
                goto out;
            }

            if ((is_hex_n(argv[2], 32) == 0) && (is_hex_n(argv[2], 64) == 0)) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "checksum_error",
                             "checksum must be 32-hex MD5 or 64-hex SHA256", "");
                goto out;
            }

            if (snprintf(message, sizeof(message), "%s %s\n", argv[1], argv[2]) >= (int)sizeof(message)) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "request_too_long", "request too long", "");
                goto out;
            }
            break;

        case MODE_HEALTH:
            if (snprintf(message, sizeof(message), "HEALTH\n") >= (int)sizeof(message)) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "request_too_long", "request too long", "");
                goto out;
            }
            break;

        case MODE_DB:
            if (validate_token(argv[1]) == 0) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "token_error", "invalid token", "");
                goto out;
            }
            if (validate_dbtype(argv[2]) == 0) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "dbtype_error", "invalid dbtype", "");
                goto out;
            }
            if (validate_dbuser(argv[3]) == 0) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "dbuser_error", "invalid dbuser", "");
                goto out;
            }
            if (validate_dbname(argv[4]) == 0) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "dbname_error", "invalid dbname", "");
                goto out;
            }

            if (snprintf(message, sizeof(message), "%s %s %s %s\n",
                         argv[1], argv[2], argv[3], argv[4]) >= (int)sizeof(message)) {
                exit_code = EXIT_USAGE;
                print_result(&cfg, exit_code, "request_too_long", "request too long", "");
                goto out;
            }
            break;

        default:
            exit_code = EXIT_USAGE;
            print_result(&cfg, exit_code, "usage_error", "unknown mode", "");
            goto out;
    }

    if ((mode == MODE_DB) && (cfg.token_affinity != TOKEN_AFFINITY_OFF)) {
        char pinned_server[MAX_SERVER_LEN];
        int have_origin = 0;
        memset(pinned_server, 0, sizeof(pinned_server));

        have_origin = token_origin_lookup(argv[1], pinned_server, sizeof(pinned_server), cfg.debug);
        if (!have_origin) {
            if (cfg.debug) (void)fprintf(stderr, "[DEBUG] Local token-origin cache miss; probing connectors...\n");
            have_origin = discover_token_origin(argv[1], pinned_server, sizeof(pinned_server), &cfg);
            if (have_origin) {
                (void)token_origin_store(argv[1], pinned_server, cfg.debug);
                if (cfg.debug) (void)fprintf(stderr, "[DEBUG] Token owner discovered server=%s\n", pinned_server);
            }
        }

        if (have_origin) {
            if (server_already_tried(tried, tried_count, pinned_server) == 0) {
                if (cfg.debug) (void)fprintf(stderr, "[DEBUG] Trying token-origin server %s first...\n", pinned_server);
                mark_server_tried(tried, &tried_count, pinned_server);
                if (try_server_with_retries(pinned_server, message, response, sizeof(response), &cfg) == 0) {
                    success = 1;
                    (void)copy_string_checked(chosen_server, sizeof(chosen_server), pinned_server);
                } else if (cfg.token_affinity == TOKEN_AFFINITY_STRICT) {
                    exit_code = EXIT_CONNECT;
                    print_result(&cfg, exit_code, "token_origin_unavailable", "token issuing server unavailable", pinned_server);
                    goto out;
                }
            }
        } else if (cfg.token_affinity == TOKEN_AFFINITY_STRICT) {
            exit_code = EXIT_SECURITY;
            print_result(&cfg, exit_code, "token_origin_unknown", "token issuing server could not be discovered", "");
            goto out;
        }
    }


    if (success == 0) {
        char ordered[MAX_TRIED_SERVERS][MAX_SERVER_LEN];
        char cached_server[MAX_SERVER_LEN];
        int ordered_count;
        int use_cached;

        memset(ordered, 0, sizeof(ordered));
        memset(cached_server, 0, sizeof(cached_server));
        ordered_count = build_ordered_servers(&cfg, ordered, MAX_TRIED_SERVERS);
        use_cached = (mode == MODE_HEALTH) ? 0 :
                     priority_cache_plan(ordered, ordered_count, cfg.priority_recheck_sec,
                                         cached_server, sizeof(cached_server), cfg.debug);

        if (use_cached && server_already_tried(tried, tried_count, cached_server) == 0) {
            memset(response, 0, sizeof(response));
            if (cfg.debug) (void)fprintf(stderr, "[DEBUG] Trying cached active server %s first...\n", cached_server);
            mark_server_tried(tried, &tried_count, cached_server);
            if (try_server_with_retries(cached_server, message, response, sizeof(response), &cfg) == 0) {
                if (mode != MODE_HEALTH && response_is_nonactive(response)) {
                    if (cfg.debug) (void)fprintf(stderr, "[DEBUG] Cached server %s reports non-active state; falling back by priority\n", cached_server);
                    memset(response, 0, sizeof(response));
                } else {
                    success = 1;
                    (void)copy_string_checked(chosen_server, sizeof(chosen_server), cached_server);
                }
            }
        }

        if (success == 0) {
            for (i = 0; i < ordered_count; ++i) {
                if (server_already_tried(tried, tried_count, ordered[i]) != 0) continue;
                memset(response, 0, sizeof(response));
                if (cfg.debug) (void)fprintf(stderr, "[DEBUG] Trying priority[%d] server %s...\n", i, ordered[i]);
                mark_server_tried(tried, &tried_count, ordered[i]);
                if (try_server_with_retries(ordered[i], message, response, sizeof(response), &cfg) == 0) {
                    if (mode != MODE_HEALTH && response_is_nonactive(response)) {
                        if (cfg.debug) (void)fprintf(stderr, "[DEBUG] Server %s reports standby/maintenance; trying next priority\n", ordered[i]);
                        memset(response, 0, sizeof(response));
                        continue;
                    }
                    success = 1;
                    (void)copy_string_checked(chosen_server, sizeof(chosen_server), ordered[i]);
                    break;
                }
            }
        }
    }
    if (success == 0) {
        exit_code = EXIT_CONNECT;
        print_result(&cfg, exit_code, "connect_error", "failed to connect to any server", "");
        goto out;
    }

    exit_code = EXIT_OK;
    if (mode != MODE_HEALTH) {
        priority_cache_store(chosen_server, cfg.priority_recheck_sec, cfg.debug);
    }
    if ((mode == MODE_AD || mode == MODE_APP_MD5 || mode == MODE_APP_SHA256 || mode == MODE_APP_CHECKSUM) &&
        cfg.token_affinity != TOKEN_AFFINITY_OFF) {
        (void)token_origin_store(response, chosen_server, cfg.debug);
    }
    print_result(&cfg, exit_code, "ok", response, chosen_server);

out:
    secure_bzero(message, sizeof(message));
    secure_bzero(response, sizeof(response));
    platform_cleanup();
    return (int)exit_code;
}
