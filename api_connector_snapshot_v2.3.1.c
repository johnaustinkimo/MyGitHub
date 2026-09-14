#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdatomic.h>
#include <sqlite3.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <libgen.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/inotify.h>
#include <sys/types.h>
#include <sys/un.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <limits.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/hmac.h>
#include <openssl/bio.h>
#include <openssl/buffer.h>
#include <openssl/bn.h>
#include <openssl/sha.h>

#include <jansson.h>

#define KEY_HEX "6e9f78c1c24acdee688a360f1212c9b9989e7469d6a6e39e4ed7ca279f0c7846"
#define CERT_FILE "/opt/epm_certs/server.crt"
#define KEY_FILE  "/opt/epm_certs/server.key"
#define CA_FILE   "/opt/epm_certs/ca.crt"

#define DEFAULT_DB_FILE "/ws/snapshot.db"
#define DEFAULT_PORT 6666
#define DEFAULT_WORKERS 8
#define MAX_WORKERS 128
#define DEFAULT_HANDSHAKE_TIMEOUT 5
#define DEFAULT_IO_TIMEOUT 10
#define DEFAULT_CERT_WARN_DAYS 30
#define DEFAULT_SNAPSHOT_WARN_AGE 86400
#define DEFAULT_STATUS_INTERVAL 0
#define HEALTH_CHECK_INTERVAL_SEC 60
#define DB_STAT_FALLBACK_INTERVAL_SEC 5
#define INOTIFY_RETRY_INTERVAL_SEC 30
#define WARNING_REPEAT_INTERVAL_SEC 3600
#define EPV_VERSION "2.3.1"
#define INSTANCE_ID_MAX 63
#define BOOT_ID_HEX_LEN 32
#define ROLE_CHECK_INTERVAL_SEC 1
#define MIN_TIMEOUT_SEC 1
#define MAX_TIMEOUT_SEC 300

#define DB_URI_MAX (PATH_MAX + 64)
#define TOKEN_EXPIRY 600

#define QUEUE_CAPACITY 8192
#define READ_BUF_SZ 2048
#define WRITE_BUF_SZ 8192

#define TOKEN_TABLE_SIZE 65536
#define TOKEN_PROBE_LIMIT 32

static int g_debug = 0;
#define DBG(fmt, ...) do { \
    if (g_debug) { \
        time_t _t = time(NULL); \
        struct tm _tm; \
        localtime_r(&_t, &_tm); \
        char _buf[64]; \
        strftime(_buf, sizeof(_buf), "[%Y-%m-%d %H:%M:%S]", &_tm); \
        fprintf(stderr, "%s [DEBUG] " fmt "\n", _buf, ##__VA_ARGS__); \
    } \
} while (0)

typedef enum {
    TOKEN_BINDING_OFF = 0,
    TOKEN_BINDING_COMPAT = 1,
    TOKEN_BINDING_STRICT = 2
} token_binding_mode_t;

typedef enum {
    CONNECTOR_ROLE_ACTIVE = 0,
    CONNECTOR_ROLE_STANDBY = 1,
    CONNECTOR_ROLE_MAINTENANCE = 2
} connector_role_t;

typedef struct {
    int port;
    int strict_tls;
    int debug;
    int workers;
    int handshake_timeout_sec;
    int io_timeout_sec;
    int cert_warn_days;
    int snapshot_warn_age_sec;
    int status_interval_sec;
    token_binding_mode_t token_binding_mode;
    connector_role_t initial_role;
    char instance_id[INSTANCE_ID_MAX + 1];
    char db_path[PATH_MAX];
    char runtime_dir[PATH_MAX];
    char role_file[PATH_MAX];
} server_opts_t;

typedef struct {
    int fd;
    struct sockaddr_in addr;
} conn_job_t;

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
    conn_job_t items[QUEUE_CAPACITY];
    size_t head;
    size_t tail;
    size_t count;
    int stopped;
} conn_queue_t;

typedef struct {
    uint64_t h1;
    uint64_t h2;
    time_t ts;
    uint8_t used;
} token_slot_t;

typedef struct {
    pthread_mutex_t mutex;
    token_slot_t slots[TOKEN_TABLE_SIZE];
} token_store_t;

typedef struct {
    sqlite3 *db;
    sqlite3_stmt *st_login;
    sqlite3_stmt *st_secret;
    unsigned long db_epoch_seen;
    int id;
} worker_ctx_t;

typedef struct {
    atomic_ulong accepted_total;
    atomic_ulong active_connections;
    atomic_ulong queue_depth;
    atomic_ulong queue_peak;
    atomic_ulong queue_dropped_total;
    atomic_ulong emfile_total;
    atomic_ulong tls_ok_total;
    atomic_ulong tls_fail_total;
    atomic_ulong tls_timeout_total;
    atomic_ulong request_total;
    atomic_ulong login_request_total;
    atomic_ulong login_ok_total;
    atomic_ulong login_fail_total;
    atomic_ulong secret_request_total;
    atomic_ulong secret_ok_total;
    atomic_ulong secret_fail_total;
    atomic_ulong invalid_request_total;
    atomic_ulong io_error_total;
    atomic_ulong token_replay_total;
    atomic_ulong token_store_saturated_total;
    atomic_ulong token_node_mismatch_total;
    atomic_ulong token_boot_mismatch_total;
    atomic_ulong legacy_token_accept_total;
    atomic_ulong health_request_total;
    atomic_ulong owner_probe_total;
    atomic_ulong owner_match_total;
    atomic_ulong role_reject_total;
    atomic_ulong db_reload_ok_total;
    atomic_ulong db_reload_fail_total;
    atomic_ulong dbwatch_recover_total;
} metrics_t;

static volatile sig_atomic_t g_stop = 0;
static volatile sig_atomic_t g_status_requested = 0;
static SSL_CTX *g_ssl_ctx = NULL;
static int g_listen_fd = -1;
static int g_strict_tls = 0;
static int g_handshake_timeout_sec = DEFAULT_HANDSHAKE_TIMEOUT;
static int g_io_timeout_sec = DEFAULT_IO_TIMEOUT;
static int g_signal_pipe[2] = {-1, -1};
static int g_reserve_fd = -1;
static char g_runtime_dir[PATH_MAX];
static char g_lkg_path[PATH_MAX];
static int g_cert_warn_days = DEFAULT_CERT_WARN_DAYS;
static int g_snapshot_warn_age_sec = DEFAULT_SNAPSHOT_WARN_AGE;
static int g_status_interval_sec = DEFAULT_STATUS_INTERVAL;
static token_binding_mode_t g_token_binding_mode = TOKEN_BINDING_COMPAT;
static atomic_int g_connector_role = CONNECTOR_ROLE_ACTIVE;
static char g_role_file[PATH_MAX];
static int64_t g_last_role_check_ms = 0;
static char g_instance_id[INSTANCE_ID_MAX + 1];
static char g_boot_id[BOOT_ID_HEX_LEN + 1];
static int64_t g_start_monotonic_ms = 0;
static int64_t g_watchdog_interval_ms = 0;
static int64_t g_last_watchdog_ms = 0;
static int64_t g_last_health_check_ms = 0;
static int64_t g_last_status_ms = 0;
static int64_t g_last_cert_warning_ms = 0;
static int64_t g_last_snapshot_warning_ms = 0;
static atomic_llong g_last_good_snapshot_mtime = 0;
static atomic_int g_dbwatch_alive = 0;
static conn_queue_t g_queue;
static token_store_t g_token_store;
static metrics_t g_metrics;
static atomic_ulong g_db_epoch = 1;

static char g_db_path[PATH_MAX];
static pthread_t *g_worker_threads = NULL;
static worker_ctx_t *g_workers = NULL;
static pthread_t g_dbwatch_thread;

static void die(const char *msg) {
    perror(msg);
    exit(1);
}

static void ssl_die(const char *msg) {
    fprintf(stderr, "[SSL ERROR] %s\n", msg);
    ERR_print_errors_fp(stderr);
    exit(1);
}

static void handle_signal(int sig) {
    if (sig == SIGUSR1) {
        g_status_requested = 1;
    } else {
        g_stop = 1;
    }
    if (g_signal_pipe[1] >= 0) {
        const unsigned char b = (sig == SIGUSR1) ? 2U : 1U;
        ssize_t wr = write(g_signal_pipe[1], &b, 1);
        (void)wr;
    }
}

static int install_signal_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    if (sigaction(SIGINT, &sa, NULL) != 0) return -1;
    if (sigaction(SIGTERM, &sa, NULL) != 0) return -1;
    if (sigaction(SIGUSR1, &sa, NULL) != 0) return -1;

    struct sigaction ign;
    memset(&ign, 0, sizeof(ign));
    ign.sa_handler = SIG_IGN;
    sigemptyset(&ign.sa_mask);
    if (sigaction(SIGPIPE, &ign, NULL) != 0) return -1;
    return 0;
}

static int parse_timeout_value(const char *name, const char *value) {
    char *end = NULL;
    errno = 0;
    long v = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' ||
        v < MIN_TIMEOUT_SEC || v > MAX_TIMEOUT_SEC) {
        fprintf(stderr, "invalid %s value: %s (range %d-%d)\n",
                name, value ? value : "(null)", MIN_TIMEOUT_SEC, MAX_TIMEOUT_SEC);
        exit(1);
    }
    return (int)v;
}

static int parse_nonnegative_value(const char *name, const char *value, int maxv) {
    char *end = NULL;
    errno = 0;
    long v = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || v < 0 || v > maxv) {
        fprintf(stderr, "invalid %s value: %s (range 0-%d)\n",
                name, value ? value : "(null)", maxv);
        exit(1);
    }
    return (int)v;
}

static void hex2bin(const char *hex, unsigned char *out) {
    for (int i = 0; i < 32; i++) {
        sscanf(hex + 2 * i, "%2hhx", &out[i]);
    }
}

static const char *token_binding_name(token_binding_mode_t mode) {
    switch (mode) {
        case TOKEN_BINDING_OFF: return "off";
        case TOKEN_BINDING_STRICT: return "strict";
        case TOKEN_BINDING_COMPAT:
        default: return "compat";
    }
}

static int parse_token_binding_mode(const char *value, token_binding_mode_t *out) {
    if (!value || !out) return -1;
    if (strcmp(value, "off") == 0) *out = TOKEN_BINDING_OFF;
    else if (strcmp(value, "compat") == 0) *out = TOKEN_BINDING_COMPAT;
    else if (strcmp(value, "strict") == 0) *out = TOKEN_BINDING_STRICT;
    else return -1;
    return 0;
}

static int valid_instance_id(const char *s) {
    if (!s || !*s) return 0;
    size_t n = strlen(s);
    if (n > INSTANCE_ID_MAX) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!((c >= (unsigned char)'a' && c <= (unsigned char)'z') ||
              (c >= (unsigned char)'A' && c <= (unsigned char)'Z') ||
              (c >= (unsigned char)'0' && c <= (unsigned char)'9') ||
              c == (unsigned char)'-' || c == (unsigned char)'_' || c == (unsigned char)'.')) {
            return 0;
        }
    }
    return 1;
}

static int init_instance_identity(const char *configured_id) {
    char host[INSTANCE_ID_MAX + 1];
    memset(host, 0, sizeof(host));

    if (configured_id && *configured_id) {
        if (!valid_instance_id(configured_id)) return -1;
        snprintf(g_instance_id, sizeof(g_instance_id), "%s", configured_id);
    } else {
        if (gethostname(host, sizeof(host) - 1U) != 0 || host[0] == '\0') {
            snprintf(host, sizeof(host), "epv-%ld", (long)getpid());
        }
        host[sizeof(host) - 1U] = '\0';
        for (size_t i = 0; host[i] != '\0'; i++) {
            unsigned char c = (unsigned char)host[i];
            if (!((c >= (unsigned char)'a' && c <= (unsigned char)'z') ||
                  (c >= (unsigned char)'A' && c <= (unsigned char)'Z') ||
                  (c >= (unsigned char)'0' && c <= (unsigned char)'9') ||
                  c == (unsigned char)'-' || c == (unsigned char)'_' || c == (unsigned char)'.')) {
                host[i] = '_';
            }
        }
        snprintf(g_instance_id, sizeof(g_instance_id), "%s", host);
    }

    unsigned char boot[BOOT_ID_HEX_LEN / 2];
    if (RAND_bytes(boot, (int)sizeof(boot)) != 1) return -1;
    for (size_t i = 0; i < sizeof(boot); i++) {
        snprintf(g_boot_id + i * 2U, sizeof(g_boot_id) - i * 2U, "%02x", boot[i]);
    }
    g_boot_id[BOOT_ID_HEX_LEN] = '\0';
    OPENSSL_cleanse(boot, sizeof(boot));
    return 0;
}

static int64_t monotonic_ms(void);

static const char *connector_role_name(connector_role_t role) {
    switch (role) {
        case CONNECTOR_ROLE_STANDBY: return "STANDBY";
        case CONNECTOR_ROLE_MAINTENANCE: return "MAINTENANCE";
        case CONNECTOR_ROLE_ACTIVE:
        default: return "ACTIVE";
    }
}

static int parse_connector_role(const char *s, connector_role_t *out) {
    if (!s || !out) return -1;
    if (!strcasecmp(s, "active")) *out = CONNECTOR_ROLE_ACTIVE;
    else if (!strcasecmp(s, "standby")) *out = CONNECTOR_ROLE_STANDBY;
    else if (!strcasecmp(s, "maintenance")) *out = CONNECTOR_ROLE_MAINTENANCE;
    else return -1;
    return 0;
}

static int load_role_file(const char *path, connector_role_t *out, time_t *mtime_out) {
    FILE *fp;
    char buf[64];
    struct stat st;
    char *p;
    char *end;
    if (!path || !*path || !out) return -1;
    if (stat(path, &st) != 0) return -1;
    fp = fopen(path, "r");
    if (!fp) return -1;
    if (!fgets(buf, sizeof(buf), fp)) { fclose(fp); return -1; }
    fclose(fp);
    p = buf;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') ++p;
    end = p + strlen(p);
    while (end > p && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) *--end = '\0';
    if (parse_connector_role(p, out) != 0) return -1;
    if (mtime_out) *mtime_out = st.st_mtime;
    return 0;
}

static void refresh_connector_role(int force) {
    int64_t now_ms;
    connector_role_t role;
    connector_role_t old_role;

    if (g_role_file[0] == '\0') return;
    now_ms = monotonic_ms();
    if (!force && now_ms >= 0 && g_last_role_check_ms != 0 &&
        now_ms - g_last_role_check_ms < (int64_t)ROLE_CHECK_INTERVAL_SEC * 1000LL) return;
    g_last_role_check_ms = now_ms;

    /* The role file is tiny. Read it once per second instead of depending on
       filesystem timestamp granularity; this also catches rapid HA transitions. */
    if (load_role_file(g_role_file, &role, NULL) != 0) {
        DBG("role file unavailable/invalid path=%s errno=%d; retaining role=%s", g_role_file, errno,
            connector_role_name((connector_role_t)atomic_load(&g_connector_role)));
        return;
    }
    old_role = (connector_role_t)atomic_exchange(&g_connector_role, (int)role);
    if (old_role != role || force) {
        fprintf(stderr, "EPV_ROLE version=%s node=%s old=%s new=%s source=%s\n",
                EPV_VERSION, g_instance_id, connector_role_name(old_role), connector_role_name(role), g_role_file);
        fflush(stderr);
    }
}

static void parse_args(int argc, char **argv, server_opts_t *opts) {
    memset(opts, 0, sizeof(*opts));
    opts->port = DEFAULT_PORT;
    opts->strict_tls = 0;
    opts->debug = 0;
    opts->workers = DEFAULT_WORKERS;
    opts->handshake_timeout_sec = DEFAULT_HANDSHAKE_TIMEOUT;
    opts->io_timeout_sec = DEFAULT_IO_TIMEOUT;
    opts->cert_warn_days = DEFAULT_CERT_WARN_DAYS;
    opts->snapshot_warn_age_sec = DEFAULT_SNAPSHOT_WARN_AGE;
    opts->status_interval_sec = DEFAULT_STATUS_INTERVAL;
    opts->token_binding_mode = TOKEN_BINDING_COMPAT;
    opts->initial_role = CONNECTOR_ROLE_ACTIVE;
    opts->instance_id[0] = '\0';
    opts->role_file[0] = '\0';
    snprintf(opts->db_path, sizeof(opts->db_path), "%s", DEFAULT_DB_FILE);
    {
        const char *rd = getenv("RUNTIME_DIRECTORY");
        if (rd && *rd) {
            size_t n = strcspn(rd, ":");
            if (n >= sizeof(opts->runtime_dir)) n = sizeof(opts->runtime_dir) - 1U;
            memcpy(opts->runtime_dir, rd, n);
            opts->runtime_dir[n] = '\0';
        } else {
            snprintf(opts->runtime_dir, sizeof(opts->runtime_dir), "/tmp/epv-api-connector-%ld", (long)geteuid());
        }
    }

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "strict")) {
            opts->strict_tls = 1;
        } else if (!strcmp(argv[i], "--debug")) {
            opts->debug = 1;
        } else if (!strcmp(argv[i], "--workers")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--workers requires a value\n");
                exit(1);
            }
            long w = strtol(argv[++i], NULL, 10);
            if (w < 1 || w > MAX_WORKERS) {
                fprintf(stderr, "invalid --workers value: %ld\n", w);
                exit(1);
            }
            opts->workers = (int)w;
        } else if (!strcmp(argv[i], "--db")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--db requires a path\n");
                exit(1);
            }
            snprintf(opts->db_path, sizeof(opts->db_path), "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--runtime-dir")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--runtime-dir requires a path\n");
                exit(1);
            }
            snprintf(opts->runtime_dir, sizeof(opts->runtime_dir), "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--handshake-timeout")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--handshake-timeout requires seconds\n");
                exit(1);
            }
            opts->handshake_timeout_sec = parse_timeout_value("--handshake-timeout", argv[++i]);
        } else if (!strcmp(argv[i], "--io-timeout")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--io-timeout requires seconds\n");
                exit(1);
            }
            opts->io_timeout_sec = parse_timeout_value("--io-timeout", argv[++i]);
        } else if (!strcmp(argv[i], "--cert-warn-days")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--cert-warn-days requires days\n");
                exit(1);
            }
            opts->cert_warn_days = parse_nonnegative_value("--cert-warn-days", argv[++i], 3650);
        } else if (!strcmp(argv[i], "--snapshot-warn-age")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--snapshot-warn-age requires seconds\n");
                exit(1);
            }
            opts->snapshot_warn_age_sec = parse_nonnegative_value("--snapshot-warn-age", argv[++i], 315360000);
        } else if (!strcmp(argv[i], "--status-interval")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--status-interval requires seconds\n");
                exit(1);
            }
            opts->status_interval_sec = parse_nonnegative_value("--status-interval", argv[++i], 86400);
        } else if (!strcmp(argv[i], "--instance-id")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--instance-id requires a value\n");
                exit(1);
            }
            const char *id = argv[++i];
            if (!valid_instance_id(id)) {
                fprintf(stderr, "invalid --instance-id value (allowed: A-Z a-z 0-9 . _ -, max %d)\n", INSTANCE_ID_MAX);
                exit(1);
            }
            snprintf(opts->instance_id, sizeof(opts->instance_id), "%s", id);
        } else if (!strcmp(argv[i], "--role")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--role requires active|standby|maintenance\n");
                exit(1);
            }
            if (parse_connector_role(argv[++i], &opts->initial_role) != 0) {
                fprintf(stderr, "invalid --role value: %s (expected active|standby|maintenance)\n", argv[i]);
                exit(1);
            }
        } else if (!strcmp(argv[i], "--role-file")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--role-file requires a path\n");
                exit(1);
            }
            snprintf(opts->role_file, sizeof(opts->role_file), "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--token-binding")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--token-binding requires off|compat|strict\n");
                exit(1);
            }
            if (parse_token_binding_mode(argv[++i], &opts->token_binding_mode) != 0) {
                fprintf(stderr, "invalid --token-binding value: %s (expected off|compat|strict)\n", argv[i]);
                exit(1);
            }
        } else {
            char *end = NULL;
            long p = strtol(argv[i], &end, 10);
            if (*end == '\0' && p > 0 && p <= 65535) {
                opts->port = (int)p;
            } else {
                fprintf(stderr, "unknown argument: %s\n", argv[i]);
                exit(1);
            }
        }
    }
}

static char *b64url_enc(const unsigned char *in, int len) {
    BIO *b64 = BIO_new(BIO_f_base64());
    BIO *mem = BIO_new(BIO_s_mem());
    if (!b64 || !mem) {
        if (b64) BIO_free(b64);
        if (mem) BIO_free(mem);
        DBG("b64url_enc allocation failed");
        return NULL;
    }

    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    b64 = BIO_push(b64, mem);

    if (BIO_write(b64, in, len) <= 0 || BIO_flush(b64) != 1) {
        BIO_free_all(b64);
        DBG("b64url_enc BIO write/flush failed");
        return NULL;
    }

    BUF_MEM *b = NULL;
    BIO_get_mem_ptr(b64, &b);
    if (!b || !b->data || b->length <= 0) {
        BIO_free_all(b64);
        DBG("b64url_enc mem ptr failed");
        return NULL;
    }

    char *out = strndup(b->data, b->length);
    BIO_free_all(b64);
    if (!out) {
        DBG("b64url_enc strdup failed");
        return NULL;
    }

    for (char *p = out; *p; p++) {
        if (*p == '+') *p = '-';
        else if (*p == '/') *p = '_';
    }
    size_t n = strlen(out);
    while (n > 0 && out[n - 1] == '=') {
        out[n - 1] = '\0';
        n--;
    }

    DBG("b64url_enc success len_in=%d len_out=%zu", len, strlen(out));
    return out;
}

static unsigned char *b64url_dec(const char *s, int *outlen) {
    if (!s || !outlen) return NULL;

    size_t sl = strlen(s);
    size_t pad = (4 - (sl % 4)) % 4;

    char *tmp = malloc(sl + pad + 1);
    if (!tmp) {
        DBG("b64url_dec tmp alloc failed");
        return NULL;
    }

    memcpy(tmp, s, sl);
    for (size_t i = 0; i < pad; i++) tmp[sl + i] = '=';
    tmp[sl + pad] = '\0';

    for (char *p = tmp; *p; p++) {
        if (*p == '-') *p = '+';
        else if (*p == '_') *p = '/';
    }

    BIO *b64 = BIO_new(BIO_f_base64());
    BIO *mem = BIO_new_mem_buf(tmp, -1);
    if (!b64 || !mem) {
        if (b64) BIO_free(b64);
        if (mem) BIO_free(mem);
        free(tmp);
        DBG("b64url_dec BIO alloc failed");
        return NULL;
    }

    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    mem = BIO_push(b64, mem);

    unsigned char *out = malloc(strlen(tmp) + 1);
    if (!out) {
        BIO_free_all(mem);
        free(tmp);
        DBG("b64url_dec output alloc failed");
        return NULL;
    }

    *outlen = BIO_read(mem, out, (int)strlen(tmp));
    BIO_free_all(mem);
    free(tmp);

    if (*outlen <= 0) {
        free(out);
        DBG("b64url_dec BIO_read failed");
        return NULL;
    }

    DBG("b64url_dec success len_in=%zu len_out=%d", sl, *outlen);
    return out;
}

static char *hmac256(const char *s, const unsigned char *key) {
    if (!s || !key) return NULL;

    unsigned char h[EVP_MAX_MD_SIZE];
    unsigned int l = 0;

    if (!HMAC(EVP_sha256(), key, 32, (const unsigned char *)s, strlen(s), h, &l) || l != 32) {
        DBG("HMAC SHA256 failed");
        return NULL;
    }

    char *o = malloc(65);
    if (!o) {
        DBG("HMAC hex alloc failed");
        return NULL;
    }

    for (int i = 0; i < 32; i++) sprintf(o + i * 2, "%02x", h[i]);
    o[64] = '\0';
    DBG("HMAC success input_len=%zu", strlen(s));
    return o;
}

static char *aes_encrypt(const char *plain, const unsigned char *key) {
    if (!plain || !key) return NULL;

    unsigned char iv[16];
    unsigned char buf[4096];
    int len = 0, cl = 0;

    if (!RAND_bytes(iv, sizeof(iv))) {
        DBG("AES encrypt RAND_bytes failed");
        return NULL;
    }

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        DBG("AES encrypt ctx alloc failed");
        return NULL;
    }

    if (EVP_EncryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, iv) != 1) {
        DBG("AES encrypt init failed");
        EVP_CIPHER_CTX_free(ctx);
        return NULL;
    }
    if (EVP_EncryptUpdate(ctx, buf, &len, (const unsigned char *)plain, (int)strlen(plain)) != 1) {
        DBG("AES encrypt update failed");
        EVP_CIPHER_CTX_free(ctx);
        return NULL;
    }
    cl = len;
    if (EVP_EncryptFinal_ex(ctx, buf + len, &len) != 1) {
        DBG("AES encrypt final failed");
        EVP_CIPHER_CTX_free(ctx);
        return NULL;
    }
    cl += len;
    EVP_CIPHER_CTX_free(ctx);

    char *iv64 = b64url_enc(iv, sizeof(iv));
    char *ct64 = b64url_enc(buf, cl);
    if (!iv64 || !ct64) {
        DBG("AES encrypt base64 encode failed");
        free(iv64);
        free(ct64);
        return NULL;
    }

    char *out = malloc(strlen(iv64) + strlen(ct64) + 2);
    if (!out) {
        DBG("AES encrypt output alloc failed");
        free(iv64);
        free(ct64);
        return NULL;
    }

    sprintf(out, "%s:%s", iv64, ct64);
    DBG("AES encrypt success plain_len=%zu enc_len=%zu", strlen(plain), strlen(out));
    free(iv64);
    free(ct64);
    return out;
}

static char *aes_decrypt(const char *enc, const unsigned char *key) {
    if (!enc || !key) return strdup("(decrypt error)");

    char *sep = strchr(enc, ':');
    if (!sep) {
        DBG("AES decrypt invalid format");
        return strdup("(decrypt error)");
    }

    char *ivs = strndup(enc, (size_t)(sep - enc));
    char *cts = strdup(sep + 1);
    if (!ivs || !cts) {
        free(ivs);
        free(cts);
        DBG("AES decrypt alloc failed");
        return strdup("(decrypt error)");
    }

    int il = 0, cl = 0;
    unsigned char *iv = b64url_dec(ivs, &il);
    unsigned char *ct = b64url_dec(cts, &cl);
    free(ivs);
    free(cts);

    if (!iv || !ct || il != 16 || cl <= 0) {
        free(iv);
        free(ct);
        DBG("AES decrypt base64 decode failed");
        return strdup("(decrypt error)");
    }

    unsigned char buf[4096];
    int len = 0, pl = 0;

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) {
        free(iv);
        free(ct);
        DBG("AES decrypt ctx alloc failed");
        return strdup("(decrypt error)");
    }

    if (EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, key, iv) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free(iv);
        free(ct);
        DBG("AES decrypt init failed");
        return strdup("(decrypt error)");
    }
    if (EVP_DecryptUpdate(ctx, buf, &len, ct, cl) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free(iv);
        free(ct);
        DBG("AES decrypt update failed");
        return strdup("(decrypt error)");
    }
    pl = len;
    if (EVP_DecryptFinal_ex(ctx, buf + len, &len) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        free(iv);
        free(ct);
        DBG("AES decrypt final failed");
        return strdup("(decrypt error)");
    }
    pl += len;

    EVP_CIPHER_CTX_free(ctx);
    free(iv);
    free(ct);

    buf[pl] = '\0';
    DBG("AES decrypt success enc_len=%zu plain_len=%d", strlen(enc), pl);
    return strdup((char *)buf);
}

static char *aes_decrypt_db(const char *enc, const unsigned char *key) {
    if (!enc || !key) return strdup("(decrypt error)");

    const char *sep = strchr(enc, ':');
    if (!sep) {
        DBG("AES DB decrypt invalid format");
        return strdup("(decrypt error)");
    }

    size_t hexlen = (size_t)(sep - enc);
    if (hexlen != 32) {
        DBG("AES DB decrypt IV hex length invalid: %zu", hexlen);
        return strdup("(decrypt error)");
    }

    unsigned char iv[16];
    for (int i = 0; i < 16; i++) {
        if (sscanf(enc + i * 2, "%2hhx", &iv[i]) != 1) {
            DBG("AES DB decrypt IV parse failed");
            return strdup("(decrypt error)");
        }
    }

    BIO *b64 = BIO_new(BIO_f_base64());
    BIO *bmem = BIO_new_mem_buf(sep + 1, -1);
    if (!b64 || !bmem) {
        if (b64) BIO_free(b64);
        if (bmem) BIO_free(bmem);
        DBG("AES DB decrypt BIO alloc failed");
        return strdup("(decrypt error)");
    }

    BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
    bmem = BIO_push(b64, bmem);

    unsigned char ct[4096];
    int cl = BIO_read(bmem, ct, sizeof(ct));
    BIO_free_all(bmem);
    if (cl <= 0) {
        DBG("AES DB decrypt base64 read failed");
        return strdup("(decrypt error)");
    }

    unsigned char plain[4096];
    int len = 0, pl = 0;

    EVP_CIPHER_CTX *c = EVP_CIPHER_CTX_new();
    if (!c) {
        DBG("AES DB decrypt ctx alloc failed");
        return strdup("(decrypt error)");
    }

    if (EVP_DecryptInit_ex(c, EVP_aes_256_cbc(), NULL, key, iv) != 1) {
        EVP_CIPHER_CTX_free(c);
        DBG("AES DB decrypt init failed");
        return strdup("(decrypt error)");
    }
    if (EVP_DecryptUpdate(c, plain, &len, ct, cl) != 1) {
        EVP_CIPHER_CTX_free(c);
        DBG("AES DB decrypt update failed");
        return strdup("(decrypt error)");
    }
    pl = len;
    if (EVP_DecryptFinal_ex(c, plain + len, &len) != 1) {
        EVP_CIPHER_CTX_free(c);
        DBG("AES DB decrypt final failed");
        return strdup("(decrypt error)");
    }
    pl += len;
    EVP_CIPHER_CTX_free(c);

    plain[pl] = '\0';
    DBG("AES DB decrypt success enc_len=%zu plain_len=%d", strlen(enc), pl);
    return strdup((char *)plain);
}

static void queue_init(conn_queue_t *q) {
    memset(q, 0, sizeof(*q));
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->not_empty, NULL);
    pthread_cond_init(&q->not_full, NULL);
}

static void queue_destroy(conn_queue_t *q) {
    pthread_mutex_destroy(&q->mutex);
    pthread_cond_destroy(&q->not_empty);
    pthread_cond_destroy(&q->not_full);
}

static int queue_try_push(conn_queue_t *q, const conn_job_t *job) {
    pthread_mutex_lock(&q->mutex);
    if (q->stopped) {
        pthread_mutex_unlock(&q->mutex);
        return -1;
    }
    if (q->count == QUEUE_CAPACITY) {
        pthread_mutex_unlock(&q->mutex);
        return -2;
    }
    q->items[q->tail] = *job;
    q->tail = (q->tail + 1) % QUEUE_CAPACITY;
    q->count++;
    unsigned long depth = atomic_fetch_add(&g_metrics.queue_depth, 1UL) + 1UL;
    unsigned long peak = atomic_load(&g_metrics.queue_peak);
    while (depth > peak && !atomic_compare_exchange_weak(&g_metrics.queue_peak, &peak, depth)) {}
    DBG("Enqueue fd=%d queue_count=%zu", job->fd, q->count);
    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->mutex);
    return 0;
}

static void queue_stop_and_close_pending(conn_queue_t *q) {
    pthread_mutex_lock(&q->mutex);
    q->stopped = 1;
    while (q->count > 0) {
        conn_job_t *job = &q->items[q->head];
        if (job->fd >= 0) close(job->fd);
        q->head = (q->head + 1) % QUEUE_CAPACITY;
        q->count--;
    }
    q->tail = q->head;
    atomic_store(&g_metrics.queue_depth, 0UL);
    pthread_cond_broadcast(&q->not_empty);
    pthread_cond_broadcast(&q->not_full);
    pthread_mutex_unlock(&q->mutex);
}

static int queue_pop(conn_queue_t *q, conn_job_t *job) {
    pthread_mutex_lock(&q->mutex);
    while (!q->stopped && q->count == 0) {
        pthread_cond_wait(&q->not_empty, &q->mutex);
    }
    if (q->count == 0 && q->stopped) {
        pthread_mutex_unlock(&q->mutex);
        return -1;
    }
    *job = q->items[q->head];
    q->head = (q->head + 1) % QUEUE_CAPACITY;
    q->count--;
    (void)atomic_fetch_sub(&g_metrics.queue_depth, 1UL);
    DBG("Dequeue fd=%d queue_count=%zu", job->fd, q->count);
    pthread_cond_signal(&q->not_full);
    pthread_mutex_unlock(&q->mutex);
    return 0;
}

static void token_store_init(token_store_t *ts) {
    memset(ts, 0, sizeof(*ts));
    pthread_mutex_init(&ts->mutex, NULL);
    DBG("Token store initialized");
}

static void token_store_destroy(token_store_t *ts) {
    pthread_mutex_destroy(&ts->mutex);
    DBG("Token store destroyed");
}

static void token_fingerprint(const char *token, uint64_t *h1, uint64_t *h2) {
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256((const unsigned char *)token, strlen(token), digest);
    memcpy(h1, digest, sizeof(uint64_t));
    memcpy(h2, digest + 8, sizeof(uint64_t));
}

static int token_check_once(const char *token) {
    if (!token) return 0;

    uint64_t h1 = 0, h2 = 0;
    token_fingerprint(token, &h1, &h2);

    time_t now = time(NULL);
    size_t idx = (size_t)(h1 % TOKEN_TABLE_SIZE);

    pthread_mutex_lock(&g_token_store.mutex);

    size_t first_expired = (size_t)-1;
    for (size_t i = 0; i < TOKEN_PROBE_LIMIT; i++) {
        size_t pos = (idx + i) % TOKEN_TABLE_SIZE;
        token_slot_t *s = &g_token_store.slots[pos];

        if (s->used) {
            if ((now - s->ts) > TOKEN_EXPIRY) {
                if (first_expired == (size_t)-1) first_expired = pos;
                continue;
            }
            if (s->h1 == h1 && s->h2 == h2) {
                pthread_mutex_unlock(&g_token_store.mutex);
                (void)atomic_fetch_add(&g_metrics.token_replay_total, 1UL);
                DBG("Token replay detected");
                return 0;
            }
        } else {
            first_expired = pos;
            break;
        }
    }

    if (first_expired == (size_t)-1) {
        pthread_mutex_unlock(&g_token_store.mutex);
        (void)atomic_fetch_add(&g_metrics.token_store_saturated_total, 1UL);
        DBG("Token replay store probe window saturated; rejecting token");
        return 0;
    }

    g_token_store.slots[first_expired].h1 = h1;
    g_token_store.slots[first_expired].h2 = h2;
    g_token_store.slots[first_expired].ts = now;
    g_token_store.slots[first_expired].used = 1;

    pthread_mutex_unlock(&g_token_store.mutex);
    DBG("Token registered");
    return 1;
}

static char *token_encode(const char *u, const char *ip, const char *auth, const unsigned char *key) {
    time_t now = time(NULL);
    char js[768];

    uint32_t jti = 0;
    if (RAND_bytes((unsigned char *)&jti, sizeof(jti)) != 1) {
        DBG("Token encode RAND_bytes failed");
        return NULL;
    }

    snprintf(js, sizeof(js),
             "{\"ver\":2,\"sub\":\"%s\",\"ip\":\"%s\",\"iat\":%ld,\"exp\":%ld,\"jti\":\"%08x\",\"auth\":\"%s\",\"node\":\"%s\",\"boot\":\"%s\"}",
             u ? u : "", ip ? ip : "", (long)now, (long)(now + TOKEN_EXPIRY),
             (unsigned int)jti, auth ? auth : "", g_instance_id, g_boot_id);

    DBG("Token encode payload prepared user=%s ip=%s", u ? u : "", ip ? ip : "");

    char *aes_str = aes_encrypt(js, key);
    if (!aes_str) {
        DBG("Token encode AES failed");
        return NULL;
    }

    char *sig = hmac256(aes_str, key);
    if (!sig) {
        DBG("Token encode HMAC failed");
        free(aes_str);
        return NULL;
    }

    char *t = malloc(strlen(aes_str) + strlen(sig) + 4);
    if (!t) {
        free(aes_str);
        free(sig);
        DBG("Token encode output alloc failed");
        return NULL;
    }

    sprintf(t, "s.%s.%s", aes_str, sig);
    DBG("Token encode success");
    free(aes_str);
    free(sig);
    return t;
}

static int token_verify(const char *t, const unsigned char *key, const char *client_ip,
                        char **u, char **token_ip, long *exp) {
    if (!t || !key || !client_ip || !u || !token_ip || !exp) return 0;

    *u = NULL;
    *token_ip = NULL;
    *exp = 0;

    DBG("Token verify begin client_ip=%s", client_ip);

    if (strncmp(t, "s.", 2) != 0) {
        DBG("Token verify bad prefix");
        return 0;
    }

    char *dot = strrchr(t, '.');
    if (!dot) {
        DBG("Token verify bad format");
        return 0;
    }

    char *aes_str = strndup(t + 2, (size_t)(dot - (t + 2)));
    char *sig = strdup(dot + 1);
    if (!aes_str || !sig) {
        free(aes_str);
        free(sig);
        DBG("Token verify alloc failed");
        return 0;
    }

    char *chk = hmac256(aes_str, key);
    size_t sig_len = strlen(sig);
    if (!chk || sig_len != 64U || CRYPTO_memcmp(chk, sig, 64U) != 0) {
        DBG("Token HMAC mismatch");
        free(aes_str);
        free(sig);
        free(chk);
        return 0;
    }
    DBG("Token HMAC verified");
    free(chk);
    free(sig);

    char *pl = aes_decrypt(aes_str, key);
    free(aes_str);
    if (!pl || strcmp(pl, "(decrypt error)") == 0) {
        DBG("Token AES decrypt failed");
        free(pl);
        return 0;
    }

    DBG("Token decrypted payload parsed");

    json_error_t jerr;
    json_t *j = json_loads(pl, 0, &jerr);
    free(pl);
    if (!j) {
        DBG("Token JSON parse failed: %s", jerr.text);
        return 0;
    }

    const char *su = json_string_value(json_object_get(j, "sub"));
    const char *si = json_string_value(json_object_get(j, "ip"));
    const char *sn = json_string_value(json_object_get(j, "node"));
    const char *sb = json_string_value(json_object_get(j, "boot"));
    json_int_t je = json_integer_value(json_object_get(j, "exp"));
    json_int_t ji = json_integer_value(json_object_get(j, "iat"));

    if (g_token_binding_mode != TOKEN_BINDING_OFF) {
        if (!sn && !sb) {
            if (g_token_binding_mode == TOKEN_BINDING_STRICT) {
                DBG("Token rejected: legacy token missing node/boot binding");
                json_decref(j);
                return 0;
            }
            (void)atomic_fetch_add(&g_metrics.legacy_token_accept_total, 1UL);
            DBG("Legacy token accepted in compatibility mode");
        } else if (!sn || !sb) {
            DBG("Token rejected: incomplete node/boot binding");
            json_decref(j);
            return 0;
        } else {
            int node_mismatch = (strcmp(sn, g_instance_id) != 0);
            int boot_mismatch = (strcmp(sb, g_boot_id) != 0);
            if (node_mismatch) {
                (void)atomic_fetch_add(&g_metrics.token_node_mismatch_total, 1UL);
                DBG("Token node mismatch token_node=%s local_node=%s mode=%s",
                    sn, g_instance_id, token_binding_name(g_token_binding_mode));
            }
            if (boot_mismatch) {
                (void)atomic_fetch_add(&g_metrics.token_boot_mismatch_total, 1UL);
                DBG("Token boot mismatch for node=%s mode=%s",
                    g_instance_id, token_binding_name(g_token_binding_mode));
            }
            if (g_token_binding_mode == TOKEN_BINDING_STRICT && (node_mismatch || boot_mismatch)) {
                json_decref(j);
                return 0;
            }
            if (g_token_binding_mode == TOKEN_BINDING_COMPAT && (node_mismatch || boot_mismatch)) {
                DBG("Compatibility mode bypassed node/boot mismatch");
            }
        }
    }

    if (!su || !si) {
        DBG("Token JSON missing sub/ip");
        json_decref(j);
        return 0;
    }

    *u = strdup(su);
    *token_ip = strdup(si);
    *exp = (long)je;

    if (!*u || !*token_ip) {
        free(*u);
        free(*token_ip);
        *u = NULL;
        *token_ip = NULL;
        DBG("Token verify output alloc failed");
        json_decref(j);
        return 0;
    }

    DBG("Token decoded user=%s token_ip=%s iat=%ld exp=%ld now=%ld",
        *u, *token_ip, (long)ji, (long)je, (long)time(NULL));

    if (*exp < time(NULL)) {
        DBG("Token expired");
        free(*u);
        free(*token_ip);
        *u = NULL;
        *token_ip = NULL;
        json_decref(j);
        return 0;
    }

    if (strcmp(*token_ip, client_ip) != 0) {
        DBG("Token IP mismatch token_ip=%s client_ip=%s", *token_ip, client_ip);
        free(*u);
        free(*token_ip);
        *u = NULL;
        *token_ip = NULL;
        json_decref(j);
        return 0;
    }

    if (!token_check_once(t)) {
        DBG("Token verify failed by replay check");
        free(*u);
        free(*token_ip);
        *u = NULL;
        *token_ip = NULL;
        json_decref(j);
        return 0;
    }

    DBG("Token verified successfully");
    json_decref(j);
    return 1;
}

static int token_owned_by_this_instance(const char *t, const unsigned char *key, const char *client_ip) {
    if (!t || !key || !client_ip || strncmp(t, "s.", 2) != 0) return 0;

    const char *dot = strrchr(t, '.');
    if (!dot || dot <= t + 2) return 0;

    char *aes_str = strndup(t + 2, (size_t)(dot - (t + 2)));
    char *sig = strdup(dot + 1);
    if (!aes_str || !sig) {
        free(aes_str);
        free(sig);
        return 0;
    }

    char *chk = hmac256(aes_str, key);
    size_t sig_len = strlen(sig);
    if (!chk || sig_len != 64U || CRYPTO_memcmp(chk, sig, 64U) != 0) {
        free(aes_str);
        free(sig);
        free(chk);
        return 0;
    }
    free(chk);
    free(sig);

    char *pl = aes_decrypt(aes_str, key);
    free(aes_str);
    if (!pl || strcmp(pl, "(decrypt error)") == 0) {
        free(pl);
        return 0;
    }

    json_error_t jerr;
    json_t *j = json_loads(pl, 0, &jerr);
    free(pl);
    if (!j) return 0;

    const char *si = json_string_value(json_object_get(j, "ip"));
    const char *sn = json_string_value(json_object_get(j, "node"));
    const char *sb = json_string_value(json_object_get(j, "boot"));
    json_int_t je = json_integer_value(json_object_get(j, "exp"));

    int owned = 0;
    if (si && sn && sb &&
        je >= (json_int_t)time(NULL) &&
        strcmp(si, client_ip) == 0 &&
        strcmp(sn, g_instance_id) == 0 &&
        strcmp(sb, g_boot_id) == 0) {
        owned = 1;
    }
    json_decref(j);
    return owned;
}

static int set_common_sockopts(int fd) {
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one)) < 0) {
        DBG("setsockopt SO_KEEPALIVE failed fd=%d", fd);
        return -1;
    }
    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) < 0) {
        DBG("setsockopt TCP_NODELAY failed fd=%d", fd);
        return -1;
    }
    return 0;
}

static int validate_snapshot_uri(const char *uri) {
    sqlite3 *db = NULL;
    sqlite3_stmt *st = NULL;
    int ok = 0;

    if (!uri || !*uri) return -1;
    if (sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return -1;
    }

    if (sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &st, NULL) != SQLITE_OK) goto out;
    if (sqlite3_step(st) != SQLITE_ROW) goto out;
    {
        const unsigned char *v = sqlite3_column_text(st, 0);
        if (!v || strcmp((const char *)v, "ok") != 0) goto out;
    }
    sqlite3_finalize(st);
    st = NULL;

    static const char *schema_checks[] = {
        "SELECT pass_salt, pass_hash, auth_type, restrict_ip, valid_code FROM users LIMIT 0;",
        "SELECT users_id, records_id, valid_code FROM access LIMIT 0;",
        "SELECT password, system_type, username, hostname, valid_code FROM records LIMIT 0;",
        NULL
    };
    for (int i = 0; schema_checks[i] != NULL; i++) {
        if (sqlite3_prepare_v2(db, schema_checks[i], -1, &st, NULL) != SQLITE_OK) goto out;
        sqlite3_finalize(st);
        st = NULL;
    }
    ok = 1;

out:
    if (st) sqlite3_finalize(st);
    if (db) sqlite3_close(db);
    return ok ? 0 : -1;
}

static int validate_snapshot_fd(int fd) {
    char uri[128];
    if (fd < 0) return -1;
    if (snprintf(uri, sizeof(uri), "file:/proc/self/fd/%d?mode=ro&immutable=1", fd) >= (int)sizeof(uri)) return -1;
    return validate_snapshot_uri(uri);
}

static int open_validated_snapshot_candidate(const char *path, int *out_fd, struct stat *out_st) {
    if (!path || !out_fd) return -1;
    *out_fd = -1;

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        DBG("snapshot candidate open failed path=%s errno=%d", path, errno);
        return -1;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        DBG("snapshot candidate fstat/type check failed path=%s errno=%d", path, errno);
        close(fd);
        return -1;
    }

    if (validate_snapshot_fd(fd) != 0) {
        DBG("snapshot candidate validation failed path=%s", path);
        close(fd);
        return -1;
    }

    *out_fd = fd;
    if (out_st) *out_st = st;
    return 0;
}

static int ensure_runtime_dir(void) {
    struct stat st;
    if (mkdir(g_runtime_dir, 0700) != 0 && errno != EEXIST) {
        DBG("runtime dir mkdir failed path=%s errno=%d", g_runtime_dir, errno);
        return -1;
    }
    if (lstat(g_runtime_dir, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
        DBG("runtime dir validation failed path=%s", g_runtime_dir);
        return -1;
    }
    if (st.st_uid != geteuid()) {
        DBG("runtime dir owner mismatch path=%s uid=%ld expected=%ld", g_runtime_dir,
            (long)st.st_uid, (long)geteuid());
        return -1;
    }
    if ((st.st_mode & 0777) != 0700) {
        if (chmod(g_runtime_dir, 0700) != 0) {
            DBG("runtime dir chmod failed path=%s errno=%d", g_runtime_dir, errno);
            return -1;
        }
    }
    return 0;
}

static int copy_fd_all(int srcfd, int dstfd) {
    if (lseek(srcfd, 0, SEEK_SET) < 0) return -1;
    unsigned char buf[65536];
    for (;;) {
        ssize_t nr = read(srcfd, buf, sizeof(buf));
        if (nr == 0) break;
        if (nr < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        ssize_t off = 0;
        while (off < nr) {
            ssize_t nw = write(dstfd, buf + off, (size_t)(nr - off));
            if (nw < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            off += nw;
        }
    }
    return 0;
}

static int fsync_parent_dir(const char *path) {
    char tmp[PATH_MAX];
    if (snprintf(tmp, sizeof(tmp), "%s", path) >= (int)sizeof(tmp)) return -1;
    char *d = dirname(tmp);
    int dfd = open(d, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dfd < 0) return -1;
    int rc = fsync(dfd);
    int saved = errno;
    close(dfd);
    errno = saved;
    return rc;
}

static int publish_snapshot_lkg(int candidate_fd, const struct stat *source_st, int bump_epoch,
                                unsigned long *epoch_out) {
    char tmp_path[PATH_MAX];
    if (candidate_fd < 0) return -1;
    if (snprintf(tmp_path, sizeof(tmp_path), "%s/.snapshot.lkg.%ld.tmp",
                 g_runtime_dir, (long)getpid()) >= (int)sizeof(tmp_path)) return -1;

    int out = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (out < 0) return -1;

    int rc = 0;
    if (copy_fd_all(candidate_fd, out) != 0 || fsync(out) != 0) rc = -1;
    int saved = errno;
    close(out);
    errno = saved;
    if (rc != 0) {
        unlink(tmp_path);
        return -1;
    }

    int verify_fd = open(tmp_path, O_RDONLY | O_CLOEXEC);
    if (verify_fd < 0 || validate_snapshot_fd(verify_fd) != 0) {
        if (verify_fd >= 0) close(verify_fd);
        unlink(tmp_path);
        return -1;
    }
    close(verify_fd);

    if (rename(tmp_path, g_lkg_path) != 0) {
        unlink(tmp_path);
        return -1;
    }
    (void)fsync_parent_dir(g_lkg_path);

    unsigned long epoch = atomic_load(&g_db_epoch);
    if (bump_epoch) epoch = atomic_fetch_add(&g_db_epoch, 1UL) + 1UL;
    if (source_st) atomic_store(&g_last_good_snapshot_mtime, (long long)source_st->st_mtime);
    if (epoch_out) *epoch_out = epoch;
    return 0;
}

static int open_worker_db(worker_ctx_t *w) {
    char uri[DB_URI_MAX];
    sqlite3 *newdb = NULL;
    sqlite3_stmt *st_login = NULL;
    sqlite3_stmt *st_secret = NULL;
    unsigned long snapshot_epoch = atomic_load(&g_db_epoch);

    if (snprintf(uri, sizeof(uri), "file:%s?mode=ro&immutable=1", g_lkg_path) >= (int)sizeof(uri)) return -1;
    DBG("worker[%d] opening last-known-good DB epoch=%lu path=%s", w->id, snapshot_epoch, g_lkg_path);

    if (sqlite3_open_v2(uri, &newdb, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (newdb) sqlite3_close(newdb);
        DBG("worker[%d] failed to open DB", w->id);
        return -1;
    }

    sqlite3_exec(newdb, "PRAGMA query_only=ON;", NULL, NULL, NULL);
    sqlite3_exec(newdb, "PRAGMA mmap_size=1073741824;", NULL, NULL, NULL);
    sqlite3_exec(newdb, "PRAGMA cache_size=-200000;", NULL, NULL, NULL);
    sqlite3_exec(newdb, "PRAGMA temp_store=MEMORY;", NULL, NULL, NULL);
    sqlite3_exec(newdb, "PRAGMA journal_mode=OFF;", NULL, NULL, NULL);
    sqlite3_exec(newdb, "PRAGMA synchronous=OFF;", NULL, NULL, NULL);

    static const char *SQL_LOGIN =
        "SELECT pass_salt, pass_hash, auth_type "
        "FROM users "
        "WHERE username = ?1 "
        "  AND ?2 LIKE (REPLACE(restrict_ip, '.0', '%') || '%') "
        "  AND valid_code = 'Y' "
        "LIMIT 1";

    static const char *SQL_SECRET =
        "SELECT t3.password "
        "FROM access t1 "
        "JOIN users t2 ON t1.users_id = t2.id "
        "JOIN records t3 ON t1.records_id = t3.id "
        "WHERE t2.username = ?1 "
        "  AND ?2 LIKE (REPLACE(t2.restrict_ip, '.0', '%') || '%') "
        "  AND t3.system_type = ?3 "
        "  AND t3.username = ?4 "
        "  AND t3.hostname = ?5 "
        "  AND t1.valid_code = 'Y' "
        "  AND t2.valid_code = 'Y' "
        "  AND t3.valid_code = 'Y' "
        "LIMIT 1";

    if (sqlite3_prepare_v2(newdb, SQL_LOGIN, -1, &st_login, NULL) != SQLITE_OK) {
        DBG("worker[%d] prepare login failed: %s", w->id, sqlite3_errmsg(newdb));
        sqlite3_close(newdb);
        return -1;
    }

    if (sqlite3_prepare_v2(newdb, SQL_SECRET, -1, &st_secret, NULL) != SQLITE_OK) {
        DBG("worker[%d] prepare secret failed: %s", w->id, sqlite3_errmsg(newdb));
        sqlite3_finalize(st_login);
        sqlite3_close(newdb);
        return -1;
    }

    if (w->st_login) sqlite3_finalize(w->st_login);
    if (w->st_secret) sqlite3_finalize(w->st_secret);
    if (w->db) sqlite3_close(w->db);

    w->db = newdb;
    w->st_login = st_login;
    w->st_secret = st_secret;
    w->db_epoch_seen = snapshot_epoch;

    DBG("worker[%d] DB ready epoch=%lu", w->id, w->db_epoch_seen);
    return 0;
}

static int worker_refresh_db_if_needed(worker_ctx_t *w) {
    unsigned long cur = atomic_load(&g_db_epoch);
    if (w->db && w->db_epoch_seen == cur) return 0;
    DBG("worker[%d] refreshing DB old_epoch=%lu new_epoch=%lu", w->id, w->db_epoch_seen, cur);
    return open_worker_db(w);
}

static int db_get_login_info(worker_ctx_t *w, const char *username, const char *ip,
                             char *salt, size_t salt_sz,
                             char *hash, size_t hash_sz,
                             char *auth, size_t auth_sz) {
    if (worker_refresh_db_if_needed(w) != 0) return 0;

    sqlite3_stmt *st = w->st_login;
    sqlite3_reset(st);
    sqlite3_clear_bindings(st);

    DBG("worker[%d] login SQL bind username=%s ip=%s", w->id, username, ip);

    if (sqlite3_bind_text(st, 1, username, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, ip, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        DBG("worker[%d] login SQL bind failed", w->id);
        return 0;
    }

    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        DBG("worker[%d] login SQL no row rc=%d", w->id, rc);
        return 0;
    }

    const unsigned char *v1 = sqlite3_column_text(st, 0);
    const unsigned char *v2 = sqlite3_column_text(st, 1);
    const unsigned char *v3 = sqlite3_column_text(st, 2);

    snprintf(salt, salt_sz, "%s", v1 ? (const char *)v1 : "");
    snprintf(hash, hash_sz, "%s", v2 ? (const char *)v2 : "");
    snprintf(auth, auth_sz, "%s", v3 ? (const char *)v3 : "");

    DBG("worker[%d] login SQL result found auth=%s", w->id, auth);
    return 1;
}

static char *db_get_secret_password(worker_ctx_t *w, const char *username, const char *ip,
                                    const char *system_type,
                                    const char *record_user,
                                    const char *hostname) {
    if (worker_refresh_db_if_needed(w) != 0) return NULL;

    sqlite3_stmt *st = w->st_secret;
    sqlite3_reset(st);
    sqlite3_clear_bindings(st);

    DBG("worker[%d] secret SQL bind username=%s ip=%s system_type=%s record_user=%s hostname=%s",
        w->id, username, ip, system_type, record_user, hostname);

    if (sqlite3_bind_text(st, 1, username, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, ip, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 3, system_type, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 4, record_user, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 5, hostname, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        DBG("worker[%d] secret SQL bind failed", w->id);
        return NULL;
    }

    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        DBG("worker[%d] secret SQL no row rc=%d", w->id, rc);
        return NULL;
    }

    const unsigned char *v = sqlite3_column_text(st, 0);
    char *result = v ? strdup((const char *)v) : NULL;

    DBG("worker[%d] secret SQL result=%s", w->id, result ? "FOUND" : "NULL");
    return result;
}

static void worker_db_close(worker_ctx_t *w) {
    if (w->st_login) {
        sqlite3_finalize(w->st_login);
        w->st_login = NULL;
    }
    if (w->st_secret) {
        sqlite3_finalize(w->st_secret);
        w->st_secret = NULL;
    }
    if (w->db) {
        sqlite3_close(w->db);
        w->db = NULL;
    }
    DBG("worker[%d] DB closed", w->id);
}

static void log_peer_cert(SSL *ssl) {
    if (!ssl || !g_debug || !g_strict_tls) return;

    X509 *peer_cert = SSL_get_peer_certificate(ssl);
    if (!peer_cert) {
        DBG("Client did not present a certificate");
        return;
    }

    char *subj = X509_NAME_oneline(X509_get_subject_name(peer_cert), NULL, 0);
    char *issuer = X509_NAME_oneline(X509_get_issuer_name(peer_cert), NULL, 0);

    DBG("Client certificate subject=%s", subj ? subj : "(null)");
    DBG("Client certificate issuer=%s", issuer ? issuer : "(null)");
    DBG("Client certificate verify=%s", SSL_get_verify_result(ssl) == X509_V_OK ? "OK" : "FAILED");

    ASN1_INTEGER *serial = X509_get_serialNumber(peer_cert);
    if (serial) {
        BIGNUM *bn = ASN1_INTEGER_to_BN(serial, NULL);
        if (bn) {
            char *hex = BN_bn2hex(bn);
            if (hex) {
                DBG("Client certificate serial=%s", hex);
                OPENSSL_free(hex);
            }
            BN_free(bn);
        }
    }

    const ASN1_TIME *nb = X509_get0_notBefore(peer_cert);
    const ASN1_TIME *na = X509_get0_notAfter(peer_cert);
    if (nb && na) {
        BIO *bio = BIO_new(BIO_s_mem());
        if (bio) {
            char buf[256];
            BIO_printf(bio, "notBefore=");
            ASN1_TIME_print(bio, nb);
            BIO_printf(bio, " notAfter=");
            ASN1_TIME_print(bio, na);
            int n = BIO_read(bio, buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = '\0';
                DBG("Client certificate validity=%s", buf);
            }
            BIO_free(bio);
        }
    }

    if (subj) OPENSSL_free(subj);
    if (issuer) OPENSSL_free(issuer);
    X509_free(peer_cert);
}

static int set_nonblocking_fd(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return -1;
    return 0;
}

static int64_t monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000L);
}

static int snapshot_path_stat(struct stat *st) {
    if (!st) return -1;
    memset(st, 0, sizeof(*st));
    return stat(g_db_path, st);
}

static int snapshot_stat_differs(const struct stat *a, const struct stat *b) {
    if (!a || !b) return 1;
    return a->st_dev != b->st_dev ||
           a->st_ino != b->st_ino ||
           a->st_size != b->st_size ||
           a->st_mtim.tv_sec != b->st_mtim.tv_sec ||
           a->st_mtim.tv_nsec != b->st_mtim.tv_nsec;
}

static int server_cert_days_remaining(void) {
    if (!g_ssl_ctx) return INT_MIN;
    X509 *cert = SSL_CTX_get0_certificate(g_ssl_ctx);
    if (!cert) return INT_MIN;
    const ASN1_TIME *na = X509_get0_notAfter(cert);
    if (!na) return INT_MIN;
    int days = 0;
    int secs = 0;
    if (ASN1_TIME_diff(&days, &secs, NULL, na) != 1) return INT_MIN;
    if (days == 0 && secs < 0) return -1;
    return days;
}

static int sd_notify_message(const char *message) {
    const char *notify_socket = getenv("NOTIFY_SOCKET");
    if (!notify_socket || !*notify_socket || !message || !*message) return 0;

    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;

    size_t path_len = strlen(notify_socket);
    socklen_t sa_len;
    if (notify_socket[0] == '@') {
        if (path_len > sizeof(sa.sun_path)) {
            close(fd);
            return -1;
        }
        sa.sun_path[0] = '\0';
        if (path_len > 1U) memcpy(sa.sun_path + 1, notify_socket + 1, path_len - 1U);
        sa_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + path_len);
    } else {
        if (path_len >= sizeof(sa.sun_path)) {
            close(fd);
            return -1;
        }
        memcpy(sa.sun_path, notify_socket, path_len + 1U);
        sa_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + path_len + 1U);
    }

    ssize_t n = sendto(fd, message, strlen(message), MSG_NOSIGNAL,
                       (const struct sockaddr *)&sa, sa_len);
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    return (n >= 0) ? 1 : -1;
}

static void init_systemd_watchdog(void) {
    const char *usec_s = getenv("WATCHDOG_USEC");
    const char *pid_s = getenv("WATCHDOG_PID");
    g_watchdog_interval_ms = 0;

    if (pid_s && *pid_s) {
        char *end = NULL;
        errno = 0;
        long pid_v = strtol(pid_s, &end, 10);
        if (errno != 0 || end == pid_s || *end != '\0' || pid_v != (long)getpid()) return;
    }
    if (!usec_s || !*usec_s) return;

    char *end = NULL;
    errno = 0;
    unsigned long long usec = strtoull(usec_s, &end, 10);
    if (errno != 0 || end == usec_s || *end != '\0' || usec < 2000000ULL) return;

    unsigned long long half_ms = usec / 2000ULL;
    if (half_ms > (unsigned long long)INT_MAX) half_ms = (unsigned long long)INT_MAX;
    g_watchdog_interval_ms = (int64_t)half_ms;
    DBG("systemd watchdog enabled interval_ms=%lld", (long long)g_watchdog_interval_ms);
}

static void print_runtime_status(const char *reason) {
    int64_t now_ms = monotonic_ms();
    long long uptime_sec = 0;
    if (now_ms >= 0 && g_start_monotonic_ms > 0 && now_ms >= g_start_monotonic_ms) {
        uptime_sec = (long long)((now_ms - g_start_monotonic_ms) / 1000LL);
    }

    time_t now = time(NULL);
    long long good_mtime = (long long)atomic_load(&g_last_good_snapshot_mtime);
    long long snapshot_age = -1;
    if (good_mtime > 0 && now >= (time_t)good_mtime) snapshot_age = (long long)now - good_mtime;
    int cert_days = server_cert_days_remaining();

    fprintf(stderr,
        "EPV_STATUS version=%s node=%s boot=%.8s role=%s token_binding=%s reason=%s uptime_sec=%lld accepted=%lu active=%lu "
        "queue=%lu queue_peak=%lu queue_dropped=%lu fd_exhaustion=%lu "
        "tls_ok=%lu tls_fail=%lu tls_timeout=%lu requests=%lu "
        "login_req=%lu login_ok=%lu login_fail=%lu secret_req=%lu secret_ok=%lu secret_fail=%lu "
        "invalid_req=%lu io_errors=%lu token_replay=%lu token_store_saturated=%lu "
        "token_node_mismatch=%lu token_boot_mismatch=%lu legacy_token_accept=%lu health_req=%lu "
        "owner_probe=%lu owner_match=%lu role_reject=%lu db_epoch=%lu db_reload_ok=%lu db_reload_fail=%lu dbwatch=%s dbwatch_recover=%lu "
        "snapshot_age_sec=%lld cert_days_remaining=%d\n",
        EPV_VERSION, g_instance_id, g_boot_id,
        connector_role_name((connector_role_t)atomic_load(&g_connector_role)),
        token_binding_name(g_token_binding_mode), reason ? reason : "manual", uptime_sec,
        atomic_load(&g_metrics.accepted_total),
        atomic_load(&g_metrics.active_connections),
        atomic_load(&g_metrics.queue_depth),
        atomic_load(&g_metrics.queue_peak),
        atomic_load(&g_metrics.queue_dropped_total),
        atomic_load(&g_metrics.emfile_total),
        atomic_load(&g_metrics.tls_ok_total),
        atomic_load(&g_metrics.tls_fail_total),
        atomic_load(&g_metrics.tls_timeout_total),
        atomic_load(&g_metrics.request_total),
        atomic_load(&g_metrics.login_request_total),
        atomic_load(&g_metrics.login_ok_total),
        atomic_load(&g_metrics.login_fail_total),
        atomic_load(&g_metrics.secret_request_total),
        atomic_load(&g_metrics.secret_ok_total),
        atomic_load(&g_metrics.secret_fail_total),
        atomic_load(&g_metrics.invalid_request_total),
        atomic_load(&g_metrics.io_error_total),
        atomic_load(&g_metrics.token_replay_total),
        atomic_load(&g_metrics.token_store_saturated_total),
        atomic_load(&g_metrics.token_node_mismatch_total),
        atomic_load(&g_metrics.token_boot_mismatch_total),
        atomic_load(&g_metrics.legacy_token_accept_total),
        atomic_load(&g_metrics.health_request_total),
        atomic_load(&g_metrics.owner_probe_total),
        atomic_load(&g_metrics.owner_match_total),
        atomic_load(&g_metrics.role_reject_total),
        atomic_load(&g_db_epoch),
        atomic_load(&g_metrics.db_reload_ok_total),
        atomic_load(&g_metrics.db_reload_fail_total),
        atomic_load(&g_dbwatch_alive) ? "up" : "down",
        atomic_load(&g_metrics.dbwatch_recover_total),
        snapshot_age, cert_days);
    fflush(stderr);
}

static void run_periodic_tasks(void) {
    int64_t now_ms = monotonic_ms();
    if (now_ms < 0) return;
    refresh_connector_role(0);

    if (g_watchdog_interval_ms > 0 &&
        (g_last_watchdog_ms == 0 || now_ms - g_last_watchdog_ms >= g_watchdog_interval_ms)) {
        if (sd_notify_message("WATCHDOG=1") < 0) DBG("systemd watchdog notify failed errno=%d", errno);
        g_last_watchdog_ms = now_ms;
    }

    if (g_status_requested) {
        g_status_requested = 0;
        print_runtime_status("SIGUSR1");
        (void)sd_notify_message("STATUS=EPV connector v2.3 status emitted by SIGUSR1");
    }

    if (g_status_interval_sec > 0 &&
        (g_last_status_ms == 0 || now_ms - g_last_status_ms >= (int64_t)g_status_interval_sec * 1000LL)) {
        print_runtime_status("interval");
        g_last_status_ms = now_ms;
    }

    if (g_last_health_check_ms != 0 &&
        now_ms - g_last_health_check_ms < (int64_t)HEALTH_CHECK_INTERVAL_SEC * 1000LL) return;
    g_last_health_check_ms = now_ms;

    int cert_days = server_cert_days_remaining();
    if (g_cert_warn_days > 0 && cert_days != INT_MIN && cert_days <= g_cert_warn_days &&
        (g_last_cert_warning_ms == 0 ||
         now_ms - g_last_cert_warning_ms >= (int64_t)WARNING_REPEAT_INTERVAL_SEC * 1000LL)) {
        fprintf(stderr, "EPV_WARN version=%s type=certificate_expiry days_remaining=%d threshold_days=%d\n",
                EPV_VERSION, cert_days, g_cert_warn_days);
        fflush(stderr);
        g_last_cert_warning_ms = now_ms;
    }

    if (g_snapshot_warn_age_sec > 0) {
        time_t now = time(NULL);
        long long good_mtime = (long long)atomic_load(&g_last_good_snapshot_mtime);
        long long age = (good_mtime > 0 && now >= (time_t)good_mtime) ? (long long)now - good_mtime : -1;
        if (age >= (long long)g_snapshot_warn_age_sec &&
            (g_last_snapshot_warning_ms == 0 ||
             now_ms - g_last_snapshot_warning_ms >= (int64_t)WARNING_REPEAT_INTERVAL_SEC * 1000LL)) {
            fprintf(stderr, "EPV_WARN version=%s type=snapshot_age age_sec=%lld threshold_sec=%d db_epoch=%lu\n",
                    EPV_VERSION, age, g_snapshot_warn_age_sec, atomic_load(&g_db_epoch));
            fflush(stderr);
            g_last_snapshot_warning_ms = now_ms;
        }
    }

    if (!atomic_load(&g_dbwatch_alive)) {
        fprintf(stderr, "EPV_WARN version=%s type=dbwatch_down message=\"snapshot watcher unavailable\"\n",
                EPV_VERSION);
        fflush(stderr);
    }
}

static int open_reserve_fd(void) {
    int fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (fd < 0) DBG("reserve fd open failed errno=%d", errno);
    return fd;
}

static void recover_from_fd_exhaustion(void) {
    (void)atomic_fetch_add(&g_metrics.emfile_total, 1UL);
    if (g_reserve_fd >= 0) {
        close(g_reserve_fd);
        g_reserve_fd = -1;
    }

    int tmpfd = accept4(g_listen_fd, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
    if (tmpfd >= 0) close(tmpfd);
    g_reserve_fd = open_reserve_fd();
}

static int ssl_wait_ready(SSL *ssl, int ssl_error, int64_t deadline_ms) {
    int fd = SSL_get_fd(ssl);
    short events;
    if (ssl_error == SSL_ERROR_WANT_READ) events = POLLIN;
    else if (ssl_error == SSL_ERROR_WANT_WRITE) events = POLLOUT;
    else return -1;

    for (;;) {
        int64_t now = monotonic_ms();
        if (now < 0 || now >= deadline_ms) {
            errno = ETIMEDOUT;
            return -1;
        }
        int64_t remain64 = deadline_ms - now;
        int remain = remain64 > INT_MAX ? INT_MAX : (int)remain64;
        struct pollfd pfd = {.fd = fd, .events = events, .revents = 0};
        int rc = poll(&pfd, 1, remain);
        if (rc > 0) {
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
            if (pfd.revents & events) return 0;
            continue;
        }
        if (rc == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        if (errno == EINTR) {
            if (g_stop) return -1;
            continue;
        }
        return -1;
    }
}

static int ssl_accept_with_timeout(SSL *ssl, int timeout_sec) {
    int64_t start = monotonic_ms();
    if (start < 0) return -1;
    int64_t deadline = start + (int64_t)timeout_sec * 1000LL;

    for (;;) {
        int rc = SSL_accept(ssl);
        if (rc == 1) return 0;
        int err = SSL_get_error(ssl, rc);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            if (ssl_wait_ready(ssl, err, deadline) == 0) continue;
            return -1;
        }
        return -1;
    }
}

static int do_ssl_readline(SSL *ssl, char *buf, size_t bufsz) {
    size_t off = 0;
    int64_t start = monotonic_ms();
    if (start < 0) return -1;
    int64_t deadline = start + (int64_t)g_io_timeout_sec * 1000LL;

    while (off + 1 < bufsz) {
        int n = SSL_read(ssl, buf + off, 1);
        if (n == 1) {
            if (buf[off] == '\n' || buf[off] == '\r') {
                buf[off] = '\0';
                DBG("SSL_read line complete len=%zu", off);
                return (int)off;
            }
            off++;
            continue;
        }

        int err = SSL_get_error(ssl, n);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            if (ssl_wait_ready(ssl, err, deadline) == 0) continue;
            DBG("SSL_read timeout/error errno=%d", errno);
            (void)atomic_fetch_add(&g_metrics.io_error_total, 1UL);
            return -1;
        }
        if (err == SSL_ERROR_ZERO_RETURN) {
            (void)atomic_fetch_add(&g_metrics.io_error_total, 1UL);
            return -1;
        }
        DBG("SSL_read failed ssl_error=%d", err);
        (void)atomic_fetch_add(&g_metrics.io_error_total, 1UL);
        return -1;
    }

    buf[bufsz - 1] = '\0';
    DBG("SSL_read line truncated max=%zu", bufsz - 1);
    return (int)(bufsz - 1);
}

static int do_ssl_writestr(SSL *ssl, const char *s) {
    size_t len = strlen(s);
    size_t off = 0;
    int64_t start = monotonic_ms();
    if (start < 0) return -1;
    int64_t deadline = start + (int64_t)g_io_timeout_sec * 1000LL;

    DBG("SSL_write begin len=%zu", len);
    while (off < len) {
        int n = SSL_write(ssl, s + off, (int)(len - off));
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        int err = SSL_get_error(ssl, n);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            if (ssl_wait_ready(ssl, err, deadline) == 0) continue;
            DBG("SSL_write timeout/error errno=%d", errno);
            (void)atomic_fetch_add(&g_metrics.io_error_total, 1UL);
            return -1;
        }
        DBG("SSL_write failed ssl_error=%d", err);
        (void)atomic_fetch_add(&g_metrics.io_error_total, 1UL);
        return -1;
    }
    DBG("SSL_write complete len=%zu", len);
    return 0;
}

static void process_request(worker_ctx_t *w, SSL *ssl, const char *client_ip, const unsigned char *key) {
    char rbuf[READ_BUF_SZ];
    char wbuf[WRITE_BUF_SZ];

    int n = do_ssl_readline(ssl, rbuf, sizeof(rbuf));
    if (n <= 0) {
        DBG("worker[%d] empty/failed read from %s", w->id, client_ip);
        do_ssl_writestr(ssl, "null\n");
        return;
    }

    (void)atomic_fetch_add(&g_metrics.request_total, 1UL);
    DBG("worker[%d] request received from %s len=%d", w->id, client_ip, n);

    char *saveptr = NULL;
    char *a = strtok_r(rbuf, " \t\r\n", &saveptr);
    char *b = strtok_r(NULL, " \t\r\n", &saveptr);
    char *c = strtok_r(NULL, " \t\r\n", &saveptr);
    char *d = strtok_r(NULL, " \t\r\n", &saveptr);

    DBG("worker[%d] parsed request fields=%d", w->id,
        (a != NULL) + (b != NULL) + (c != NULL) + (d != NULL));

    if (a && !b && strcmp(a, "HEALTH") == 0) {
        (void)atomic_fetch_add(&g_metrics.health_request_total, 1UL);
        int m = snprintf(wbuf, sizeof(wbuf),
                         "ok version=%s node=%s boot=%.8s role=%s token_binding=%s db_epoch=%lu dbwatch=%s queue=%lu active=%lu\n",
                         EPV_VERSION, g_instance_id, g_boot_id,
                         connector_role_name((connector_role_t)atomic_load(&g_connector_role)), token_binding_name(g_token_binding_mode),
                         atomic_load(&g_db_epoch),
                         atomic_load(&g_dbwatch_alive) ? "up" : "down",
                         atomic_load(&g_metrics.queue_depth),
                         atomic_load(&g_metrics.active_connections));
        if (m < 0 || (size_t)m >= sizeof(wbuf)) {
            do_ssl_writestr(ssl, "error\n");
            return;
        }
        do_ssl_writestr(ssl, wbuf);
        return;
    }

    if (a && b && !c && strcmp(a, "__EPV2_OWNER__") == 0) {
        (void)atomic_fetch_add(&g_metrics.owner_probe_total, 1UL);
        if (token_owned_by_this_instance(b, key, client_ip)) {
            (void)atomic_fetch_add(&g_metrics.owner_match_total, 1UL);
            int m = snprintf(wbuf, sizeof(wbuf), "owner version=%s node=%s boot=%.8s\n",
                             EPV_VERSION, g_instance_id, g_boot_id);
            if (m < 0 || (size_t)m >= sizeof(wbuf)) do_ssl_writestr(ssl, "error\n");
            else do_ssl_writestr(ssl, wbuf);
        } else {
            do_ssl_writestr(ssl, "not_owner\n");
        }
        return;
    }

    if (((a && b && !c) || (a && b && c && d))) {
        connector_role_t role = (connector_role_t)atomic_load(&g_connector_role);
        if (role != CONNECTOR_ROLE_ACTIVE) {
            (void)atomic_fetch_add(&g_metrics.role_reject_total, 1UL);
            if (role == CONNECTOR_ROLE_MAINTENANCE) do_ssl_writestr(ssl, "error: maintenance\n");
            else do_ssl_writestr(ssl, "error: standby\n");
            return;
        }
    }

    if (a && b && !c) {
        (void)atomic_fetch_add(&g_metrics.login_request_total, 1UL);
        char salt[64] = {0};
        char hash[128] = {0};
        char auth[32] = {0};

        if (!db_get_login_info(w, a, client_ip, salt, sizeof(salt), hash, sizeof(hash), auth, sizeof(auth))) {
            DBG("worker[%d] login SQL response null", w->id);
            (void)atomic_fetch_add(&g_metrics.login_fail_total, 1UL);
            do_ssl_writestr(ssl, "null\n");
            return;
        }

        char combined[1024];
        snprintf(combined, sizeof(combined), "%s%s", salt, b);
        DBG("worker[%d] password hash input prepared", w->id);

        unsigned char hash_bin[SHA256_DIGEST_LENGTH];
        unsigned int mdlen = 0;
        EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
        if (!mdctx) {
            DBG("worker[%d] EVP_MD_CTX_new failed", w->id);
            (void)atomic_fetch_add(&g_metrics.login_fail_total, 1UL);
            do_ssl_writestr(ssl, "null\n");
            return;
        }
        if (EVP_DigestInit_ex(mdctx, EVP_sha256(), NULL) != 1 ||
            EVP_DigestUpdate(mdctx, combined, strlen(combined)) != 1 ||
            EVP_DigestFinal_ex(mdctx, hash_bin, &mdlen) != 1 ||
            mdlen != SHA256_DIGEST_LENGTH) {
            EVP_MD_CTX_free(mdctx);
            DBG("worker[%d] password digest failed", w->id);
            (void)atomic_fetch_add(&g_metrics.login_fail_total, 1UL);
            do_ssl_writestr(ssl, "null\n");
            return;
        }
        EVP_MD_CTX_free(mdctx);

        char hash_input[65];
        for (int i = 0; i < 32; i++) sprintf(hash_input + i * 2, "%02x", hash_bin[i]);
        hash_input[64] = '\0';

        DBG("worker[%d] comparing password verifier", w->id);

        if (strcmp(hash_input, hash) != 0) {
            DBG("worker[%d] auth failed", w->id);
            (void)atomic_fetch_add(&g_metrics.login_fail_total, 1UL);
            do_ssl_writestr(ssl, "error: auth failed\n");
            return;
        }

        char *t = token_encode(a, client_ip, auth, key);
        if (!t) {
            DBG("worker[%d] token generation failed", w->id);
            (void)atomic_fetch_add(&g_metrics.login_fail_total, 1UL);
            do_ssl_writestr(ssl, "null\n");
            return;
        }

        int m = snprintf(wbuf, sizeof(wbuf), "%s\n", t);
        DBG("worker[%d] login success", w->id);
        free(t);

        if (m < 0 || (size_t)m >= sizeof(wbuf)) {
            DBG("worker[%d] response buffer overflow on token", w->id);
            (void)atomic_fetch_add(&g_metrics.login_fail_total, 1UL);
            do_ssl_writestr(ssl, "null\n");
            return;
        }
        (void)atomic_fetch_add(&g_metrics.login_ok_total, 1UL);
        do_ssl_writestr(ssl, wbuf);
        return;
    }

    if (a && b && c && d) {
        (void)atomic_fetch_add(&g_metrics.secret_request_total, 1UL);
        char *u = NULL;
        char *tip = NULL;
        long exp = 0;

        if (!token_verify(a, key, client_ip, &u, &tip, &exp)) {
            DBG("worker[%d] token verify failed", w->id);
            (void)atomic_fetch_add(&g_metrics.secret_fail_total, 1UL);
            free(u);
            free(tip);
            do_ssl_writestr(ssl, "null\n");
            return;
        }

        DBG("worker[%d] token verify ok user=%s token_ip=%s exp=%ld", w->id, u, tip, exp);

        char *sec = db_get_secret_password(w, u, client_ip, b, c, d);
        free(u);
        free(tip);

        if (!sec) {
            DBG("worker[%d] secret SQL returned null", w->id);
            (void)atomic_fetch_add(&g_metrics.secret_fail_total, 1UL);
            do_ssl_writestr(ssl, "null\n");
            return;
        }

        char *pw = aes_decrypt_db(sec, key);
        DBG("worker[%d] secret decryption result=%s", w->id, pw ? "OK" : "NULL");
        free(sec);

        if (!pw || strcmp(pw, "(decrypt error)") == 0) {
            DBG("worker[%d] decrypted secret invalid", w->id);
            (void)atomic_fetch_add(&g_metrics.secret_fail_total, 1UL);
            free(pw);
            do_ssl_writestr(ssl, "null\n");
            return;
        }

        int m = snprintf(wbuf, sizeof(wbuf), "%s\n", pw);
        free(pw);
        if (m < 0 || (size_t)m >= sizeof(wbuf)) {
            DBG("worker[%d] response buffer overflow on password", w->id);
            (void)atomic_fetch_add(&g_metrics.secret_fail_total, 1UL);
            do_ssl_writestr(ssl, "null\n");
            return;
        }
        (void)atomic_fetch_add(&g_metrics.secret_ok_total, 1UL);
        do_ssl_writestr(ssl, wbuf);
        return;
    }

    (void)atomic_fetch_add(&g_metrics.invalid_request_total, 1UL);
    DBG("worker[%d] invalid request format", w->id);
    do_ssl_writestr(ssl, "null\n");
}

static void handle_connection(worker_ctx_t *w, int fd, const struct sockaddr_in *addr, const unsigned char *key) {
    char client_ip[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &addr->sin_addr, client_ip, sizeof(client_ip));

    (void)atomic_fetch_add(&g_metrics.active_connections, 1UL);
    DBG("worker[%d] handling fd=%d ip=%s", w->id, fd, client_ip);

    (void)set_common_sockopts(fd);
    if (set_nonblocking_fd(fd) != 0) {
        DBG("worker[%d] failed to set nonblocking fd=%d", w->id, fd);
        close(fd);
        (void)atomic_fetch_sub(&g_metrics.active_connections, 1UL);
        return;
    }

    SSL *ssl = SSL_new(g_ssl_ctx);
    if (!ssl) {
        DBG("worker[%d] SSL_new failed fd=%d", w->id, fd);
        (void)atomic_fetch_add(&g_metrics.tls_fail_total, 1UL);
        close(fd);
        (void)atomic_fetch_sub(&g_metrics.active_connections, 1UL);
        return;
    }

    SSL_set_fd(ssl, fd);

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
    SSL_set_options(ssl, SSL_OP_IGNORE_UNEXPECTED_EOF);
#endif

    if (ssl_accept_with_timeout(ssl, g_handshake_timeout_sec) != 0) {
        DBG("worker[%d] SSL_accept failed/timeout fd=%d ip=%s errno=%d",
            w->id, fd, client_ip, errno);
        if (errno == ETIMEDOUT) (void)atomic_fetch_add(&g_metrics.tls_timeout_total, 1UL);
        else (void)atomic_fetch_add(&g_metrics.tls_fail_total, 1UL);
        if (g_debug) ERR_print_errors_fp(stderr);
        SSL_free(ssl);
        close(fd);
        (void)atomic_fetch_sub(&g_metrics.active_connections, 1UL);
        return;
    }

    (void)atomic_fetch_add(&g_metrics.tls_ok_total, 1UL);
    DBG("worker[%d] TLS handshake complete fd=%d ip=%s", w->id, fd, client_ip);
    log_peer_cert(ssl);
    process_request(w, ssl, client_ip, key);

    DBG("worker[%d] closing fd=%d ip=%s", w->id, fd, client_ip);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    close(fd);
    (void)atomic_fetch_sub(&g_metrics.active_connections, 1UL);
}

static void *worker_thread_main(void *arg) {
    worker_ctx_t *w = (worker_ctx_t *)arg;
    unsigned char key[32];
    hex2bin(KEY_HEX, key);

    DBG("worker[%d] started", w->id);

    if (open_worker_db(w) != 0) {
        fprintf(stderr, "worker[%d] failed to open DB at startup\n", w->id);
    }

    while (!g_stop) {
        conn_job_t job;
        if (queue_pop(&g_queue, &job) != 0) break;
        handle_connection(w, job.fd, &job.addr, key);
    }

    worker_db_close(w);
    OPENSSL_cleanse(key, sizeof(key));
    DBG("worker[%d] exited", w->id);
    return NULL;
}

static void *db_watch_thread(void *arg) {
    (void)arg;

    char tmp1[PATH_MAX];
    char tmp2[PATH_MAX];
    char dir[PATH_MAX];
    char file[PATH_MAX];

    snprintf(tmp1, sizeof(tmp1), "%s", g_db_path);
    snprintf(tmp2, sizeof(tmp2), "%s", g_db_path);
    snprintf(file, sizeof(file), "%s", basename(tmp1));
    snprintf(dir, sizeof(dir), "%s", dirname(tmp2));

    DBG("DB watch dir=%s file=%s", dir, file);
    atomic_store(&g_dbwatch_alive, 1);

    int fd = -1;
    int wd = -1;
    int had_inotify_failure = 0;
    int64_t next_inotify_retry_ms = 0;
    int64_t next_stat_check_ms = 0;
    struct stat last_seen;
    int have_last_seen = (snapshot_path_stat(&last_seen) == 0);

    char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));

    while (!g_stop) {
        int64_t now_ms = monotonic_ms();
        if (now_ms < 0) now_ms = 0;

        if (fd < 0 && now_ms >= next_inotify_retry_ms) {
            fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
            if (fd >= 0) {
                wd = inotify_add_watch(fd, dir,
                    IN_CLOSE_WRITE | IN_MOVED_TO | IN_ATTRIB | IN_CREATE | IN_DELETE);
                if (wd < 0) {
                    DBG("inotify_add_watch failed for %s: %s; using stat fallback", dir, strerror(errno));
                    close(fd);
                    fd = -1;
                    had_inotify_failure = 1;
                    next_inotify_retry_ms = now_ms + (int64_t)INOTIFY_RETRY_INTERVAL_SEC * 1000LL;
                } else {
                    if (had_inotify_failure) {
                        (void)atomic_fetch_add(&g_metrics.dbwatch_recover_total, 1UL);
                        DBG("inotify watcher recovered");
                    }
                    had_inotify_failure = 0;
                }
            } else {
                DBG("inotify_init1 failed: %s; using stat fallback", strerror(errno));
                had_inotify_failure = 1;
                next_inotify_retry_ms = now_ms + (int64_t)INOTIFY_RETRY_INTERVAL_SEC * 1000LL;
            }
        }

        int event_reload = 0;
        if (fd >= 0) {
            struct pollfd pfd = {.fd = fd, .events = POLLIN, .revents = 0};
            int prc = poll(&pfd, 1, 500);
            if (prc < 0) {
                if (errno != EINTR) {
                    DBG("inotify poll failed: %s; switching to stat fallback", strerror(errno));
                    if (wd >= 0) (void)inotify_rm_watch(fd, wd);
                    close(fd);
                    fd = -1;
                    wd = -1;
                    had_inotify_failure = 1;
                    next_inotify_retry_ms = monotonic_ms() + (int64_t)INOTIFY_RETRY_INTERVAL_SEC * 1000LL;
                }
            } else if (prc > 0 && (pfd.revents & POLLIN)) {
                ssize_t len = read(fd, buf, sizeof(buf));
                if (len > 0) {
                    for (char *p = buf; p < buf + len; ) {
                        struct inotify_event *ev = (struct inotify_event *)p;
                        if ((ev->mask & IN_Q_OVERFLOW) != 0) {
                            event_reload = 1;
                        } else if (ev->len > 0 && strcmp(ev->name, file) == 0) {
                            event_reload = 1;
                            DBG("DB filesystem event file=%s mask=0x%x", ev->name, ev->mask);
                        }
                        p += sizeof(struct inotify_event) + ev->len;
                    }
                } else if (len < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                    DBG("inotify read failed: %s; switching to stat fallback", strerror(errno));
                    if (wd >= 0) (void)inotify_rm_watch(fd, wd);
                    close(fd);
                    fd = -1;
                    wd = -1;
                    had_inotify_failure = 1;
                    next_inotify_retry_ms = monotonic_ms() + (int64_t)INOTIFY_RETRY_INTERVAL_SEC * 1000LL;
                }
            } else if (prc > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                DBG("inotify fd error revents=0x%x; switching to stat fallback", pfd.revents);
                if (wd >= 0) (void)inotify_rm_watch(fd, wd);
                close(fd);
                fd = -1;
                wd = -1;
                had_inotify_failure = 1;
                next_inotify_retry_ms = monotonic_ms() + (int64_t)INOTIFY_RETRY_INTERVAL_SEC * 1000LL;
            }
        } else {
            (void)poll(NULL, 0, 500);
        }

        now_ms = monotonic_ms();
        int stat_reload = 0;
        struct stat current;
        int have_current = 0;
        if (now_ms >= next_stat_check_ms) {
            next_stat_check_ms = now_ms + (int64_t)DB_STAT_FALLBACK_INTERVAL_SEC * 1000LL;
            if (snapshot_path_stat(&current) == 0) {
                have_current = 1;
                if (!have_last_seen || snapshot_stat_differs(&last_seen, &current)) stat_reload = 1;
            } else if (have_last_seen) {
                stat_reload = 1;
            }
        }

        if (event_reload && !have_current) {
            if (snapshot_path_stat(&current) == 0) have_current = 1;
        }

        if (event_reload || stat_reload) {
            if (have_current) {
                last_seen = current;
                have_last_seen = 1;
            } else {
                have_last_seen = 0;
            }

            int candidate_fd = -1;
            struct stat candidate_st;
            if (open_validated_snapshot_candidate(g_db_path, &candidate_fd, &candidate_st) == 0) {
                unsigned long new_epoch = 0;
                if (publish_snapshot_lkg(candidate_fd, &candidate_st, 1, &new_epoch) == 0) {
                    (void)atomic_fetch_add(&g_metrics.db_reload_ok_total, 1UL);
                    DBG("DB validation OK; publishing last-known-good snapshot epoch=%lu", new_epoch);
                } else {
                    (void)atomic_fetch_add(&g_metrics.db_reload_fail_total, 1UL);
                    DBG("DB last-known-good publish FAILED; retaining epoch=%lu", atomic_load(&g_db_epoch));
                }
                close(candidate_fd);
            } else {
                (void)atomic_fetch_add(&g_metrics.db_reload_fail_total, 1UL);
                DBG("DB validation FAILED; retaining last-known-good snapshot epoch=%lu", atomic_load(&g_db_epoch));
            }
        }
    }

    if (fd >= 0) {
        if (wd >= 0) (void)inotify_rm_watch(fd, wd);
        close(fd);
    }
    atomic_store(&g_dbwatch_alive, 0);
    DBG("DB watch thread exited");
    return NULL;
}

int main(int argc, char **argv) {
    server_opts_t opts;
    parse_args(argc, argv, &opts);

    g_debug = opts.debug;
    g_strict_tls = opts.strict_tls;
    g_handshake_timeout_sec = opts.handshake_timeout_sec;
    g_io_timeout_sec = opts.io_timeout_sec;
    g_cert_warn_days = opts.cert_warn_days;
    g_snapshot_warn_age_sec = opts.snapshot_warn_age_sec;
    g_status_interval_sec = opts.status_interval_sec;
    g_token_binding_mode = opts.token_binding_mode;
    atomic_store(&g_connector_role, (int)opts.initial_role);
    snprintf(g_role_file, sizeof(g_role_file), "%s", opts.role_file);
    if (init_instance_identity(opts.instance_id) != 0) {
        fprintf(stderr, "connector instance identity initialization failed\n");
        return 1;
    }
    snprintf(g_db_path, sizeof(g_db_path), "%s", opts.db_path);
    snprintf(g_runtime_dir, sizeof(g_runtime_dir), "%s", opts.runtime_dir);
    if (snprintf(g_lkg_path, sizeof(g_lkg_path), "%s/snapshot.lkg.db", g_runtime_dir) >= (int)sizeof(g_lkg_path)) {
        fprintf(stderr, "runtime directory path too long\n");
        return 1;
    }

    DBG("Starting worker-pool server");
    DBG("version=%s node=%s role=%s token_binding=%s port=%d strict_tls=%d debug=%d workers=%d handshake_timeout=%d io_timeout=%d cert_warn_days=%d snapshot_warn_age=%d status_interval=%d db=%s",
        EPV_VERSION, g_instance_id, connector_role_name((connector_role_t)atomic_load(&g_connector_role)), token_binding_name(g_token_binding_mode),
        opts.port, opts.strict_tls, opts.debug, opts.workers,
        opts.handshake_timeout_sec, opts.io_timeout_sec, opts.cert_warn_days,
        opts.snapshot_warn_age_sec, opts.status_interval_sec, g_db_path);
    DBG("runtime_dir=%s lkg_path=%s role_file=%s", g_runtime_dir, g_lkg_path,
        g_role_file[0] ? g_role_file : "(none)");
    refresh_connector_role(1);

    if (pipe2(g_signal_pipe, O_NONBLOCK | O_CLOEXEC) != 0) die("pipe2 failed");
    if (install_signal_handlers() != 0) die("sigaction failed");

    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();

    g_ssl_ctx = SSL_CTX_new(TLS_server_method());
    if (!g_ssl_ctx) ssl_die("SSL_CTX_new failed");
#if defined(TLS1_2_VERSION)
    if (SSL_CTX_set_min_proto_version(g_ssl_ctx, TLS1_2_VERSION) != 1)
        ssl_die("SSL_CTX_set_min_proto_version TLS1.2 failed");
#endif
    SSL_CTX_set_mode(g_ssl_ctx, SSL_MODE_RELEASE_BUFFERS);

#if OPENSSL_VERSION_NUMBER >= 0x30000000L
    SSL_CTX_set_options(g_ssl_ctx, SSL_OP_IGNORE_UNEXPECTED_EOF);
#endif

    if (SSL_CTX_use_certificate_file(g_ssl_ctx, CERT_FILE, SSL_FILETYPE_PEM) != 1)
        ssl_die("SSL_CTX_use_certificate_file failed");
    if (SSL_CTX_use_PrivateKey_file(g_ssl_ctx, KEY_FILE, SSL_FILETYPE_PEM) != 1)
        ssl_die("SSL_CTX_use_PrivateKey_file failed");
    if (SSL_CTX_check_private_key(g_ssl_ctx) != 1)
        ssl_die("SSL_CTX_check_private_key failed");

    if (opts.strict_tls) {
        DBG("Client cert verification enabled");
        if (SSL_CTX_load_verify_locations(g_ssl_ctx, CA_FILE, NULL) != 1)
            ssl_die("SSL_CTX_load_verify_locations failed");
        SSL_CTX_set_verify(g_ssl_ctx, SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, NULL);
        SSL_CTX_set_verify_depth(g_ssl_ctx, 4);
    } else {
        DBG("Client cert verification disabled");
        SSL_CTX_set_verify(g_ssl_ctx, SSL_VERIFY_NONE, NULL);
    }

    if (ensure_runtime_dir() != 0) {
        fprintf(stderr, "runtime directory initialization failed: %s\n", g_runtime_dir);
        return 1;
    }
    {
        int initial_fd = -1;
        struct stat initial_st;
        if (open_validated_snapshot_candidate(g_db_path, &initial_fd, &initial_st) != 0) {
            fprintf(stderr, "snapshot validation failed at startup: %s\n", g_db_path);
            return 1;
        }
        if (publish_snapshot_lkg(initial_fd, &initial_st, 0, NULL) != 0) {
            close(initial_fd);
            fprintf(stderr, "last-known-good snapshot publish failed: %s\n", g_lkg_path);
            return 1;
        }
        close(initial_fd);
    }
    DBG("Initial snapshot validation OK and last-known-good runtime copy published");

    g_listen_fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (g_listen_fd < 0) die("socket failed");

    int one = 1;
    if (setsockopt(g_listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0)
        die("setsockopt SO_REUSEADDR failed");

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)opts.port);
    a.sin_addr.s_addr = INADDR_ANY;

    if (bind(g_listen_fd, (struct sockaddr *)&a, sizeof(a)) < 0)
        die("bind failed");
    if (listen(g_listen_fd, 4096) < 0)
        die("listen failed");

    g_reserve_fd = open_reserve_fd();

    queue_init(&g_queue);
    token_store_init(&g_token_store);

    g_worker_threads = calloc((size_t)opts.workers, sizeof(*g_worker_threads));
    g_workers = calloc((size_t)opts.workers, sizeof(*g_workers));
    if (!g_worker_threads || !g_workers) {
        fprintf(stderr, "worker allocation failed\n");
        exit(1);
    }

    for (int i = 0; i < opts.workers; i++) {
        g_workers[i].id = i;
        if (pthread_create(&g_worker_threads[i], NULL, worker_thread_main, &g_workers[i]) != 0) {
            die("pthread_create(worker) failed");
        }
    }

    atomic_store(&g_dbwatch_alive, 1);
    if (pthread_create(&g_dbwatch_thread, NULL, db_watch_thread, NULL) != 0) {
        atomic_store(&g_dbwatch_alive, 0);
        die("pthread_create(db_watch_thread) failed");
    }

    g_start_monotonic_ms = monotonic_ms();
    g_last_health_check_ms = 0;
    g_last_status_ms = g_start_monotonic_ms;
    init_systemd_watchdog();
    g_last_watchdog_ms = g_start_monotonic_ms;

    DBG("Server listening on port %d", opts.port);
    {
        char ready[256];
        snprintf(ready, sizeof(ready), "READY=1\nSTATUS=EPV API Connector v%s node=%s role=%s ready on port %d",
                 EPV_VERSION, g_instance_id,
                 connector_role_name((connector_role_t)atomic_load(&g_connector_role)), opts.port);
        (void)sd_notify_message(ready);
    }
    print_runtime_status("startup");

    while (!g_stop) {
        struct pollfd pfds[2];
        pfds[0].fd = g_listen_fd;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = g_signal_pipe[0];
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;

        int prc = poll(pfds, 2, 1000);
        if (prc < 0) {
            if (errno == EINTR) {
                run_periodic_tasks();
                continue;
            }
            DBG("main poll failed: %s", strerror(errno));
            break;
        }
        if (pfds[1].revents & POLLIN) {
            unsigned char drain[64];
            while (read(g_signal_pipe[0], drain, sizeof(drain)) > 0) {}
        }
        run_periodic_tasks();
        if (g_stop) break;
        if (prc == 0 || !(pfds[0].revents & POLLIN)) continue;

        for (;;) {
            struct sockaddr_in c;
            socklen_t l = sizeof(c);
            int fd = accept4(g_listen_fd, (struct sockaddr *)&c, &l, SOCK_CLOEXEC | SOCK_NONBLOCK);
            if (fd < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                if (errno == EINTR) continue;
                if (errno == EMFILE || errno == ENFILE) {
                    DBG("accept resource limit reached errno=%d; using reserve-fd recovery", errno);
                    recover_from_fd_exhaustion();
                    (void)poll(NULL, 0, 100);
                    break;
                }
                if (g_stop) break;
                DBG("accept4 failed errno=%d", errno);
                break;
            }

            (void)atomic_fetch_add(&g_metrics.accepted_total, 1UL);
            char ip[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &c.sin_addr, ip, sizeof(ip));
            DBG("Accepted fd=%d ip=%s", fd, ip);

            conn_job_t job;
            job.fd = fd;
            job.addr = c;

            int qrc = queue_try_push(&g_queue, &job);
            if (qrc != 0) {
                if (qrc == -2) (void)atomic_fetch_add(&g_metrics.queue_dropped_total, 1UL);
                DBG("Queue unavailable/full rc=%d; closing fd=%d", qrc, fd);
                close(fd);
                if (qrc == -1) break;
            }
        }
    }

    g_stop = 1;
    print_runtime_status("shutdown");
    (void)sd_notify_message("STOPPING=1\nSTATUS=EPV API Connector v2.2 shutting down");
    queue_stop_and_close_pending(&g_queue);

    if (g_dbwatch_thread) pthread_join(g_dbwatch_thread, NULL);

    for (int i = 0; i < opts.workers; i++) {
        pthread_join(g_worker_threads[i], NULL);
    }

    free(g_worker_threads);
    free(g_workers);

    token_store_destroy(&g_token_store);
    queue_destroy(&g_queue);

    if (g_listen_fd >= 0) {
        close(g_listen_fd);
        g_listen_fd = -1;
    }
    if (g_signal_pipe[0] >= 0) close(g_signal_pipe[0]);
    if (g_signal_pipe[1] >= 0) close(g_signal_pipe[1]);
    if (g_reserve_fd >= 0) {
        close(g_reserve_fd);
        g_reserve_fd = -1;
    }
    if (g_lkg_path[0] != '\0') (void)unlink(g_lkg_path);

    if (g_ssl_ctx) SSL_CTX_free(g_ssl_ctx);

    EVP_cleanup();
    ERR_free_strings();

    DBG("Server shutdown complete");
    return 0;
}
