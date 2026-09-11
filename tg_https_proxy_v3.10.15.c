#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <ctype.h>
#include <curl/curl.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <limits.h>
#include <netdb.h>
#include <openssl/evp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/time.h>
#include <sys/types.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#ifndef NI_MAXHOST
#define NI_MAXHOST 1025
#endif

#define PROGRAM_VERSION              "3.10.15"
#define DEFAULT_BIND_ADDR            "0.0.0.0"
#define DEFAULT_CONFIG_FILE          "/etc/tg_https_proxy.conf"
#define DEFAULT_FILTER_FILE          "/etc/tg_https_proxy.filters"
#define DEFAULT_SPOOL_DIR            "/var/lib/tg_https_proxy/spool"
#define DEFAULT_WORKERS              4
#define MAX_WORKERS                  32
#define MAX_CHANNELS                 128
#define MAX_SELECTED_PORTS           128
#define MAX_ALLOWED_CLIENTS          128
#define ALLOW_RULE_TEXT_SIZE          80
#define MAX_HEADER_SIZE              16384
#define MAX_REQUEST_BODY             (20U * 1024U * 1024U)
#define SENDMESSAGE_MAX_BODY         (64U * 1024U)
#define SENDPHOTO_MAX_BYTES          (10U * 1024U * 1024U)
#define TELEGRAM_CAPTION_MAX_CHARS   1024U
#define MAX_RESPONSE_BODY            (2U * 1024U * 1024U)
#define MAX_INGEST_THREADS            64
#define CLIENT_IO_TIMEOUT_SEC        30
#define HTTP_HEADER_DEADLINE_MS      10000LL
#define REQUEST_TOTAL_DEADLINE_MS    60000LL
#define UPSTREAM_CONNECT_SEC         10L
#define UPSTREAM_TOTAL_SEC           60L
#define TOKEN_SIZE                   256
#define CHAT_ID_SIZE                 64
#define LABEL_SIZE                   128
#define PATH_SIZE                    256
#define REQUEST_TARGET_SIZE          8192
#define CONTENT_TYPE_SIZE            128
#define CAPTION_SIZE                 2048
#define PARSE_MODE_SIZE              64
#define JOB_ID_SIZE                  96
#define SPOOL_PATH_SIZE              PATH_MAX
#define SPOOL_FORMAT_VERSION         2
#define SPOOL_MIN_FREE_BYTES         (128ULL * 1024ULL * 1024ULL)
#define WORKER_IDLE_WAKE_SEC          1
#define PROTOCOL_DETECT_TIMEOUT_MS    2000
#define STALE_TMP_AGE_SEC             3600LL
#define AUDIT_TEXT_RAW_CHUNK         256U
#define AUDIT_BINARY_RAW_CHUNK       768U
#define TELEGRAM_SENDMESSAGE_MAX_CHARS 4096U
#define MAX_FILTER_PATTERNS           128U
#define FILTER_NAME_SIZE              64U
#define FILTER_PATTERN_SIZE           512U
#define IDEMPOTENCY_KEY_SIZE          128U
#define IDEMPOTENCY_RETENTION_SEC     86400LL
#define RETRY_JITTER_PERCENT          20L
#define CIRCUIT_FAILURE_THRESHOLD     5U
#define CIRCUIT_OPEN_MS               30000LL
#define MAX_TOKEN_STATES              MAX_CHANNELS
#define MAINTENANCE_MAGIC_ON          "__TG_MAINTENANCE_ON__"
#define MAINTENANCE_MAGIC_OFF         "__TG_MAINTENANCE_OFF__"
#define MAINTENANCE_MAGIC_STATUS      "__TG_MAINTENANCE_STATUS__"
#define MAINTENANCE_MAGIC_ON_30M      "__TG_MAINTENANCE_ON_30M__"
#define MAINTENANCE_MAGIC_ON_PREFIX   "__TG_MAINTENANCE_ON__:"
#define MAINTENANCE_MAGIC_EXTEND_PREFIX "__TG_MAINTENANCE_EXTEND__:"
#define MAINTENANCE_MAGIC_MARK_PREFIX "__TG_MAINTENANCE_MARK__:"
#define TEST_LOG_ONLY_PREFIX          "__TG_TEST_LOG_ONLY__:"
#define MAINTENANCE_REASON_SIZE       256U
#define MAINTENANCE_MAX_TTL_SEC       604800ULL
#define MAINTENANCE_COUNT_CHECKPOINT  100ULL
#define MAGIC_TEST_TEXT_SIZE          8192U
#define MAINT_NOTICE_TEXT_SIZE        2048U
#define MAINT_NOTICE_TRIGGER_SIZE      64U
#define MAINT_NOTICE_CONNECT_SEC       3L
#define MAINT_NOTICE_TOTAL_SEC         5L

/* Production queue guardrails.  These are intentionally conservative and
 * can be adjusted at compile time for larger installations. */
#define MAX_PENDING_JOBS              10000U
#define MAX_FAILED_JOBS               10000U
#define MAX_SPOOL_BYTES               (10ULL * 1024ULL * 1024ULL * 1024ULL)
#define HEALTH_PENDING_DEGRADED       1000U
#define HEALTH_OLDEST_PENDING_SEC     300LL

/* Production policy: stay below Telegram's nominal 20/minute group-chat
 * ceiling. 18/minute provides rolling-window headroom while preserving a
 * smooth send cadence.
 */
#define CHANNEL_MAX_PER_MINUTE       18L
#define CHANNEL_WINDOW_SEC           60L
#define CHANNEL_SPACING_MS           (((CHANNEL_WINDOW_SEC * 1000L) + CHANNEL_MAX_PER_MINUTE - 1L) / CHANNEL_MAX_PER_MINUTE)

/* Persistent retry policy. The attempt count is encoded in the pending spool
 * filename, so restart does not reset retry history.
 */
#define UPSTREAM_MAX_ATTEMPTS        4U
#define UPSTREAM_BACKOFF_BASE_MS     1000L
#define UPSTREAM_BACKOFF_MAX_MS      8000L
#define UPSTREAM_RETRY_AFTER_MAX_SEC 3600L
#define RATE_LIMIT_SAFETY_MARGIN_MS   1000L
#define RATE_LIMIT_DEFAULT_DEFER_MS   10000L
#define RATE_LIMIT_ADAPTIVE_1_MS      9000L
#define RATE_LIMIT_ADAPTIVE_2_MS      18000L
#define RATE_LIMIT_ADAPTIVE_3_MS      36000L
#define RATE_LIMIT_ADAPTIVE_4_MS      60000L
#define RATE_LIMIT_ADAPTIVE_5_MS      120000L
#define MAX_JOB_AGE_SEC               86400LL

struct channel {
    int port;
    char token[TOKEN_SIZE];
    char chat_id[CHAT_ID_SIZE];
    char label[LABEL_SIZE];
    int listen_fd;
    bool selected;
    bool maintenance_suppress;
    int64_t maintenance_since_ms;
    int64_t maintenance_expires_ms;
    char maintenance_reason[MAINTENANCE_REASON_SIZE];
    char maintenance_enabled_by[NI_MAXHOST];
    uint64_t maintenance_suppressed_count;
    uint64_t maintenance_generation;
    int64_t maintenance_notice_message_id;
    int64_t maintenance_notice_stale_message_id;
    bool maintenance_notice_state_valid;
    bool maintenance_notice_state_on;
};

struct http_request {
    char method[16];
    char path[PATH_SIZE];
    char version[16];
    char content_type[CONTENT_TYPE_SIZE];
    char caption[CAPTION_SIZE];
    char parse_mode[PARSE_MODE_SIZE];
    char filename[NAME_MAX + 1];
    char idempotency_key[IDEMPOTENCY_KEY_SIZE + 1U];
    char original_method[16];
    bool query_sendmessage_compat;
    bool compat_header_text_query;
    bool method_compat_normalized;
    size_t content_length;
    unsigned char *body;
};

struct mem_buf {
    char *data;
    size_t len;
    size_t cap;
    bool overflow;
};

struct retry_header_state {
    long retry_after_sec;
};

struct spool_job {
    int spool_version;
    char job_id[JOB_ID_SIZE];
    int64_t created_ms;
    int listen_port;
    char client_ip[NI_MAXHOST];
    unsigned client_port;
    char endpoint[PATH_SIZE];
    char token[TOKEN_SIZE];
    char chat_id[CHAT_ID_SIZE];
    char label[LABEL_SIZE];
    char content_type[CONTENT_TYPE_SIZE];
    char caption[CAPTION_SIZE];
    char parse_mode[PARSE_MODE_SIZE];
    char filename[NAME_MAX + 1];
    char body_sha256[65];
    size_t body_len;
    unsigned char *body;
};

struct message_filter_pattern {
    char name[FILTER_NAME_SIZE];
    char needle[FILTER_PATTERN_SIZE];
};

struct token_circuit_state {
    char token_hash[65];
    unsigned consecutive_failures;
    int64_t open_until_ms;
    bool half_open;
    bool probe_inflight;
};

struct bot_rate_state {
    int64_t cooldown_until_ms;
    unsigned consecutive_429;
    bool recovery_required;
};

struct token_rate_probe_state {
    char token_hash[65];
    bool probe_inflight;
};

struct ingest_ctx {
    int fd;
    char client_ip[NI_MAXHOST];       /* effective/original client IP */
    unsigned client_port;
    char peer_ip[NI_MAXHOST];         /* direct TCP peer, e.g. Host B */
    unsigned peer_port;
    bool proxy_protocol_used;
    struct channel *ch;
};

struct pending_item {
    char basename[NAME_MAX + 1];
    int64_t due_ms;
    unsigned attempts_done;
    unsigned rate_limit_deferrals;
    char job_id[JOB_ID_SIZE];
};

struct send_result {
    CURLcode curl_code;
    long http_code;
    long retry_after_sec;
    char error[CURL_ERROR_SIZE];
    char telegram_description[512];
};

struct dir_summary {
    size_t count;
    unsigned long long bytes;
    int64_t oldest_mtime_ms;
};

struct queue_summary {
    struct dir_summary pending;
    struct dir_summary working;
    struct dir_summary failed;
    unsigned long long total_bytes;
    unsigned long long free_bytes;
};

struct runtime_metrics {
    uint64_t enqueued_total;
    uint64_t sent_total;
    uint64_t failed_total;
    uint64_t retries_total;
    uint64_t rate_deferred_total;
    uint64_t telegram_429_deferred_total;
    uint64_t capacity_reject_total;
    uint64_t filtered_total;
    uint64_t suppressed_total;
    uint64_t maintenance_toggle_total;
    uint64_t maintenance_auto_expire_total;
    uint64_t maintenance_mark_total;
    uint64_t test_log_only_total;
    uint64_t maintenance_notice_sent_total;
    uint64_t maintenance_notice_pin_total;
    uint64_t maintenance_notice_fail_total;
    int64_t last_success_ms;
};

enum metric_kind {
    METRIC_ENQUEUED,
    METRIC_SENT,
    METRIC_FAILED,
    METRIC_RETRY,
    METRIC_RATE_DEFER,
    METRIC_TELEGRAM_429_DEFER,
    METRIC_CAPACITY_REJECT,
    METRIC_FILTERED,
    METRIC_SUPPRESSED,
    METRIC_MAINTENANCE_TOGGLE,
    METRIC_MAINTENANCE_AUTO_EXPIRE,
    METRIC_MAINTENANCE_MARK,
    METRIC_TEST_LOG_ONLY,
    METRIC_MAINTENANCE_NOTICE_SENT,
    METRIC_MAINTENANCE_NOTICE_PIN,
    METRIC_MAINTENANCE_NOTICE_FAIL
};

enum one_shot_mode {
    MODE_DAEMON = 0,
    MODE_CONFIG_TEST,
    MODE_QUEUE_STATUS,
    MODE_FAILED_LIST,
    MODE_FAILED_SHOW,
    MODE_FAILED_RETRY,
    MODE_FAILED_RETRY_ALL,
    MODE_FAILED_DELETE,
    MODE_VALIDATE_TOKENS
};

static struct channel channels[MAX_CHANNELS];
static size_t channel_count = 0;
static int selected_ports[MAX_SELECTED_PORTS];
static size_t selected_port_count = 0;
struct allowed_client_rule {
    int family;
    unsigned prefix_len;
    unsigned char network[16];
    char text[ALLOW_RULE_TEXT_SIZE];
};

static struct allowed_client_rule allowed_clients[MAX_ALLOWED_CLIENTS];
static size_t allowed_client_count = 0;
static struct allowed_client_rule maintenance_control_rules[MAX_ALLOWED_CLIENTS];
static size_t maintenance_control_rule_count = 0;

static volatile sig_atomic_t stop_flag = 0;
static volatile sig_atomic_t reload_flag = 0;
static volatile sig_atomic_t fatal_flag = 0;
static bool sensitive_audit_enabled = false;
static bool full_token_audit_enabled = false;
static bool audit_binary_content_enabled = false;
static bool http_compat_text_query = false;
static bool http_compat_auto_urlencode = false;
static bool proxy_protocol_v1_enabled = false;
static int worker_count = DEFAULT_WORKERS;
static char filter_file[SPOOL_PATH_SIZE] = DEFAULT_FILTER_FILE;
static char spool_root[SPOOL_PATH_SIZE] = DEFAULT_SPOOL_DIR;
static char spool_pending[SPOOL_PATH_SIZE];
static char spool_working[SPOOL_PATH_SIZE];
static char spool_failed[SPOOL_PATH_SIZE];
static char spool_tmp[SPOOL_PATH_SIZE];
static char spool_rate[SPOOL_PATH_SIZE];
static char spool_idempotency[SPOOL_PATH_SIZE];
static char spool_maintenance[SPOOL_PATH_SIZE];

static pthread_t workers[MAX_WORKERS];
static pthread_mutex_t queue_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queue_cond = PTHREAD_COND_INITIALIZER;
static pthread_mutex_t ingest_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t rate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t idempotency_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t circuit_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_rwlock_t filter_lock = PTHREAD_RWLOCK_INITIALIZER;
static pthread_cond_t ingest_cond = PTHREAD_COND_INITIALIZER;
static size_t ingest_threads = 0;
static pthread_mutex_t metrics_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t maintenance_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t maintenance_notice_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t maintenance_notice_thread_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t maintenance_notice_thread_cond = PTHREAD_COND_INITIALIZER;
static size_t maintenance_notice_threads = 0;
static struct runtime_metrics metrics_state;
static int64_t daemon_start_ms = 0;
static struct message_filter_pattern active_filters[MAX_FILTER_PATTERNS];
static size_t active_filter_count = 0;
static struct token_circuit_state token_states[MAX_TOKEN_STATES];
static size_t token_state_count = 0;
static struct token_rate_probe_state token_rate_probes[MAX_TOKEN_STATES];
static size_t token_rate_probe_count = 0;

static char *form_get_value(const unsigned char *body, size_t len, const char *key);
static int send_http_response(int fd, long status, const char *content_type, const void *body, size_t body_len);
static char *trim(char *s);
static int parse_i64_strict(const char *s, int64_t *out);
static int64_t age_seconds_from_ms(int64_t when_ms);
static int parse_allowed_client_rule(const char *input, struct allowed_client_rule *rule);
struct maintenance_notice_event;
static int maintenance_publish_notice(const struct maintenance_notice_event *ev);
static void maintenance_spawn_auto_off_notice(const struct maintenance_notice_event *ev);

static void log_msg(int priority, const char *fmt, ...)
{
    char msg[4096];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    syslog(priority, "%s", msg);
}

static int64_t realtime_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static int64_t monotonic_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static ssize_t recv_deadline(int fd, void *buf, size_t len, int flags,
                             int64_t deadline_ms)
{
    for (;;) {
        int64_t remain = deadline_ms - monotonic_ms();
        struct pollfd pfd;
        int prc;
        if (remain <= 0) { errno = ETIMEDOUT; return -1; }
        if (remain > INT_MAX) remain = INT_MAX;
        memset(&pfd, 0, sizeof(pfd));
        pfd.fd = fd;
        pfd.events = POLLIN;
        do { prc = poll(&pfd, 1, (int)remain); } while (prc < 0 && errno == EINTR);
        if (prc == 0) { errno = ETIMEDOUT; return -1; }
        if (prc < 0) return -1;
        for (;;) {
            ssize_t n = recv(fd, buf, len, flags);
            if (n < 0 && errno == EINTR) continue;
            return n;
        }
    }
}

static void metric_record(enum metric_kind kind)
{
    pthread_mutex_lock(&metrics_mutex);
    switch (kind) {
        case METRIC_ENQUEUED: metrics_state.enqueued_total++; break;
        case METRIC_SENT:
            metrics_state.sent_total++;
            metrics_state.last_success_ms = realtime_ms();
            break;
        case METRIC_FAILED: metrics_state.failed_total++; break;
        case METRIC_RETRY: metrics_state.retries_total++; break;
        case METRIC_RATE_DEFER: metrics_state.rate_deferred_total++; break;
        case METRIC_TELEGRAM_429_DEFER: metrics_state.telegram_429_deferred_total++; break;
        case METRIC_CAPACITY_REJECT: metrics_state.capacity_reject_total++; break;
        case METRIC_FILTERED: metrics_state.filtered_total++; break;
        case METRIC_SUPPRESSED: metrics_state.suppressed_total++; break;
        case METRIC_MAINTENANCE_TOGGLE: metrics_state.maintenance_toggle_total++; break;
        case METRIC_MAINTENANCE_AUTO_EXPIRE: metrics_state.maintenance_auto_expire_total++; break;
        case METRIC_MAINTENANCE_MARK: metrics_state.maintenance_mark_total++; break;
        case METRIC_TEST_LOG_ONLY: metrics_state.test_log_only_total++; break;
        case METRIC_MAINTENANCE_NOTICE_SENT: metrics_state.maintenance_notice_sent_total++; break;
        case METRIC_MAINTENANCE_NOTICE_PIN: metrics_state.maintenance_notice_pin_total++; break;
        case METRIC_MAINTENANCE_NOTICE_FAIL: metrics_state.maintenance_notice_fail_total++; break;
    }
    pthread_mutex_unlock(&metrics_mutex);
}

static void metrics_snapshot(struct runtime_metrics *out)
{
    pthread_mutex_lock(&metrics_mutex);
    *out = metrics_state;
    pthread_mutex_unlock(&metrics_mutex);
}

static void sleep_ms_interruptible(int64_t ms)
{
    while (ms > 0 && !stop_flag) {
        struct timespec ts;
        int64_t chunk = ms > 500 ? 500 : ms;
        ts.tv_sec = (time_t)(chunk / 1000);
        ts.tv_nsec = (long)((chunk % 1000) * 1000000L);
        while (nanosleep(&ts, &ts) != 0 && errno == EINTR && !stop_flag) {}
        ms -= chunk;
    }
}

static int sha256_hex(const unsigned char *data, size_t len, char out[65])
{
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int dlen = 0;
    size_t i;

    if (!ctx) return -1;
    if (EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) != 1 ||
        EVP_DigestUpdate(ctx, data, len) != 1 ||
        EVP_DigestFinal_ex(ctx, digest, &dlen) != 1 || dlen != 32U) {
        EVP_MD_CTX_free(ctx);
        return -1;
    }
    EVP_MD_CTX_free(ctx);
    for (i = 0; i < dlen; i++) snprintf(out + i * 2U, 3U, "%02x", digest[i]);
    out[64] = '\0';
    return 0;
}

static int request_sha256_hex(const struct http_request *req,
                              const struct channel *ch, char out[65])
{
    EVP_MD_CTX *ctx;
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int dlen = 0;
    size_t i;
    static const unsigned char sep = 0;

    if (!req || !ch) return -1;
    ctx = EVP_MD_CTX_new();
    if (!ctx) return -1;
#define HASH_FIELD(p_, n_) do { \
    if (EVP_DigestUpdate(ctx, (p_), (n_)) != 1 || \
        EVP_DigestUpdate(ctx, &sep, 1U) != 1) goto fail; \
} while (0)
    if (EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) != 1) goto fail;
    HASH_FIELD(req->path, strlen(req->path));
    HASH_FIELD(ch->chat_id, strlen(ch->chat_id));
    HASH_FIELD(req->content_type, strlen(req->content_type));
    HASH_FIELD(req->caption, strlen(req->caption));
    HASH_FIELD(req->parse_mode, strlen(req->parse_mode));
    HASH_FIELD(req->filename, strlen(req->filename));
    HASH_FIELD(req->body ? req->body : (const unsigned char *)"", req->content_length);
    if (EVP_DigestFinal_ex(ctx, digest, &dlen) != 1 || dlen != 32U) goto fail;
    EVP_MD_CTX_free(ctx);
    for (i = 0; i < dlen; i++) snprintf(out + i * 2U, 3U, "%02x", digest[i]);
    out[64] = '\0';
#undef HASH_FIELD
    return 0;
fail:
#undef HASH_FIELD
    EVP_MD_CTX_free(ctx);
    return -1;
}

static char *base64_encode_alloc(const unsigned char *data, size_t len)
{
    size_t outlen = 4U * ((len + 2U) / 3U);
    unsigned char *out;
    int rc;

    if (len > INT_MAX) return NULL;
    out = malloc(outlen + 1U);
    if (!out) return NULL;
    rc = EVP_EncodeBlock(out, data, (int)len);
    if (rc < 0) {
        free(out);
        return NULL;
    }
    out[rc] = '\0';
    return (char *)out;
}

static int base64_decode_into(const char *src, unsigned char *dst, size_t dstsz, size_t *outlen)
{
    size_t slen = strlen(src);
    int rc;
    size_t pad = 0;

    if (slen == 0) {
        if (dstsz == 0) return -1;
        dst[0] = '\0';
        *outlen = 0;
        return 0;
    }
    if (slen > INT_MAX || slen % 4U != 0) return -1;
    if (slen >= 1 && src[slen - 1] == '=') pad++;
    if (slen >= 2 && src[slen - 2] == '=') pad++;
    if ((slen / 4U) * 3U > dstsz + pad) return -1;
    rc = EVP_DecodeBlock(dst, (const unsigned char *)src, (int)slen);
    if (rc < 0) return -1;
    if ((size_t)rc < pad) return -1;
    *outlen = (size_t)rc - pad;
    if (*outlen < dstsz) dst[*outlen] = '\0';
    return 0;
}

/* Return the byte length of one valid UTF-8 code point beginning at src.
 * ASCII returns 1. Invalid/truncated UTF-8 returns 0.
 */
static size_t utf8_sequence_len(const unsigned char *src, size_t len)
{
    unsigned char c;
    size_t need, j;
    uint32_t cp;

    if (!src || len == 0U) return 0U;
    c = src[0];
    if (c <= 0x7fU) return 1U;

    if (c >= 0xc2U && c <= 0xdfU) {
        need = 2U;
        cp = (uint32_t)(c & 0x1fU);
    } else if (c >= 0xe0U && c <= 0xefU) {
        need = 3U;
        cp = (uint32_t)(c & 0x0fU);
    } else if (c >= 0xf0U && c <= 0xf4U) {
        need = 4U;
        cp = (uint32_t)(c & 0x07U);
    } else {
        return 0U;
    }

    if (need > len) return 0U;
    for (j = 1U; j < need; j++) {
        unsigned char cc = src[j];
        if ((cc & 0xc0U) != 0x80U) return 0U;
        cp = (cp << 6) | (uint32_t)(cc & 0x3fU);
    }

    if ((need == 2U && cp < 0x80U) ||
        (need == 3U && cp < 0x800U) ||
        (need == 4U && cp < 0x10000U) ||
        (cp >= 0xd800U && cp <= 0xdfffU) ||
        cp > 0x10ffffU)
        return 0U;

    return need;
}

/* Pick a raw audit chunk boundary without splitting a valid UTF-8 code point.
 * Invalid bytes deliberately count as one input byte; audit_escape() converts
 * each such byte to an ASCII \\xNN sequence so the resulting syslog record is
 * always valid UTF-8/ASCII.
 */
static size_t audit_text_chunk_len(const unsigned char *data, size_t remaining,
                                   size_t max_bytes)
{
    size_t off = 0U;

    if (!data || remaining == 0U || max_bytes == 0U) return 0U;
    while (off < remaining && off < max_bytes) {
        size_t seq = utf8_sequence_len(data + off, remaining - off);
        if (seq == 0U) seq = 1U;
        if (seq > max_bytes - off) break;
        off += seq;
    }
    return off;
}

static size_t audit_text_chunk_count(const unsigned char *data, size_t len,
                                     size_t max_bytes)
{
    size_t off = 0U, count = 0U;

    if (!data || len == 0U || max_bytes == 0U) return 0U;
    while (off < len) {
        size_t n = audit_text_chunk_len(data + off, len - off, max_bytes);
        if (n == 0U) return 0U;
        off += n;
        count++;
    }
    return count;
}

/* Escape audit text while preserving complete valid UTF-8 sequences. Invalid
 * UTF-8 bytes are emitted as ASCII \\xNN, preventing MySQL utf8mb4 rejection.
 */
static size_t audit_escape(const unsigned char *src, size_t len, char *dst, size_t dst_size)
{
    size_t i = 0U, o = 0U;

    if (dst_size == 0U) return 0U;
    while (i < len) {
        unsigned char c = src[i];
        const char *rep = NULL;
        char hexbuf[5];
        size_t rlen;

        if (c < 0x80U) {
            switch (c) {
                case '\\': rep = "\\\\"; break;
                case '"': rep = "\\\""; break;
                case '\n': rep = "\\n"; break;
                case '\r': rep = "\\r"; break;
                case '\t': rep = "\\t"; break;
                default:
                    if (c < 0x20U || c == 0x7fU) {
                        snprintf(hexbuf, sizeof(hexbuf), "\\x%02X", c);
                        rep = hexbuf;
                    }
                    break;
            }

            if (rep) {
                rlen = strlen(rep);
                if (o + rlen + 1U > dst_size) break;
                memcpy(dst + o, rep, rlen);
                o += rlen;
            } else {
                if (o + 2U > dst_size) break;
                dst[o++] = (char)c;
            }
            i++;
            continue;
        }

        {
            size_t seq = utf8_sequence_len(src + i, len - i);
            if (seq == 0U) {
                snprintf(hexbuf, sizeof(hexbuf), "\\x%02X", c);
                rlen = strlen(hexbuf);
                if (o + rlen + 1U > dst_size) break;
                memcpy(dst + o, hexbuf, rlen);
                o += rlen;
                i++;
            } else {
                if (o + seq + 1U > dst_size) break;
                memcpy(dst + o, src + i, seq);
                o += seq;
                i += seq;
            }
        }
    }

    dst[o] = '\0';
    return o;
}

static size_t json_escape(const char *src, char *dst, size_t dst_size)
{
    const unsigned char *p = (const unsigned char *)src;
    size_t o = 0;

    if (!dst_size) return 0;
    while (*p) {
        const char *rep = NULL;
        char ubuf[7];
        size_t rlen;

        switch (*p) {
            case '"': rep = "\\\""; break;
            case '\\': rep = "\\\\"; break;
            case '\b': rep = "\\b"; break;
            case '\f': rep = "\\f"; break;
            case '\n': rep = "\\n"; break;
            case '\r': rep = "\\r"; break;
            case '\t': rep = "\\t"; break;
            default:
                if (*p < 0x20) {
                    snprintf(ubuf, sizeof(ubuf), "\\u%04x", (unsigned)*p);
                    rep = ubuf;
                }
                break;
        }
        if (rep) {
            rlen = strlen(rep);
            if (o + rlen + 1U > dst_size) break;
            memcpy(dst + o, rep, rlen);
            o += rlen;
        } else {
            if (o + 2U > dst_size) break;
            dst[o++] = (char)*p;
        }
        p++;
    }
    dst[o] = '\0';
    return o;
}


static void audit_log_credentials(const char *job_id, const char *client_ip,
                                  const struct channel *ch, const char *endpoint)
{
    char token_hash[65] = "unavailable";
    const char *suffix = "";
    size_t tlen;

    if (!sensitive_audit_enabled) return;
    tlen = strlen(ch->token);
    if (tlen > 4U) suffix = ch->token + tlen - 4U;
    else suffix = ch->token;
    (void)sha256_hex((const unsigned char *)ch->token, tlen, token_hash);

    if (full_token_audit_enabled) {
        log_msg(LOG_NOTICE,
                "event=AUDIT_CREDENTIAL version=%s job_id=%s client_ip=%s listen_port=%d "
                "label=%s endpoint=%s bot_token=\"%s\" token_redacted=no chat_id=\"%s\"",
                PROGRAM_VERSION, job_id, client_ip, ch->port, ch->label,
                endpoint, ch->token, ch->chat_id);
    } else {
        log_msg(LOG_NOTICE,
                "event=AUDIT_CREDENTIAL version=%s job_id=%s client_ip=%s listen_port=%d "
                "label=%s endpoint=%s bot_token_sha256=%s bot_token_suffix=\"%s\" "
                "token_redacted=yes chat_id=\"%s\"",
                PROGRAM_VERSION, job_id, client_ip, ch->port, ch->label,
                endpoint, token_hash, suffix, ch->chat_id);
    }
}

static void audit_log_text(const char *job_id, const char *client_ip,
                           const struct channel *ch, const char *endpoint,
                           const char *field, const unsigned char *data, size_t len)
{
    size_t total, seq = 1U, off = 0U;

    if (!sensitive_audit_enabled || !data) return;
    if (len == 0U) {
        log_msg(LOG_NOTICE,
                "event=AUDIT_TEXT version=%s job_id=%s client_ip=%s listen_port=%d "
                "label=%s endpoint=%s field=%s seq=1 total=1 raw_bytes=0 value=\"\"",
                PROGRAM_VERSION, job_id, client_ip, ch->port, ch->label,
                endpoint, field);
        return;
    }

    total = audit_text_chunk_count(data, len, AUDIT_TEXT_RAW_CHUNK);
    if (total == 0U) total = 1U;

    while (off < len) {
        size_t n = audit_text_chunk_len(data + off, len - off,
                                        AUDIT_TEXT_RAW_CHUNK);
        char escaped[1200];

        if (n == 0U) {
            /* Defensive fallback: consume one byte; audit_escape() will turn
             * an invalid non-ASCII byte into \\xNN rather than emitting it.
             */
            n = 1U;
        }
        audit_escape(data + off, n, escaped, sizeof(escaped));
        log_msg(LOG_NOTICE,
                "event=AUDIT_TEXT version=%s job_id=%s client_ip=%s listen_port=%d "
                "label=%s endpoint=%s field=%s seq=%zu total=%zu raw_bytes=%zu value=\"%s\"",
                PROGRAM_VERSION, job_id, client_ip, ch->port, ch->label,
                endpoint, field, seq, total, n, escaped);
        off += n;
        seq++;
    }
}

/* Emit one additional single-line syslog record whose message body contains
 * only the sendMessage text.  This is intentionally tied to -L because it
 * exposes message content.  It is designed for rsyslog/LogAnalyzer setups
 * where SystemEvents.Message should be directly readable without parsing the
 * structured AUDIT_TEXT record.
 *
 * Trailing CR/LF bytes (for example from "echo test | nc ...") are removed.
 * Embedded CR/LF/TAB/control bytes are normalized to a single space so the
 * mirror remains one syslog event / one database row.
 */
static void audit_log_plain_send_message(const unsigned char *data, size_t len)
{
    char *plain;
    size_t i, o = 0;
    bool last_space = false;

    if (!sensitive_audit_enabled || !data) return;

    while (len > 0U && (data[len - 1U] == '\n' || data[len - 1U] == '\r'))
        len--;
    if (len == 0U) return;

    plain = malloc(len + 1U);
    if (!plain) return;

    for (i = 0; i < len; i++) {
        unsigned char c = data[i];
        bool make_space = (c == '\r' || c == '\n' || c == '\t' ||
                           c < 0x20U || c == 0x7fU);

        if (make_space) {
            if (!last_space && o > 0U)
                plain[o++] = ' ';
            last_space = true;
            continue;
        }

        plain[o++] = (char)c;
        last_space = (c == ' ');
    }

    while (o > 0U && plain[o - 1U] == ' ')
        o--;
    plain[o] = '\0';

    if (o > 0U)
        syslog(LOG_NOTICE, "%s", plain);

    free(plain);
}

static void audit_log_binary(const char *job_id, const char *client_ip,
                             const struct channel *ch, const char *endpoint,
                             const char *field, const char *content_type,
                             const unsigned char *data, size_t len)
{
    char sha256[65] = "unavailable";
    size_t total = 0U, seq, off;
    if (!sensitive_audit_enabled || !data) return;
    (void)sha256_hex(data, len, sha256);
    if (audit_binary_content_enabled) {
        total = (len + AUDIT_BINARY_RAW_CHUNK - 1U) / AUDIT_BINARY_RAW_CHUNK;
        if (total == 0U) total = 1U;
    }
    log_msg(LOG_NOTICE,
            "event=AUDIT_BINARY_BEGIN version=%s job_id=%s client_ip=%s listen_port=%d "
            "label=%s endpoint=%s field=%s content_type=%s bytes=%zu sha256=%s chunks=%zu payload_logged=%s",
            PROGRAM_VERSION, job_id, client_ip, ch->port, ch->label, endpoint,
            field, content_type && *content_type ? content_type : "unknown",
            len, sha256, total, audit_binary_content_enabled ? "yes" : "no");
    for (seq = 1U, off = 0U; audit_binary_content_enabled && seq <= total; seq++) {
        size_t n = len > off ? len - off : 0U;
        unsigned char encoded[1025];
        int elen;
        if (n > AUDIT_BINARY_RAW_CHUNK) n = AUDIT_BINARY_RAW_CHUNK;
        elen = EVP_EncodeBlock(encoded, data + off, (int)n);
        if (elen < 0) break;
        encoded[elen] = '\0';
        log_msg(LOG_NOTICE,
                "event=AUDIT_BINARY_CHUNK version=%s job_id=%s client_ip=%s listen_port=%d "
                "label=%s endpoint=%s field=%s seq=%zu total=%zu raw_bytes=%zu data_b64=%s",
                PROGRAM_VERSION, job_id, client_ip, ch->port, ch->label,
                endpoint, field, seq, total, n, encoded);
        off += n;
    }
    log_msg(LOG_NOTICE,
            "event=AUDIT_BINARY_END version=%s job_id=%s client_ip=%s listen_port=%d "
            "label=%s endpoint=%s field=%s bytes=%zu sha256=%s chunks=%zu payload_logged=%s",
            PROGRAM_VERSION, job_id, client_ip, ch->port, ch->label,
            endpoint, field, len, sha256, total,
            audit_binary_content_enabled ? "yes" : "no");
}

static void audit_log_request(const char *job_id, const char *client_ip,
                              const struct channel *ch, const struct http_request *req)
{
    if (!sensitive_audit_enabled || !req) return;
    audit_log_credentials(job_id, client_ip, ch, req->path);
    if (strcmp(req->path, "/sendMessage") == 0) {
        bool is_form = strncasecmp(req->content_type,
                                   "application/x-www-form-urlencoded", 33) == 0;
        if (is_form) {
            char *text = form_get_value(req->body, req->content_length, "text");
            char *pm = form_get_value(req->body, req->content_length, "parse_mode");
            if (text) {
                audit_log_text(job_id, client_ip, ch, req->path, "message_text",
                               (const unsigned char *)text, strlen(text));
                audit_log_plain_send_message((const unsigned char *)text, strlen(text));
            } else
                audit_log_text(job_id, client_ip, ch, req->path, "request_body",
                               req->body, req->content_length);
            if (pm && *pm)
                audit_log_text(job_id, client_ip, ch, req->path, "parse_mode",
                               (const unsigned char *)pm, strlen(pm));
            free(text); free(pm);
        } else {
            audit_log_text(job_id, client_ip, ch, req->path, "message_text",
                           req->body, req->content_length);
            audit_log_plain_send_message(req->body, req->content_length);
            if (req->parse_mode[0])
                audit_log_text(job_id, client_ip, ch, req->path, "parse_mode",
                               (const unsigned char *)req->parse_mode,
                               strlen(req->parse_mode));
        }
    } else if (strcmp(req->path, "/sendPhoto") == 0) {
        if (req->caption[0])
            audit_log_text(job_id, client_ip, ch, req->path, "caption",
                           (const unsigned char *)req->caption, strlen(req->caption));
        if (req->parse_mode[0])
            audit_log_text(job_id, client_ip, ch, req->path, "parse_mode",
                           (const unsigned char *)req->parse_mode, strlen(req->parse_mode));
        audit_log_binary(job_id, client_ip, ch, req->path, "photo",
                         req->content_type, req->body, req->content_length);
    } else if (strcmp(req->path, "/sendDocument") == 0) {
        if (req->filename[0])
            audit_log_text(job_id, client_ip, ch, req->path, "filename",
                           (const unsigned char *)req->filename, strlen(req->filename));
        if (req->caption[0])
            audit_log_text(job_id, client_ip, ch, req->path, "caption",
                           (const unsigned char *)req->caption, strlen(req->caption));
        audit_log_binary(job_id, client_ip, ch, req->path, "document",
                         req->content_type, req->body, req->content_length);
    }
}



static const struct {
    const char *name;
    const char *needle;
} builtin_filter_defaults[] = {
    { "return-code-255", "Return code of 255 is out of bounds" },
    { "localhost-ip", "127.0.0.1" },
    { "http-root-probe", "GET / HTTP/1" },
    { "jndi-ldap", "jndi:ldap" },
    { "zero-hsgid", "hsgid=00000000-0000-0000-0000-000000000000" },
    { "jmx-invoker-probe", "GET /invoker/JMXInvokerServlet" }
};

static int parse_filter_file(const char *path,
                             struct message_filter_pattern out[MAX_FILTER_PATTERNS],
                             size_t *out_count)
{
    FILE *fp;
    char line[2048];
    size_t count = 0;
    unsigned long lineno = 0;
    struct stat st;

    if (!path || !out || !out_count) { errno = EINVAL; return -1; }
    if (lstat(path, &st) != 0) return -1;
    if (S_ISLNK(st.st_mode) || !S_ISREG(st.st_mode) ||
        (st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        errno = EPERM;
        return -1;
    }
    fp = fopen(path, "r");
    if (!fp) return -1;
    while (fgets(line, sizeof(line), fp)) {
        char *p = trim(line);
        char *sep;
        const char *name = "external";
        const char *needle;
        lineno++;
        if (*p == '\0' || *p == '#') continue;
        sep = strchr(p, '|');
        if (sep) {
            *sep = '\0';
            name = trim(p);
            needle = trim(sep + 1);
        } else {
            needle = p;
        }
        if (!*needle || !*name || strlen(name) >= FILTER_NAME_SIZE ||
            strlen(needle) >= FILTER_PATTERN_SIZE || count >= MAX_FILTER_PATTERNS) {
            fclose(fp);
            errno = EINVAL;
            fprintf(stderr, "ERROR: %s:%lu invalid filter entry\n", path, lineno);
            return -1;
        }
        snprintf(out[count].name, sizeof(out[count].name), "%s", name);
        snprintf(out[count].needle, sizeof(out[count].needle), "%s", needle);
        count++;
    }
    fclose(fp);
    *out_count = count;
    return 0;
}

static void install_builtin_filters(void)
{
    size_t i;
    pthread_rwlock_wrlock(&filter_lock);
    active_filter_count = 0;
    for (i = 0; i < sizeof(builtin_filter_defaults) / sizeof(builtin_filter_defaults[0]); i++) {
        snprintf(active_filters[i].name, sizeof(active_filters[i].name), "%s",
                 builtin_filter_defaults[i].name);
        snprintf(active_filters[i].needle, sizeof(active_filters[i].needle), "%s",
                 builtin_filter_defaults[i].needle);
        active_filter_count++;
    }
    pthread_rwlock_unlock(&filter_lock);
}

static int reload_filter_file(bool initial)
{
    struct message_filter_pattern tmp[MAX_FILTER_PATTERNS];
    size_t count = 0;
    if (parse_filter_file(filter_file, tmp, &count) != 0) {
        if (initial && errno == ENOENT) {
            install_builtin_filters();
            return 1;
        }
        return -1;
    }
    pthread_rwlock_wrlock(&filter_lock);
    memcpy(active_filters, tmp, count * sizeof(tmp[0]));
    active_filter_count = count;
    pthread_rwlock_unlock(&filter_lock);
    return 0;
}

static bool buffer_contains_literal(const unsigned char *data, size_t len,
                                    const char *needle)
{
    size_t nlen, i;

    if (!data || !needle) return false;
    nlen = strlen(needle);
    if (nlen == 0U || nlen > len) return false;

    for (i = 0U; i <= len - nlen; i++) {
        if (memcmp(data + i, needle, nlen) == 0)
            return true;
    }
    return false;
}

static bool message_is_blank(const unsigned char *data, size_t len)
{
    size_t i;

    if (!data || len == 0U) return true;
    for (i = 0U; i < len; i++) {
        unsigned char c = data[i];
        if (!(c == ' ' || c == '\t' || c == '\r' || c == '\n' ||
              c == '\f' || c == '\v'))
            return false;
    }
    return true;
}

static bool message_text_filter_match(const unsigned char *data, size_t len,
                                      const char **reason,
                                      const char **matched_pattern)
{
    size_t i;
    static _Thread_local char tls_reason[FILTER_NAME_SIZE];
    static _Thread_local char tls_pattern[FILTER_PATTERN_SIZE];

    if (reason) *reason = NULL;
    if (matched_pattern) *matched_pattern = NULL;

    if (message_is_blank(data, len)) {
        if (reason) *reason = "blank-message";
        if (matched_pattern) *matched_pattern = "<blank>";
        return true;
    }

    pthread_rwlock_rdlock(&filter_lock);
    for (i = 0U; i < active_filter_count; i++) {
        if (buffer_contains_literal(data, len, active_filters[i].needle)) {
            snprintf(tls_reason, sizeof(tls_reason), "%s", active_filters[i].name);
            snprintf(tls_pattern, sizeof(tls_pattern), "%s", active_filters[i].needle);
            pthread_rwlock_unlock(&filter_lock);
            if (reason) *reason = tls_reason;
            if (matched_pattern) *matched_pattern = tls_pattern;
            return true;
        }
    }
    pthread_rwlock_unlock(&filter_lock);
    return false;
}

static bool send_message_request_filter_match(const struct http_request *req,
                                              const char **reason,
                                              const char **matched_pattern)
{
    bool is_form;

    if (!req || strcmp(req->path, "/sendMessage") != 0)
        return false;

    is_form = strncasecmp(req->content_type,
                          "application/x-www-form-urlencoded", 33) == 0;
    if (is_form) {
        char *text = form_get_value(req->body, req->content_length, "text");
        bool matched;
        if (!text) return false; /* validation reports missing text separately */
        matched = message_text_filter_match((const unsigned char *)text,
                                            strlen(text), reason,
                                            matched_pattern);
        free(text);
        return matched;
    }

    return message_text_filter_match(req->body, req->content_length,
                                     reason, matched_pattern);
}

static void log_message_filter_drop(const struct ingest_ctx *ctx,
                                    const struct http_request *req,
                                    const char *source,
                                    const char *reason,
                                    const char *pattern)
{
    char escaped_pattern[512];

    if (!ctx || !req) return;
    audit_escape((const unsigned char *)(pattern ? pattern : ""),
                 strlen(pattern ? pattern : ""),
                 escaped_pattern, sizeof(escaped_pattern));
    metric_record(METRIC_FILTERED);
    log_msg(LOG_NOTICE,
            "event=MESSAGE_FILTER_DROP version=%s client_ip=%s client_port=%u "
            "listen_port=%d label=%s endpoint=/sendMessage source=%s bytes=%zu "
            "reason=%s pattern=\"%s\"",
            PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port,
            ctx->ch->label, source ? source : "unknown", req->content_length,
            reason ? reason : "matched", escaped_pattern);
}

static void send_filtered_response(int fd, const char *reason,
                                   const char *pattern)
{
    char body[1024];
    char reason_json[256], pattern_json[512];
    int n;

    json_escape(reason ? reason : "matched", reason_json, sizeof(reason_json));
    json_escape(pattern ? pattern : "", pattern_json, sizeof(pattern_json));
    n = snprintf(body, sizeof(body),
                 "{\"ok\":true,\"filtered\":true,\"dropped\":true,"
                 "\"reason\":\"%s\",\"pattern\":\"%s\"}\n",
                 reason_json, pattern_json);
    if (n < 0) n = 0;
    if ((size_t)n >= sizeof(body)) n = (int)sizeof(body) - 1;
    (void)send_http_response(fd, 200, "application/json; charset=utf-8",
                             body, (size_t)n);
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s [-b bind_address] [-c config] [-f filters] [-s spool_dir] [-w workers] [-p port ...] [-a client_ip_or_cidr ...] [-L]\n"
        "  %s -t [-c config] [-f filters] [-p port ...]\n"
        "  %s -s spool_dir --queue-status\n"
        "  %s -s spool_dir --failed-list\n"
        "  %s -s spool_dir --failed-show JOB_ID\n"
        "  %s -s spool_dir --failed-retry JOB_ID\n"
        "  %s -s spool_dir --failed-retry-all\n"
        "  %s -s spool_dir --failed-delete JOB_ID\n"
        "  %s --validate-tokens [-c config]\n\n"
        "Options:\n"
        "  -b address   Bind address. Default: %s\n"
        "  -c file      Port/token/chat config. Default: %s\n"
        "  -f file      sendMessage filter file. Default: %s; missing file uses built-in defaults.\n"
        "  -s dir       Persistent spool root. Default: %s\n"
        "  -w number    Sender worker threads. Default: %d, max: %d\n"
        "  -p port      Listen only on this configured port; may repeat. If omitted, all configured ports are enabled.\n"
        "  -a IP/CIDR   Allowed source IP or CIDR; may repeat. IPv4 shorthand CIDR is supported,\n"
        "               e.g. 192.168.167/24. If omitted, all source IPs are allowed.\n"
        "  -L           Enable sensitive audit logging and plain sendMessage mirror rows.\n"
        "               Bot Token is redacted/fingerprinted by default.\n"
        "  --audit-full-token      With -L, log the full Bot Token (NOT recommended for production).\n"
        "  --audit-binary-content  With -L, Base64-log complete photo/document payloads.\n"
        "                          Default: metadata + SHA-256 only (recommended).\n"
        "  -t           Validate config/filter syntax and exit without opening listeners.\n"
        "  --queue-status          Show persistent queue/spool status and exit.\n"
        "  --failed-list           List jobs in failed/ and exit.\n"
        "  --failed-show JOB_ID    Show failed-job metadata (Bot Token is redacted).\n"
        "  --failed-retry JOB_ID   Move one failed job back to pending, attempts reset.\n"
        "  --failed-retry-all      Retry all parseable failed jobs.\n"
        "  --failed-delete JOB_ID  Permanently delete one failed job.\n"
        "  --validate-tokens       Call Telegram getMe once per unique Bot Token and exit.\n"
        "  -h           Show help.\n\n",
        prog, prog, prog, prog, prog, prog, prog, prog, prog,
        DEFAULT_BIND_ADDR, DEFAULT_CONFIG_FILE, DEFAULT_FILTER_FILE,
        DEFAULT_SPOOL_DIR, DEFAULT_WORKERS, MAX_WORKERS);

    fprintf(stderr,
        "Config format:\n"
        "  http_compat_text_query=yes      # or no\n"
        "  http_compat_auto_urlencode=yes  # or no\n"
        "  proxy_protocol_v1=yes            # optional PROXY v1 from tcp_failover_proxy; default no\n"
        "  maintenance_control_allow=IP/CIDR # may repeat; if omitted, magic-command control is allow-all\n"
        "  port|BOT_TOKEN|CHAT_ID|label\n"
        "  Maintenance/test magic commands are sendMessage text on the target port:\n"
        "    " MAINTENANCE_MAGIC_STATUS " -> report ON/OFF, age, TTL, reason and suppressed count\n"
        "    " MAINTENANCE_MAGIC_ON " -> suppress indefinitely; audit/log only; publish+pin ENABLED notice\n"
        "    " MAINTENANCE_MAGIC_ON_30M " -> suppress for 30 minutes, publish+pin ENABLED, then auto-publish DISABLED\n"
        "    " MAINTENANCE_MAGIC_ON_PREFIX "3600[:REASON] -> suppress for TTL seconds\n"
        "    " MAINTENANCE_MAGIC_EXTEND_PREFIX "1800 -> extend an existing finite maintenance window\n"
        "    " MAINTENANCE_MAGIC_OFF " -> resume delivery; publish+pin DISABLED notice\n"
        "    " MAINTENANCE_MAGIC_MARK_PREFIX "TEXT -> write an audit marker only; state unchanged\n"
        "    " TEST_LOG_ONLY_PREFIX "TEXT -> log/audit test text only; never queue/send Telegram\n"
        "  TTL range: 1..604800 seconds (7 days). Maintenance state/TTL is persistent per listen port.\n"
        "  ON/OFF status notices use the mapped CHAT_ID and are managed as one bot-owned maintenance pin.\n"
        "  Bot must have Telegram permission to pin/unpin messages; notice failure never rolls back maintenance state.\n"
        "  http_compat_auto_urlencode=yes requires http_compat_text_query=yes.\n"
        "  maintenance_control_allow affects only reserved __TG_* control commands, not normal alert delivery.\n"
        "  With proxy_protocol_v1=yes, restrict direct TCP peers with -a to trusted Host B proxy addresses in production.\n\n"
        "Filter format:\n"
        "  name|case-sensitive-substring\n"
        "  Blank/whitespace-only sendMessage text is always dropped.\n"
        "  SIGHUP reloads token/chat/label values, HTTP compatibility flags and filter rules; listener ports must not change.\n\n"
        "Relay endpoints:\n"
        "  POST /sendMessage   Queue UTF-8 text/form data. Optional X-Idempotency-Key.\n"
        "  ANY-METHOD /sendMessage Compatibility method normalization to POST when http_compat_text_query=yes.\n"
        "  ANY-METHOD /?text=... Compatibility sendMessage when http_compat_text_query=yes; raw unsafe query bytes can be encoded automatically.\n"
        "  POST /sendPhoto     Queue raw PNG/JPEG. Optional X-Idempotency-Key.\n"
        "  POST /sendDocument  Queue any file; use X-Filename. Optional X-Idempotency-Key.\n"
        "  GET  /health        Detailed JSON health.\n"
        "  GET  /live          Process liveness JSON.\n"
        "  GET  /ready         Readiness JSON; HTTP 503 when queue/spool is critical.\n"
        "  GET  /metrics       Prometheus text-format metrics.\n"
        "  Maintenance suppress and managed-pin state are persistent per listen port under spool/maintenance.\n\n"
        "Hardening:\n"
        "  HTTP headers deadline: %lld ms; total request deadline: %lld ms.\n"
        "  X-Idempotency-Key retention: %lld seconds; conflicting reuse returns HTTP 409.\n"
        "  Spool v%d stores SHA-256 and verifies payload integrity.\n"
        "  Startup removes stale tmp files older than %lld seconds.\n"
        "  Retry backoff includes +/- %ld%% jitter for transport/5xx failures.\n"
        "  Circuit breaker opens after %u availability failures for %lld ms.\n"
        "  Telegram 429 is durable flow-control: no delivery-attempt increment.\n"
        "  429 Retry-After uses max(header, JSON) + %ld ms safety margin.\n"
        "  Repeated 429 uses BOT-wide adaptive floors: 9/18/36/60/120 seconds.\n"
        "  Cooldown recovery permits one in-flight BOT_TOKEN probe; 2xx clears the streak.\n"
        "  429-deferred jobs older than %lld seconds expire to failed/.\n\n",
        (long long)HTTP_HEADER_DEADLINE_MS, (long long)REQUEST_TOTAL_DEADLINE_MS,
        (long long)IDEMPOTENCY_RETENTION_SEC, SPOOL_FORMAT_VERSION,
        (long long)STALE_TMP_AGE_SEC, RETRY_JITTER_PERCENT,
        CIRCUIT_FAILURE_THRESHOLD, (long long)CIRCUIT_OPEN_MS,
        RATE_LIMIT_SAFETY_MARGIN_MS, (long long)MAX_JOB_AGE_SEC);

    fprintf(stderr,
        "Queue policy:\n"
        "  max pending+working jobs: %u\n"
        "  max failed jobs:          %u\n"
        "  max spool bytes:          %llu\n"
        "  minimum filesystem free:  %llu\n\n"
        "RAW TCP classification:\n"
        "  PNG/JPEG -> sendPhoto; DOC/DOCX/XLS/XLSX/PPT/PPTX/PDF/HTML/CSV/LOG -> sendDocument.\n"
        "  gzip/tar/7z/RAR/JSON/shell/BOM/long text -> sendDocument; other valid UTF-8 plain text <=4096 chars -> sendMessage.\n\n"
        "Delivery model:\n"
        "  Persistent at-least-once queue; restart recovers working jobs.\n"
        "  Each CHAT_ID is paced to %ld attempts/minute (%ld ms spacing).\n"
        "  429 is deferred without consuming delivery attempts; BOT_TOKEN cooldown/streak is persistent.\n"
        "  After a BOT cooldown, only one recovery probe may be in-flight until success/next failure.\n"
        "  500/502/503/504 and pre-request DNS/connect/TLS failures use bounded retries.\n"
        "  Ambiguous timeout/send/receive failures move to failed/ to reduce duplicates.\n",
        MAX_PENDING_JOBS, MAX_FAILED_JOBS,
        (unsigned long long)MAX_SPOOL_BYTES,
        (unsigned long long)SPOOL_MIN_FREE_BYTES,
        CHANNEL_MAX_PER_MINUTE, CHANNEL_SPACING_MS);
}

static char *trim(char *s)
{
    char *end;
    while (*s && isspace((unsigned char)*s)) s++;
    if (*s == '\0') return s;
    end = s + strlen(s) - 1;
    while (end > s && isspace((unsigned char)*end)) *end-- = '\0';
    return s;
}

static int parse_bool_value(const char *value, bool *out)
{
    if (!value || !out) return -1;
    if (strcasecmp(value, "yes") == 0 || strcasecmp(value, "true") == 0 ||
        strcasecmp(value, "on") == 0 || strcmp(value, "1") == 0) {
        *out = true;
        return 0;
    }
    if (strcasecmp(value, "no") == 0 || strcasecmp(value, "false") == 0 ||
        strcasecmp(value, "off") == 0 || strcmp(value, "0") == 0) {
        *out = false;
        return 0;
    }
    return -1;
}

static int parse_runtime_directive(char *line, bool *text_query,
                                   bool *auto_urlencode,
                                   bool *proxy_v1,
                                   struct allowed_client_rule control_rules[MAX_ALLOWED_CLIENTS],
                                   size_t *control_rule_count)
{
    char *eq, *key, *value;
    bool v;

    if (!line || !text_query || !auto_urlencode || !proxy_v1 ||
        !control_rules || !control_rule_count || strchr(line, '|')) return 0;
    eq = strchr(line, '=');
    if (!eq) return 0;
    *eq = '\0';
    key = trim(line);
    value = trim(eq + 1);

    if (strcmp(key, "http_compat_text_query") == 0) {
        if (parse_bool_value(value, &v) != 0) return -1;
        *text_query = v;
        return 1;
    }
    if (strcmp(key, "http_compat_auto_urlencode") == 0) {
        if (parse_bool_value(value, &v) != 0) return -1;
        *auto_urlencode = v;
        return 1;
    }
    if (strcmp(key, "proxy_protocol_v1") == 0) {
        if (parse_bool_value(value, &v) != 0) return -1;
        *proxy_v1 = v;
        return 1;
    }
    if (strcmp(key, "maintenance_control_allow") == 0) {
        if (!*value || *control_rule_count >= MAX_ALLOWED_CLIENTS) return -1;
        if (parse_allowed_client_rule(value, &control_rules[*control_rule_count]) != 0)
            return -1;
        (*control_rule_count)++;
        return 1;
    }
    return 0;
}

static int parse_port(const char *s, int *out)
{
    char *end = NULL;
    long v;
    errno = 0;
    v = strtol(s, &end, 10);
    if (errno || end == s || *end != '\0' || v < 1 || v > 65535) return -1;
    *out = (int)v;
    return 0;
}

static int parse_workers(const char *s, int *out)
{
    char *end = NULL;
    long v;
    errno = 0;
    v = strtol(s, &end, 10);
    if (errno || end == s || *end != '\0' || v < 1 || v > MAX_WORKERS) return -1;
    *out = (int)v;
    return 0;
}

static bool selected_port_requested(int port)
{
    size_t i;
    if (selected_port_count == 0) return true;
    for (i = 0; i < selected_port_count; i++) if (selected_ports[i] == port) return true;
    return false;
}

static struct channel *find_channel_by_port(int port)
{
    size_t i;
    for (i = 0; i < channel_count; i++) if (channels[i].port == port) return &channels[i];
    return NULL;
}

static int load_config(const char *path)
{
    FILE *fp;
    char line[2048];
    unsigned long lineno = 0;
    struct stat st;
    bool cfg_text_query = false;
    bool cfg_auto_urlencode = false;
    bool cfg_proxy_v1 = false;
    struct allowed_client_rule cfg_control_rules[MAX_ALLOWED_CLIENTS];
    size_t cfg_control_rule_count = 0;

    if (stat(path, &st) != 0) {
        fprintf(stderr, "ERROR: cannot stat config %s: %s\n", path, strerror(errno));
        return -1;
    }
    if ((st.st_mode & (S_IWGRP | S_IRWXO)) != 0) {
        fprintf(stderr, "ERROR: insecure config permissions on %s; use 0640 or stricter\n", path);
        return -1;
    }
    fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "ERROR: cannot open config %s: %s\n", path, strerror(errno));
        return -1;
    }
    while (fgets(line, sizeof(line), fp)) {
        char *p, *save = NULL, *f_port, *f_token, *f_chat, *f_label;
        int port, drc;
        struct channel *ch;
        lineno++;
        p = trim(line);
        if (*p == '\0' || *p == '#') continue;

        drc = parse_runtime_directive(p, &cfg_text_query, &cfg_auto_urlencode,
                                      &cfg_proxy_v1, cfg_control_rules,
                                      &cfg_control_rule_count);
        if (drc < 0) {
            fprintf(stderr, "ERROR: %s:%lu invalid runtime directive/value\n", path, lineno);
            fclose(fp); return -1;
        }
        if (drc > 0) continue;

        f_port = strtok_r(p, "|", &save);
        f_token = strtok_r(NULL, "|", &save);
        f_chat = strtok_r(NULL, "|", &save);
        f_label = strtok_r(NULL, "\r\n", &save);
        if (!f_port || !f_token || !f_chat) {
            fprintf(stderr, "ERROR: %s:%lu invalid mapping or unknown directive\n", path, lineno);
            fclose(fp); return -1;
        }
        f_port = trim(f_port); f_token = trim(f_token); f_chat = trim(f_chat);
        f_label = f_label ? trim(f_label) : (char *)"unnamed";
        if (parse_port(f_port, &port) != 0 || find_channel_by_port(port)) {
            fprintf(stderr, "ERROR: %s:%lu invalid/duplicate port '%s'\n", path, lineno, f_port);
            fclose(fp); return -1;
        }
        if (!*f_token || strlen(f_token) >= TOKEN_SIZE || !*f_chat || strlen(f_chat) >= CHAT_ID_SIZE ||
            strlen(f_label) >= LABEL_SIZE || channel_count >= MAX_CHANNELS) {
            fprintf(stderr, "ERROR: %s:%lu invalid/too-long field\n", path, lineno);
            fclose(fp); return -1;
        }
        ch = &channels[channel_count++];
        memset(ch, 0, sizeof(*ch));
        ch->port = port;
        snprintf(ch->token, sizeof(ch->token), "%s", f_token);
        snprintf(ch->chat_id, sizeof(ch->chat_id), "%s", f_chat);
        snprintf(ch->label, sizeof(ch->label), "%s", f_label);
        ch->listen_fd = -1;
        ch->selected = selected_port_requested(port);
    }
    fclose(fp);

    if (cfg_auto_urlencode && !cfg_text_query) {
        fprintf(stderr, "ERROR: %s http_compat_auto_urlencode=yes requires http_compat_text_query=yes\n", path);
        return -1;
    }
    http_compat_text_query = cfg_text_query;
    http_compat_auto_urlencode = cfg_auto_urlencode;
    proxy_protocol_v1_enabled = cfg_proxy_v1;
    memcpy(maintenance_control_rules, cfg_control_rules,
           cfg_control_rule_count * sizeof(cfg_control_rules[0]));
    maintenance_control_rule_count = cfg_control_rule_count;
    return 0;
}

static int parse_config_snapshot(const char *path,
                                 struct channel out[MAX_CHANNELS],
                                 size_t *out_count,
                                 bool *out_text_query,
                                 bool *out_auto_urlencode,
                                 bool *out_proxy_v1,
                                 struct allowed_client_rule out_control_rules[MAX_ALLOWED_CLIENTS],
                                 size_t *out_control_rule_count)
{
    FILE *fp;
    char line[2048];
    unsigned long lineno = 0;
    size_t count = 0, i;
    struct stat st;
    bool cfg_text_query = false;
    bool cfg_auto_urlencode = false;
    bool cfg_proxy_v1 = false;
    struct allowed_client_rule cfg_control_rules[MAX_ALLOWED_CLIENTS];
    size_t cfg_control_rule_count = 0;

    if (stat(path, &st) != 0) return -1;
    if ((st.st_mode & (S_IWGRP | S_IRWXO)) != 0) { errno = EPERM; return -1; }
    fp = fopen(path, "r");
    if (!fp) return -1;
    while (fgets(line, sizeof(line), fp)) {
        char *p, *save = NULL, *f_port, *f_token, *f_chat, *f_label;
        int port, drc;
        lineno++;
        p = trim(line);
        if (*p == '\0' || *p == '#') continue;

        drc = parse_runtime_directive(p, &cfg_text_query, &cfg_auto_urlencode,
                                      &cfg_proxy_v1, cfg_control_rules,
                                      &cfg_control_rule_count);
        if (drc < 0) goto invalid;
        if (drc > 0) continue;

        f_port = strtok_r(p, "|", &save);
        f_token = strtok_r(NULL, "|", &save);
        f_chat = strtok_r(NULL, "|", &save);
        f_label = strtok_r(NULL, "\r\n", &save);
        if (!f_port || !f_token || !f_chat || count >= MAX_CHANNELS) goto invalid;
        f_port = trim(f_port); f_token = trim(f_token); f_chat = trim(f_chat);
        f_label = f_label ? trim(f_label) : (char *)"unnamed";
        if (parse_port(f_port, &port) != 0 || !*f_token || !*f_chat ||
            strlen(f_token) >= TOKEN_SIZE || strlen(f_chat) >= CHAT_ID_SIZE ||
            strlen(f_label) >= LABEL_SIZE) goto invalid;
        for (i = 0; i < count; i++) if (out[i].port == port) goto invalid;
        memset(&out[count], 0, sizeof(out[count]));
        out[count].port = port;
        snprintf(out[count].token, sizeof(out[count].token), "%s", f_token);
        snprintf(out[count].chat_id, sizeof(out[count].chat_id), "%s", f_chat);
        snprintf(out[count].label, sizeof(out[count].label), "%s", f_label);
        count++;
    }
    fclose(fp);
    if (cfg_auto_urlencode && !cfg_text_query) { errno = EINVAL; return -1; }
    *out_count = count;
    if (out_text_query) *out_text_query = cfg_text_query;
    if (out_auto_urlencode) *out_auto_urlencode = cfg_auto_urlencode;
    if (out_proxy_v1) *out_proxy_v1 = cfg_proxy_v1;
    if (out_control_rules && cfg_control_rule_count > 0)
        memcpy(out_control_rules, cfg_control_rules,
               cfg_control_rule_count * sizeof(cfg_control_rules[0]));
    if (out_control_rule_count) *out_control_rule_count = cfg_control_rule_count;
    return 0;
invalid:
    fclose(fp);
    errno = EINVAL;
    fprintf(stderr, "ERROR: %s:%lu invalid mapping/directive during reload\n", path, lineno);
    return -1;
}

static int reload_runtime_config(const char *path)
{
    struct channel tmp[MAX_CHANNELS];
    size_t count = 0, i, j;
    bool new_text_query = false, new_auto_urlencode = false, new_proxy_v1 = false;
    struct allowed_client_rule new_control_rules[MAX_ALLOWED_CLIENTS];
    size_t new_control_rule_count = 0;
    if (parse_config_snapshot(path, tmp, &count,
                              &new_text_query, &new_auto_urlencode,
                              &new_proxy_v1, new_control_rules,
                              &new_control_rule_count) != 0) return -1;
    if (count != channel_count) { errno = EINVAL; return -1; }
    for (i = 0; i < channel_count; i++) {
        struct channel *match = NULL;
        for (j = 0; j < count; j++) if (tmp[j].port == channels[i].port) { match = &tmp[j]; break; }
        if (!match) { errno = EINVAL; return -1; }
    }
    /* main() only calls this when ingest_threads == 0. Listener fds and
     * selected flags remain unchanged; credentials/labels and compatibility
     * flags are refreshed atomically from the validated snapshot. */
    for (i = 0; i < channel_count; i++) {
        for (j = 0; j < count; j++) {
            if (tmp[j].port != channels[i].port) continue;
            snprintf(channels[i].token, sizeof(channels[i].token), "%s", tmp[j].token);
            snprintf(channels[i].chat_id, sizeof(channels[i].chat_id), "%s", tmp[j].chat_id);
            snprintf(channels[i].label, sizeof(channels[i].label), "%s", tmp[j].label);
            break;
        }
    }
    http_compat_text_query = new_text_query;
    http_compat_auto_urlencode = new_auto_urlencode;
    proxy_protocol_v1_enabled = new_proxy_v1;
    memcpy(maintenance_control_rules, new_control_rules,
           new_control_rule_count * sizeof(new_control_rules[0]));
    maintenance_control_rule_count = new_control_rule_count;
    return 0;
}

static int parse_decimal_octet(const char *s, size_t len, unsigned char *out)
{
    unsigned value = 0;
    size_t i;
    if (!s || !out || len == 0 || len > 3) return -1;
    for (i = 0; i < len; i++) {
        if (!isdigit((unsigned char)s[i])) return -1;
        value = value * 10U + (unsigned)(s[i] - '0');
        if (value > 255U) return -1;
    }
    *out = (unsigned char)value;
    return 0;
}

/* Parse dotted IPv4. When allow_abbrev is true, missing trailing octets are
 * filled with zero so forms such as 192.168.167/24 are accepted. */
static int parse_ipv4_text(const char *text, bool allow_abbrev,
                           unsigned char out[4], unsigned *octets_supplied)
{
    const char *p, *seg;
    unsigned count = 0;
    if (!text || !*text || !out) return -1;
    memset(out, 0, 4);
    p = seg = text;
    for (;;) {
        if (*p == '.' || *p == '\0') {
            if (count >= 4U || parse_decimal_octet(seg, (size_t)(p - seg), &out[count]) != 0)
                return -1;
            count++;
            if (*p == '\0') break;
            seg = p + 1;
        }
        p++;
    }
    if ((!allow_abbrev && count != 4U) || count == 0U) return -1;
    if (octets_supplied) *octets_supplied = count;
    return 0;
}

static void mask_network_bytes(unsigned char *addr, size_t len, unsigned prefix_len)
{
    size_t i;
    unsigned bits_left = prefix_len;
    for (i = 0; i < len; i++) {
        if (bits_left >= 8U) {
            bits_left -= 8U;
            continue;
        }
        if (bits_left == 0U) {
            addr[i] = 0;
        } else {
            addr[i] &= (unsigned char)(0xffU << (8U - bits_left));
            bits_left = 0U;
        }
    }
}

static bool prefix_bytes_match(const unsigned char *addr, const unsigned char *network,
                               size_t len, unsigned prefix_len)
{
    size_t whole = prefix_len / 8U;
    unsigned rem = prefix_len % 8U;
    unsigned char mask;
    if (whole > len) return false;
    if (whole && memcmp(addr, network, whole) != 0) return false;
    if (rem == 0U) return true;
    if (whole >= len) return false;
    mask = (unsigned char)(0xffU << (8U - rem));
    return (addr[whole] & mask) == (network[whole] & mask);
}

static int parse_allowed_client_rule(const char *input, struct allowed_client_rule *rule)
{
    char buf[128], *slash, *addr_text, *end = NULL;
    char canon[INET6_ADDRSTRLEN];
    long prefix;
    unsigned max_prefix, octets = 0;
    size_t addr_len;
    bool has_slash;

    if (!input || !*input || !rule || strlen(input) >= sizeof(buf)) return -1;
    snprintf(buf, sizeof(buf), "%s", input);
    addr_text = buf;
    slash = strchr(buf, '/');
    has_slash = slash != NULL;
    if (slash) {
        if (strchr(slash + 1, '/')) return -1;
        *slash++ = '\0';
        if (!*addr_text || !*slash) return -1;
    }

    memset(rule, 0, sizeof(*rule));
    if (strchr(addr_text, ':')) {
        struct in6_addr a6;
        rule->family = AF_INET6;
        max_prefix = 128U;
        addr_len = 16U;
        if (inet_pton(AF_INET6, addr_text, &a6) != 1) return -1;
        memcpy(rule->network, &a6, 16);
    } else {
        unsigned char a4[4];
        rule->family = AF_INET;
        max_prefix = 32U;
        addr_len = 4U;
        if (parse_ipv4_text(addr_text, has_slash, a4, &octets) != 0) return -1;
        memcpy(rule->network, a4, 4);
    }

    if (has_slash) {
        errno = 0;
        prefix = strtol(slash, &end, 10);
        if (errno || !end || *end != '\0' || prefix < 0 || prefix > (long)max_prefix) return -1;
        /* Abbreviated IPv4 must supply enough octets for all significant bits.
         * 192.168.167/24 is valid; 192.168.167/27 requires the fourth octet. */
        if (rule->family == AF_INET && octets < 4U && (unsigned)prefix > octets * 8U) return -1;
        rule->prefix_len = (unsigned)prefix;
    } else {
        rule->prefix_len = max_prefix;
    }

    mask_network_bytes(rule->network, addr_len, rule->prefix_len);
    if (rule->family == AF_INET) {
        struct in_addr a4;
        memcpy(&a4, rule->network, 4);
        if (!inet_ntop(AF_INET, &a4, canon, sizeof(canon))) return -1;
    } else {
        struct in6_addr a6;
        memcpy(&a6, rule->network, 16);
        if (!inet_ntop(AF_INET6, &a6, canon, sizeof(canon))) return -1;
    }
    if (has_slash || rule->prefix_len != max_prefix)
        snprintf(rule->text, sizeof(rule->text), "%s/%u", canon, rule->prefix_len);
    else
        snprintf(rule->text, sizeof(rule->text), "%s", canon);
    return 0;
}

static bool client_is_allowed(const char *client_ip)
{
    size_t i;
    struct in_addr a4;
    struct in6_addr a6;

    /* No -a options means allow every source address. */
    if (allowed_client_count == 0) return true;
    if (!client_ip || !*client_ip) return false;

    if (inet_pton(AF_INET, client_ip, &a4) == 1) {
        const unsigned char *addr = (const unsigned char *)&a4;
        for (i = 0; i < allowed_client_count; i++) {
            if (allowed_clients[i].family != AF_INET) continue;
            if (prefix_bytes_match(addr, allowed_clients[i].network, 4, allowed_clients[i].prefix_len))
                return true;
        }
        return false;
    }

    if (inet_pton(AF_INET6, client_ip, &a6) == 1) {
        const unsigned char *addr = (const unsigned char *)&a6;
        /* IPv4-mapped IPv6 peers also match IPv4 allow rules. */
        if (IN6_IS_ADDR_V4MAPPED(&a6)) {
            const unsigned char *mapped4 = addr + 12;
            for (i = 0; i < allowed_client_count; i++) {
                if (allowed_clients[i].family != AF_INET) continue;
                if (prefix_bytes_match(mapped4, allowed_clients[i].network, 4, allowed_clients[i].prefix_len))
                    return true;
            }
        }
        for (i = 0; i < allowed_client_count; i++) {
            if (allowed_clients[i].family != AF_INET6) continue;
            if (prefix_bytes_match(addr, allowed_clients[i].network, 16, allowed_clients[i].prefix_len))
                return true;
        }
    }
    return false;
}

static bool ip_matches_rule_list(const char *client_ip,
                                 const struct allowed_client_rule *rules,
                                 size_t rule_count)
{
    size_t i;
    struct in_addr a4;
    struct in6_addr a6;

    if (rule_count == 0U) return true;
    if (!client_ip || !*client_ip) return false;

    if (inet_pton(AF_INET, client_ip, &a4) == 1) {
        const unsigned char *addr = (const unsigned char *)&a4;
        for (i = 0U; i < rule_count; i++) {
            if (rules[i].family != AF_INET) continue;
            if (prefix_bytes_match(addr, rules[i].network, 4U, rules[i].prefix_len))
                return true;
        }
        return false;
    }
    if (inet_pton(AF_INET6, client_ip, &a6) == 1) {
        const unsigned char *addr = (const unsigned char *)&a6;
        if (IN6_IS_ADDR_V4MAPPED(&a6)) {
            const unsigned char *mapped4 = addr + 12;
            for (i = 0U; i < rule_count; i++) {
                if (rules[i].family != AF_INET) continue;
                if (prefix_bytes_match(mapped4, rules[i].network, 4U, rules[i].prefix_len))
                    return true;
            }
        }
        for (i = 0U; i < rule_count; i++) {
            if (rules[i].family != AF_INET6) continue;
            if (prefix_bytes_match(addr, rules[i].network, 16U, rules[i].prefix_len))
                return true;
        }
    }
    return false;
}

static bool maintenance_control_is_allowed(const char *client_ip)
{
    /* Explicit user requirement: no maintenance_control_allow directives
     * means backward-compatible allow-all for reserved __TG_* commands. */
    return ip_matches_rule_list(client_ip, maintenance_control_rules,
                                maintenance_control_rule_count);
}

static void stop_handler(int signo)
{
    (void)signo;
    stop_flag = 1;
}

static void hup_handler(int signo)
{
    (void)signo;
    reload_flag = 1;
}

static int set_socket_timeouts(int fd, int sec)
{
    struct timeval tv;
    tv.tv_sec = sec; tv.tv_usec = 0;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) return -1;
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) != 0) return -1;
    return 0;
}

static int send_all(int fd, const void *buf, size_t len)
{
    const unsigned char *p = buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n > 0) { p += (size_t)n; len -= (size_t)n; }
        else if (n < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}

static const char *reason_phrase(long code)
{
    switch (code) {
        case 200: return "OK";
        case 202: return "Accepted";
        case 400: return "Bad Request";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 408: return "Request Timeout";
        case 409: return "Conflict";
        case 411: return "Length Required";
        case 413: return "Payload Too Large";
        case 415: return "Unsupported Media Type";
        case 417: return "Expectation Failed";
        case 429: return "Too Many Requests";
        case 500: return "Internal Server Error";
        case 503: return "Service Unavailable";
        case 507: return "Insufficient Storage";
        default: return "Response";
    }
}

static int send_http_response(int fd, long status, const char *content_type, const void *body, size_t body_len)
{
    char hdr[1024];
    int n;
    if (!content_type) content_type = "application/json; charset=utf-8";
    n = snprintf(hdr, sizeof(hdr),
                 "HTTP/1.1 %ld %s\r\nConnection: close\r\nCache-Control: no-store\r\n"
                 "Content-Type: %s\r\nContent-Length: %zu\r\n\r\n",
                 status, reason_phrase(status), content_type, body_len);
    if (n < 0 || (size_t)n >= sizeof(hdr)) return -1;
    if (send_all(fd, hdr, (size_t)n) != 0) return -1;
    if (body_len && send_all(fd, body, body_len) != 0) return -1;
    return 0;
}

static void send_json_error(int fd, long status, const char *msg)
{
    char escaped[1024];
    char body[1280];
    int n;

    json_escape(msg ? msg : "error", escaped, sizeof(escaped));
    n = snprintf(body, sizeof(body), "{\"ok\":false,\"error\":\"%s\"}\n", escaped);
    if (n < 0) return;
    if ((size_t)n >= sizeof(body)) n = (int)sizeof(body) - 1;
    (void)send_http_response(fd, status, "application/json; charset=utf-8", body, (size_t)n);
}

static int parse_content_length(const char *v, size_t *out)
{
    char *end = NULL;
    unsigned long long x;
    errno = 0;
    x = strtoull(v, &end, 10);
    if (errno || end == v) return -1;
    while (*end && isspace((unsigned char)*end)) end++;
    if (*end || x > MAX_REQUEST_BODY) return -1;
    *out = (size_t)x;
    return 0;
}

/* Parse an HTTP/1.x request line while optionally tolerating raw spaces
 * inside the request-target. This is used only when the explicit
 * http_compat_text_query compatibility mode is enabled. */
static int parse_request_line_compat_tg(const char *line,
                                        char *method, size_t method_cap,
                                        char *target, size_t target_cap,
                                        char *version, size_t version_cap,
                                        bool *had_raw_space)
{
    const char *first_sp, *last_sp, *target_start, *target_end, *p;
    size_t mlen, tlen, vlen;

    if (!line || !method || !target || !version || !had_raw_space) return -1;
    first_sp = strchr(line, ' ');
    last_sp = strrchr(line, ' ');
    if (!first_sp || !last_sp || first_sp == last_sp) return -1;

    mlen = (size_t)(first_sp - line);
    if (mlen == 0U || mlen >= method_cap) return -1;
    target_start = first_sp + 1;
    while (*target_start == ' ') target_start++;
    target_end = last_sp;
    while (target_end > target_start && target_end[-1] == ' ') target_end--;
    if (target_end <= target_start) return -1;

    tlen = (size_t)(target_end - target_start);
    vlen = strlen(last_sp + 1);
    if (tlen >= target_cap || vlen == 0U || vlen >= version_cap) return -1;

    memcpy(method, line, mlen); method[mlen] = '\0';
    memcpy(target, target_start, tlen); target[tlen] = '\0';
    memcpy(version, last_sp + 1, vlen + 1U);

    *had_raw_space = false;
    for (p = target; *p; p++) {
        if (*p == ' ' || *p == '\t') { *had_raw_space = true; break; }
    }
    return 0;
}

static bool valid_percent_triplet(const char *p)
{
    return p && p[0] == '%' && p[1] && p[2] &&
           isxdigit((unsigned char)p[1]) && isxdigit((unsigned char)p[2]);
}

/* Percent-encode unsafe query bytes without double-encoding existing %HH.
 * '&' and '=' remain separators so application/x-www-form-urlencoded
 * semantics are preserved. */
static bool compat_query_known_separator_tg(const char *p)
{
    if (!p || *p != '&') return false;
    p++;
    return strncasecmp(p, "text=", 5) == 0 ||
           strncasecmp(p, "parse_mode=", 11) == 0;
}

static int percent_encode_query_compat_tg(const char *src,
                                          char *dst, size_t dst_cap,
                                          bool *changed)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t si = 0U, di = 0U;

    if (!src || !dst || dst_cap == 0U || !changed) return -1;
    *changed = false;
    while (src[si]) {
        unsigned char c = (unsigned char)src[si];
        if (c == '%' && valid_percent_triplet(src + si)) {
            if (di + 3U >= dst_cap) return -1;
            dst[di++] = src[si++]; dst[di++] = src[si++]; dst[di++] = src[si++];
            continue;
        }
        if (c == '&' && compat_query_known_separator_tg(src + si)) {
            if (di + 1U >= dst_cap) return -1;
            dst[di++] = '&';
            si++;
            continue;
        }
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
            c == '~' || c == '=') {
            if (di + 1U >= dst_cap) return -1;
            dst[di++] = (char)c;
            si++;
            continue;
        }
        if (di + 3U >= dst_cap) return -1;
        dst[di++] = '%';
        dst[di++] = hex[(c >> 4) & 0x0fU];
        dst[di++] = hex[c & 0x0fU];
        si++;
        *changed = true;
    }
    dst[di] = '\0';
    return 0;
}

static bool compat_text_needs_html(const unsigned char *data, size_t len)
{
    size_t i, end;
    static const char *tags[] = {
        "<b>", "</b>", "<strong>", "</strong>", "<i>", "</i>",
        "<em>", "</em>", "<u>", "</u>", "<s>", "</s>",
        "<code>", "</code>", "<pre>", "</pre>", "<a ", "</a>"
    };

    if (!data || len == 0U) return false;
    for (i = 0U; i < sizeof(tags) / sizeof(tags[0]); i++) {
        if (buffer_contains_literal(data, len, tags[i])) return true;
    }
    for (i = 0U; i + 2U < len; i++) {
        if (data[i] == '%' && data[i + 1U] == '0' &&
            (data[i + 2U] == 'A' || data[i + 2U] == 'a')) return true;
    }
    for (i = 0U; i + 1U < len; i++) {
        if (data[i] == '\\' && data[i + 1U] == 'n') return true;
    }

    end = len;
    while (end > 0U && (data[end - 1U] == '\r' || data[end - 1U] == '\n')) end--;
    for (i = 0U; i < end; i++) {
        if (data[i] == '\r' || data[i] == '\n') return true;
    }
    return false;
}

static int read_http_request(int fd, struct http_request *req,
                             int64_t header_deadline_ms,
                             int64_t total_deadline_ms)
{
    unsigned char *buf = NULL;
    size_t used = 0, header_bytes, prefix;
    char *marker, *headers, *save = NULL, *line;
    char request_target[REQUEST_TARGET_SIZE];
    char encoded_query[REQUEST_TARGET_SIZE * 3U];
    char *query = NULL;
    const char *query_to_use = NULL;
    size_t query_len = 0U;
    bool query_sendmessage = false;
    bool have_length = false, have_transfer_encoding = false;
    bool expect_continue = false;
    bool raw_target_space = false, query_encoded = false;
    bool compat_header = false, compat_original_get = false;

    memset(req, 0, sizeof(*req));
    buf = calloc(1, MAX_HEADER_SIZE + 1U);
    if (!buf) return -1;
    while (used < MAX_HEADER_SIZE) {
        ssize_t n = recv_deadline(fd, buf + used, MAX_HEADER_SIZE - used, 0,
                                  header_deadline_ms);
        if (n > 0) {
            used += (size_t)n; buf[used] = '\0';
            if (strstr((char *)buf, "\r\n\r\n")) break;
        } else if (n == 0) { free(buf); return -1; }
        else if (errno == EINTR) continue;
        else { int e = errno; free(buf); return e == ETIMEDOUT ? -7 : -1; }
    }
    marker = strstr((char *)buf, "\r\n\r\n");
    if (!marker) { free(buf); return -2; }
    header_bytes = (size_t)(marker - (char *)buf) + 4U;
    prefix = used - header_bytes;

    headers = malloc(header_bytes + 1U);
    if (!headers) { free(buf); return -1; }
    memcpy(headers, buf, header_bytes);
    headers[header_bytes] = '\0';
    marker = strstr(headers, "\r\n\r\n");
    if (marker) *marker = '\0';

    line = strtok_r(headers, "\r\n", &save);
    if (!line) { free(headers); free(buf); return -3; }
    if (http_compat_text_query) {
        if (parse_request_line_compat_tg(line,
                                         req->method, sizeof(req->method),
                                         request_target, sizeof(request_target),
                                         req->version, sizeof(req->version),
                                         &raw_target_space) != 0) {
            free(headers); free(buf); return -3;
        }
        if (raw_target_space && !http_compat_auto_urlencode) {
            free(headers); free(buf); return -3;
        }
    } else {
        if (sscanf(line, "%15s %8191s %15s",
                   req->method, request_target, req->version) != 3) {
            free(headers); free(buf); return -3;
        }
    }
    if ((strcmp(req->version, "HTTP/1.0") != 0 && strcmp(req->version, "HTTP/1.1") != 0) ||
        request_target[0] != '/') {
        free(headers); free(buf); return -3;
    }
    snprintf(req->original_method, sizeof(req->original_method), "%s", req->method);

    query = strchr(request_target, '?');
    if (query) {
        char *decoded_text = NULL;
        *query++ = '\0';
        query_to_use = query;
        if (http_compat_text_query && http_compat_auto_urlencode) {
            if (percent_encode_query_compat_tg(query, encoded_query,
                                               sizeof(encoded_query),
                                               &query_encoded) != 0) {
                free(headers); free(buf); return -3;
            }
            query_to_use = encoded_query;
        }
        query_len = strlen(query_to_use);
        if (http_compat_text_query &&
            (strcmp(request_target, "/") == 0 || strcmp(request_target, "/sendMessage") == 0)) {
            decoded_text = form_get_value((const unsigned char *)query_to_use,
                                          query_len, "text");
            if (decoded_text != NULL)
                query_sendmessage = true;
            free(decoded_text);
        }
    }
    {
        size_t path_len = strlen(request_target);
        if (path_len >= sizeof(req->path)) {
            free(headers); free(buf); return -3;
        }
        memcpy(req->path, request_target, path_len + 1U);
    }

    while ((line = strtok_r(NULL, "\r\n", &save)) != NULL) {
        char *colon = strchr(line, ':');
        char *name, *value;
        if (!colon) { free(headers); free(buf); return -3; }
        *colon = '\0'; name = trim(line); value = trim(colon + 1);
        if (strcasecmp(name, "Content-Length") == 0) {
            if (have_length || parse_content_length(value, &req->content_length) != 0) {
                free(headers); free(buf); return -4;
            }
            have_length = true;
        } else if (strcasecmp(name, "Content-Type") == 0) {
            if (strlen(value) >= sizeof(req->content_type)) { free(headers); free(buf); return -3; }
            snprintf(req->content_type, sizeof(req->content_type), "%s", value);
        } else if (strcasecmp(name, "X-Caption") == 0) {
            if (strlen(value) >= sizeof(req->caption)) { free(headers); free(buf); return -3; }
            snprintf(req->caption, sizeof(req->caption), "%s", value);
        } else if (strcasecmp(name, "X-Parse-Mode") == 0) {
            if (strlen(value) >= sizeof(req->parse_mode)) { free(headers); free(buf); return -3; }
            snprintf(req->parse_mode, sizeof(req->parse_mode), "%s", value);
        } else if (strcasecmp(name, "X-TG-Compat-Text-Query") == 0) {
            bool hv = false;
            if (parse_bool_value(value, &hv) == 0 && hv) compat_header = true;
        } else if (strcasecmp(name, "X-TG-Compat-Original-Method") == 0) {
            if (strcasecmp(value, "GET") == 0) compat_original_get = true;
        } else if (strcasecmp(name, "X-Filename") == 0) {
            if (strlen(value) >= sizeof(req->filename) || strchr(value, '/') || strchr(value, '\\') || strcmp(value, ".") == 0 || strcmp(value, "..") == 0) { free(headers); free(buf); return -3; }
            snprintf(req->filename, sizeof(req->filename), "%s", value);
        } else if (strcasecmp(name, "X-Idempotency-Key") == 0) {
            size_t j;
            if (!*value || strlen(value) > IDEMPOTENCY_KEY_SIZE) { free(headers); free(buf); return -3; }
            for (j = 0; value[j]; j++) {
                unsigned char c = (unsigned char)value[j];
                if (c < 0x21 || c > 0x7e) { free(headers); free(buf); return -3; }
            }
            snprintf(req->idempotency_key, sizeof(req->idempotency_key), "%s", value);
        } else if (strcasecmp(name, "Transfer-Encoding") == 0) {
            have_transfer_encoding = true;
        } else if (strcasecmp(name, "Expect") == 0) {
            if (strcasecmp(value, "100-continue") == 0)
                expect_continue = true;
            else {
                free(headers); free(buf); return -9;
            }
        }
    }

    /* High-compatibility method normalization.  HTTP permits extension
     * method tokens, and legacy monitoring clients sometimes emit PUT,
     * PATCH, DELETE, FOO, etc. for a sendMessage request.  When
     * http_compat_text_query=yes, normalize only requests that are clearly
     * targeting the sendMessage compatibility surface.  Do not normalize
     * /sendPhoto, /sendDocument, health endpoints, or unknown paths. */
    if (http_compat_text_query &&
        strcasecmp(req->method, "POST") != 0 &&
        strcasecmp(req->method, "GET") != 0 &&
        (strcmp(req->path, "/sendMessage") == 0 || query_sendmessage ||
         (strcmp(req->path, "/") == 0 &&
          strncasecmp(req->content_type, "application/x-www-form-urlencoded", 33) == 0))) {
        req->method_compat_normalized = true;
        snprintf(req->method, sizeof(req->method), "POST");
    }

    if (strcasecmp(req->method, "POST") == 0) {
        size_t got;
        size_t endpoint_limit = MAX_REQUEST_BODY;
        bool known_post_endpoint = false;
        if (strcmp(req->path, "/sendMessage") == 0) {
            endpoint_limit = SENDMESSAGE_MAX_BODY;
            known_post_endpoint = true;
        } else if (strcmp(req->path, "/sendPhoto") == 0) {
            endpoint_limit = SENDPHOTO_MAX_BYTES;
            known_post_endpoint = true;
        } else if (strcmp(req->path, "/sendDocument") == 0) {
            known_post_endpoint = true;
        } else if (http_compat_text_query && strcmp(req->path, "/") == 0 &&
                   strncasecmp(req->content_type, "application/x-www-form-urlencoded", 33) == 0) {
            endpoint_limit = SENDMESSAGE_MAX_BODY;
            known_post_endpoint = true;
        } else if (query_sendmessage) {
            endpoint_limit = SENDMESSAGE_MAX_BODY;
            known_post_endpoint = true;
        }
        if (!known_post_endpoint) { free(headers); free(buf); return -10; }
        if (have_transfer_encoding) { free(headers); free(buf); return -5; }
        if (!have_length && !query_sendmessage) { free(headers); free(buf); return -6; }
        if (have_length && req->content_length > endpoint_limit) {
            free(headers); free(buf); return -8;
        }
        if (expect_continue && have_length && req->content_length > 0U) {
            static const char cont[] = "HTTP/1.1 100 Continue\r\n\r\n";
            if (send_all(fd, cont, sizeof(cont) - 1U) != 0) {
                free(headers); free(buf); return -1;
            }
        }
        if (have_length) {
            req->body = malloc(req->content_length + 1U);
            if (!req->body) { free(headers); free(buf); return -1; }
            if (prefix > req->content_length) prefix = req->content_length;
            if (prefix) memcpy(req->body, buf + header_bytes, prefix);
            got = prefix;
            while (got < req->content_length) {
                ssize_t n = recv_deadline(fd, req->body + got,
                                          req->content_length - got, 0,
                                          total_deadline_ms);
                if (n > 0) got += (size_t)n;
                else if (n == 0) { free(req->body); req->body = NULL; free(headers); free(buf); return -3; }
                else if (errno == EINTR) continue;
                else { int e = errno; free(req->body); req->body = NULL; free(headers); free(buf); return e == ETIMEDOUT ? -7 : -3; }
            }
            req->body[req->content_length] = '\0';
        }
    }

    if (query_sendmessage) {
        unsigned char *query_body;
        if (query_len > MAX_REQUEST_BODY) { free(req->body); req->body = NULL; free(headers); free(buf); return -4; }
        query_body = malloc(query_len + 1U);
        if (!query_body) { free(req->body); req->body = NULL; free(headers); free(buf); return -1; }
        if (query_len) memcpy(query_body, query_to_use, query_len);
        query_body[query_len] = '\0';
        free(req->body);
        req->body = query_body;
        req->content_length = query_len;
        snprintf(req->path, sizeof(req->path), "/sendMessage");
        snprintf(req->content_type, sizeof(req->content_type),
                 "application/x-www-form-urlencoded");
        req->query_sendmessage_compat = true;
        if (!req->parse_mode[0]) {
            char *decoded_text = form_get_value(req->body, req->content_length, "text");
            if (strcasecmp(req->method, "GET") == 0 ||
                (decoded_text && compat_text_needs_html((const unsigned char *)decoded_text, strlen(decoded_text))))
                snprintf(req->parse_mode, sizeof(req->parse_mode), "HTML");
            free(decoded_text);
        }
    } else if (http_compat_text_query && strcasecmp(req->method, "POST") == 0 &&
               strcmp(req->path, "/") == 0 && req->body && req->content_length > 0U &&
               strncasecmp(req->content_type, "application/x-www-form-urlencoded", 33) == 0) {
        char *decoded_text = form_get_value(req->body, req->content_length, "text");
        if (decoded_text != NULL) {
            snprintf(req->path, sizeof(req->path), "/sendMessage");
            req->query_sendmessage_compat = true;
            if (!req->parse_mode[0]) snprintf(req->parse_mode, sizeof(req->parse_mode), "HTML");
        }
        free(decoded_text);
    }

    if (http_compat_text_query && compat_header && strcmp(req->path, "/sendMessage") == 0) {
        req->compat_header_text_query = true;
        req->query_sendmessage_compat = true;
        if (!req->parse_mode[0]) {
            char *decoded_text = NULL;
            if (req->body &&
                strncasecmp(req->content_type, "application/x-www-form-urlencoded", 33) == 0)
                decoded_text = form_get_value(req->body, req->content_length, "text");
            if (compat_original_get ||
                (decoded_text && compat_text_needs_html((const unsigned char *)decoded_text, strlen(decoded_text))))
                snprintf(req->parse_mode, sizeof(req->parse_mode), "HTML");
            free(decoded_text);
        }
    }

    /* Compatibility fallback for mixed-version proxy chains.
     * tcp_failover_proxy v2.3 already rewrites /?text=... to /sendMessage,
     * but does not add the X-TG-Compat-* provenance headers introduced in
     * v2.4.  When compatibility mode is enabled, safely auto-detect supported
     * Telegram HTML tags in any form-encoded /sendMessage body that does not
     * already specify parse_mode. Plain text remains plain text.
     */
    if (http_compat_text_query && !req->parse_mode[0] &&
        strcmp(req->path, "/sendMessage") == 0 && req->body &&
        strncasecmp(req->content_type, "application/x-www-form-urlencoded", 33) == 0) {
        char *decoded_text = form_get_value(req->body, req->content_length, "text");
        if (decoded_text &&
            compat_text_needs_html((const unsigned char *)decoded_text, strlen(decoded_text))) {
            snprintf(req->parse_mode, sizeof(req->parse_mode), "HTML");
            log_msg(LOG_INFO,
                    "event=HTTP_COMPAT_HTML_AUTODETECT version=%s source=form-body parse_mode=HTML bytes=%zu compat_header=%s",
                    PROGRAM_VERSION, strlen(decoded_text), compat_header ? "yes" : "no");
        }
        free(decoded_text);
    }

    if (query_encoded) {
        log_msg(LOG_INFO,
                "event=HTTP_COMPAT_URLENCODE version=%s raw_target_space=%s query_bytes=%zu encoded_bytes=%zu",
                PROGRAM_VERSION, raw_target_space ? "yes" : "no",
                query ? strlen(query) : 0U, query_len);
    }

    free(headers); free(buf);
    return 0;
}

static void free_http_request(struct http_request *req)
{
    free(req->body); req->body = NULL;
}

static int hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static char *url_decode(const char *src, size_t len)
{
    char *out = malloc(len + 1U);
    size_t i = 0, o = 0;
    if (!out) return NULL;
    while (i < len) {
        if (src[i] == '+') { out[o++] = ' '; i++; }
        else if (src[i] == '%' && i + 2 < len) {
            int a = hexval((unsigned char)src[i + 1]);
            int b = hexval((unsigned char)src[i + 2]);
            if (a >= 0 && b >= 0) { out[o++] = (char)((a << 4) | b); i += 3; }
            else out[o++] = src[i++];
        } else out[o++] = src[i++];
    }
    out[o] = '\0';
    return out;
}

/* RAW compatibility decoder: decode valid %HH sequences but keep '+'
 * literally because RAW TCP input is not form-encoded. The decoded text is
 * later escaped by libcurl, so embedded LF becomes %0A on the Telegram HTTP
 * request exactly once. */
static int decode_raw_percent_compat(struct http_request *req)
{
    unsigned char *out;
    size_t i = 0U, o = 0U;
    bool changed = false;

    if (!req || !req->body || req->content_length == 0U) return 0;
    out = malloc(req->content_length + 1U);
    if (!out) return -1;
    while (i < req->content_length) {
        if (req->body[i] == '%' && i + 2U < req->content_length) {
            int a = hexval(req->body[i + 1U]);
            int b = hexval(req->body[i + 2U]);
            if (a >= 0 && b >= 0) {
                out[o++] = (unsigned char)((a << 4) | b);
                i += 3U;
                changed = true;
                continue;
            }
        }
        out[o++] = req->body[i++];
    }
    out[o] = '\0';
    if (changed) {
        free(req->body);
        req->body = out;
        req->content_length = o;
    } else {
        free(out);
    }
    return changed ? 1 : 0;
}

/* In HTML compatibility mode, legacy shell/monitoring payloads often carry
 * a literal two-byte \n escape. Convert it to an LF before libcurl form
 * encoding so Telegram receives %0A rather than the literal characters \n. */
static void normalize_html_newline_escapes(char *text)
{
    size_t i = 0U, o = 0U;
    if (!text) return;
    while (text[i]) {
        if (text[i] == '\\' && text[i + 1U] == 'n') {
            text[o++] = '\n';
            i += 2U;
        } else {
            text[o++] = text[i++];
        }
    }
    text[o] = '\0';
}

static char *form_get_value(const unsigned char *body, size_t len, const char *key)
{
    const char *s = (const char *)body;
    size_t keylen = strlen(key), pos = 0;
    while (pos < len) {
        size_t end = pos, eq;
        while (end < len && s[end] != '&') end++;
        eq = pos; while (eq < end && s[eq] != '=') eq++;
        if (eq < end && eq - pos == keylen && strncmp(s + pos, key, keylen) == 0)
            return url_decode(s + eq + 1, end - eq - 1);
        pos = end < len ? end + 1 : len;
    }
    return NULL;
}

static int mkdir_secure(const char *path)
{
    struct stat st;
    bool created = false;

    if (lstat(path, &st) != 0) {
        if (errno != ENOENT) return -1;
        if (mkdir(path, 0700) != 0) return -1;
        created = true;
        if (lstat(path, &st) != 0) return -1;
    }

    if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode)) {
        errno = ENOTDIR;
        return -1;
    }
    if (st.st_uid != geteuid()) {
        errno = EPERM;
        return -1;
    }

    /* Never chmod an arbitrary pre-existing path.  A pre-existing spool
     * directory must already have the required private permissions. */
    if (created) {
        if (chmod(path, 0700) != 0) return -1;
    } else if ((st.st_mode & 0777) != 0700) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

static int build_spool_paths(void)
{
    if (snprintf(spool_pending, sizeof(spool_pending), "%s/pending", spool_root) >= (int)sizeof(spool_pending) ||
        snprintf(spool_working, sizeof(spool_working), "%s/working", spool_root) >= (int)sizeof(spool_working) ||
        snprintf(spool_failed, sizeof(spool_failed), "%s/failed", spool_root) >= (int)sizeof(spool_failed) ||
        snprintf(spool_tmp, sizeof(spool_tmp), "%s/tmp", spool_root) >= (int)sizeof(spool_tmp) ||
        snprintf(spool_rate, sizeof(spool_rate), "%s/rate", spool_root) >= (int)sizeof(spool_rate) ||
        snprintf(spool_idempotency, sizeof(spool_idempotency), "%s/idempotency", spool_root) >= (int)sizeof(spool_idempotency) ||
        snprintf(spool_maintenance, sizeof(spool_maintenance), "%s/maintenance", spool_root) >= (int)sizeof(spool_maintenance)) return -1;
    return 0;
}

static int init_spool_dirs(void)
{
    if (mkdir_secure(spool_root) != 0 || mkdir_secure(spool_pending) != 0 ||
        mkdir_secure(spool_working) != 0 || mkdir_secure(spool_failed) != 0 ||
        mkdir_secure(spool_tmp) != 0 || mkdir_secure(spool_rate) != 0 ||
        mkdir_secure(spool_idempotency) != 0 || mkdir_secure(spool_maintenance) != 0) return -1;
    return 0;
}

static int fsync_dir(const char *path)
{
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    int rc;
    if (fd < 0) return -1;
    rc = fsync(fd);
    close(fd);
    return rc;
}

static int cleanup_stale_files(const char *path, const char *prefix,
                               int64_t max_age_sec, unsigned *removed)
{
    DIR *d;
    struct dirent *de;
    time_t now = time(NULL);
    unsigned count = 0;

    if (!path || !prefix) { errno = EINVAL; return -1; }
    d = opendir(path);
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        char fpath[SPOOL_PATH_SIZE];
        struct stat st;
        if (de->d_name[0] == '.') {
            if (strcmp(prefix, ".tmp-") != 0 || strncmp(de->d_name, prefix, strlen(prefix)) != 0)
                continue;
        } else if (strncmp(de->d_name, prefix, strlen(prefix)) != 0) {
            continue;
        }
        if (snprintf(fpath, sizeof(fpath), "%s/%s", path, de->d_name) >= (int)sizeof(fpath))
            continue;
        if (lstat(fpath, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        if (now != (time_t)-1 && max_age_sec >= 0 &&
            (int64_t)(now - st.st_mtime) < max_age_sec) continue;
        if (unlink(fpath) == 0) count++;
    }
    closedir(d);
    if (count) (void)fsync_dir(path);
    if (removed) *removed = count;
    return 0;
}

static int scan_dir_summary(const char *path, struct dir_summary *sum)
{
    DIR *d;
    struct dirent *de;

    memset(sum, 0, sizeof(*sum));
    d = opendir(path);
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        char fpath[SPOOL_PATH_SIZE];
        struct stat st;
        int64_t mtime_ms;
        size_t dlen;
        if (de->d_name[0] == '.') continue;
        dlen = strlen(de->d_name);
        if (dlen < 4U || strcmp(de->d_name + dlen - 4U, ".job") != 0) continue;
        if (snprintf(fpath, sizeof(fpath), "%s/%s", path, de->d_name) >= (int)sizeof(fpath)) continue;
        if (stat(fpath, &st) != 0 || !S_ISREG(st.st_mode)) continue;
        sum->count++;
        if (st.st_size > 0) sum->bytes += (unsigned long long)st.st_size;
#if defined(__linux__)
        mtime_ms = (int64_t)st.st_mtim.tv_sec * 1000LL + st.st_mtim.tv_nsec / 1000000LL;
#else
        mtime_ms = (int64_t)st.st_mtime * 1000LL;
#endif
        /* failed/ filenames encode the actual failure timestamp; use it for
         * oldest_failed_sec instead of the original spool-file mtime. */
        if (strcmp(path, spool_failed) == 0 && strncmp(de->d_name, "f-", 2) == 0) {
            char *end = NULL;
            long long v;
            errno = 0;
            v = strtoll(de->d_name + 2, &end, 10);
            if (!errno && end != de->d_name + 2 && end && *end == '-')
                mtime_ms = (int64_t)v;
        }
        if (sum->oldest_mtime_ms == 0 || mtime_ms < sum->oldest_mtime_ms)
            sum->oldest_mtime_ms = mtime_ms;
    }
    closedir(d);
    return 0;
}

static int get_queue_summary(struct queue_summary *q)
{
    struct statvfs sv;
    memset(q, 0, sizeof(*q));
    if (scan_dir_summary(spool_pending, &q->pending) != 0 ||
        scan_dir_summary(spool_working, &q->working) != 0 ||
        scan_dir_summary(spool_failed, &q->failed) != 0) return -1;
    if (statvfs(spool_root, &sv) != 0) return -1;
    q->total_bytes = q->pending.bytes + q->working.bytes + q->failed.bytes;
    q->free_bytes = (unsigned long long)sv.f_bavail * (unsigned long long)sv.f_frsize;
    return 0;
}

static bool spool_has_space(size_t body_len)
{
    struct queue_summary q;
    unsigned long long reserve = (unsigned long long)body_len + 65536ULL;

    if (get_queue_summary(&q) != 0) return false;
    if (q.pending.count + q.working.count >= MAX_PENDING_JOBS) {
        errno = ENOBUFS;
        metric_record(METRIC_CAPACITY_REJECT);
        return false;
    }
    if (q.failed.count >= MAX_FAILED_JOBS) {
        errno = EDQUOT;
        metric_record(METRIC_CAPACITY_REJECT);
        return false;
    }
    if (q.total_bytes > MAX_SPOOL_BYTES || reserve > MAX_SPOOL_BYTES - q.total_bytes) {
        errno = ENOSPC;
        metric_record(METRIC_CAPACITY_REJECT);
        return false;
    }
    if (q.free_bytes <= SPOOL_MIN_FREE_BYTES || reserve > q.free_bytes - SPOOL_MIN_FREE_BYTES) {
        errno = ENOSPC;
        metric_record(METRIC_CAPACITY_REJECT);
        return false;
    }
    return true;
}

static int random_hex(char out[33])
{
    unsigned char rnd[16];
    size_t i;
    ssize_t n = getrandom(rnd, sizeof(rnd), 0);
    if (n != (ssize_t)sizeof(rnd)) return -1;
    for (i = 0; i < sizeof(rnd); i++) snprintf(out + i * 2U, 3U, "%02x", rnd[i]);
    out[32] = '\0';
    return 0;
}

static int write_all_fd(int fd, const void *buf, size_t len)
{
    const unsigned char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n > 0) { p += (size_t)n; len -= (size_t)n; }
        else if (n < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}



static int maintenance_state_path(const struct channel *ch, char *out, size_t outsz)
{
    int n;
    if (!ch || !out || outsz == 0U) { errno = EINVAL; return -1; }
    n = snprintf(out, outsz, "%s/port-%d.state", spool_maintenance, ch->port);
    if (n < 0 || (size_t)n >= outsz) { errno = ENAMETOOLONG; return -1; }
    return 0;
}

struct maintenance_snapshot {
    bool on;
    int64_t since_ms;
    int64_t expires_ms;
    uint64_t suppressed_count;
    char reason[MAINTENANCE_REASON_SIZE];
    char enabled_by[NI_MAXHOST];
};

struct maintenance_notice_event {
    struct channel *ch;
    bool enabled;
    uint64_t generation;
    int64_t since_ms;
    int64_t expires_ms;
    uint64_t suppressed_count;
    char token[TOKEN_SIZE];
    char chat_id[CHAT_ID_SIZE];
    char label[LABEL_SIZE];
    char reason[MAINTENANCE_REASON_SIZE];
    char actor[NI_MAXHOST];
    char trigger[MAINT_NOTICE_TRIGGER_SIZE];
};

enum maintenance_command_type {
    MAINT_CMD_NONE = 0,
    MAINT_CMD_INVALID,
    MAINT_CMD_STATUS,
    MAINT_CMD_ON,
    MAINT_CMD_OFF,
    MAINT_CMD_EXTEND,
    MAINT_CMD_MARK,
    MAINT_CMD_TEST_LOG_ONLY
};

struct maintenance_command {
    enum maintenance_command_type type;
    unsigned long long ttl_sec;
    char reason[MAINTENANCE_REASON_SIZE];
    char payload[MAGIC_TEST_TEXT_SIZE];
    char error[160];
};

static int maintenance_write_state_values(const struct channel *ch,
                                          int64_t since_ms,
                                          int64_t expires_ms,
                                          const char *reason,
                                          const char *enabled_by,
                                          uint64_t suppressed_count)
{
    char path[SPOOL_PATH_SIZE], tmp[SPOOL_PATH_SIZE], body[2048];
    int fd = -1, n;
    if (maintenance_state_path(ch, path, sizeof(path)) != 0) return -1;
    n = snprintf(tmp, sizeof(tmp), "%s/.tmp-port-%d-%ld-%lld",
                 spool_maintenance, ch->port, (long)getpid(), (long long)realtime_ms());
    if (n < 0 || (size_t)n >= sizeof(tmp)) { errno = ENAMETOOLONG; return -1; }
    n = snprintf(body, sizeof(body),
                 "TGMAINT 2\nmaintenance_suppress=on\nport=%d\nchat_id=%s\nlabel=%s\n"
                 "since_ms=%lld\nexpires_ms=%lld\nreason=%s\nenabled_by=%s\nsuppressed_count=%llu\n",
                 ch->port, ch->chat_id, ch->label,
                 (long long)since_ms, (long long)expires_ms,
                 reason ? reason : "", enabled_by ? enabled_by : "",
                 (unsigned long long)suppressed_count);
    if (n < 0 || (size_t)n >= sizeof(body)) { errno = EOVERFLOW; return -1; }
    fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (write_all_fd(fd, body, (size_t)n) != 0 || fsync(fd) != 0) {
        int e = errno; close(fd); unlink(tmp); errno = e; return -1;
    }
    if (close(fd) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    if (rename(tmp, path) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    return fsync_dir(spool_maintenance);
}

static int maintenance_persist_off(const struct channel *ch)
{
    char path[SPOOL_PATH_SIZE];
    if (maintenance_state_path(ch, path, sizeof(path)) != 0) return -1;
    if (unlink(path) != 0 && errno != ENOENT) return -1;
    return fsync_dir(spool_maintenance);
}


static int maintenance_notice_state_path(const struct channel *ch, char *out, size_t outsz)
{
    int n;
    if (!ch || !out || outsz == 0U) { errno = EINVAL; return -1; }
    n = snprintf(out, outsz, "%s/port-%d.notice", spool_maintenance, ch->port);
    if (n < 0 || (size_t)n >= outsz) { errno = ENAMETOOLONG; return -1; }
    return 0;
}

static int maintenance_notice_persist(struct channel *ch,
                                      int64_t current_message_id,
                                      int64_t stale_message_id,
                                      bool state_on)
{
    char path[SPOOL_PATH_SIZE], tmp[SPOOL_PATH_SIZE], body[512];
    int fd = -1, n;
    if (!ch) { errno = EINVAL; return -1; }
    if (maintenance_notice_state_path(ch, path, sizeof(path)) != 0) return -1;
    n = snprintf(tmp, sizeof(tmp), "%s/.tmp-notice-%d-%ld-%lld",
                 spool_maintenance, ch->port, (long)getpid(), (long long)realtime_ms());
    if (n < 0 || (size_t)n >= sizeof(tmp)) { errno = ENAMETOOLONG; return -1; }
    n = snprintf(body, sizeof(body),
                 "TGNOTICE 1\nport=%d\ncurrent_message_id=%lld\nstale_message_id=%lld\nstate=%s\nupdated_ms=%lld\n",
                 ch->port, (long long)current_message_id, (long long)stale_message_id,
                 state_on ? "on" : "off", (long long)realtime_ms());
    if (n < 0 || (size_t)n >= sizeof(body)) { errno = EOVERFLOW; return -1; }
    fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (write_all_fd(fd, body, (size_t)n) != 0 || fsync(fd) != 0) {
        int e = errno; close(fd); unlink(tmp); errno = e; return -1;
    }
    if (close(fd) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    if (rename(tmp, path) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    if (fsync_dir(spool_maintenance) != 0) return -1;
    ch->maintenance_notice_message_id = current_message_id;
    ch->maintenance_notice_stale_message_id = stale_message_id;
    ch->maintenance_notice_state_valid = true;
    ch->maintenance_notice_state_on = state_on;
    return 0;
}

static int maintenance_notice_load_states(void)
{
    size_t i;
    for (i = 0U; i < channel_count; i++) {
        struct channel *ch = &channels[i];
        char path[SPOOL_PATH_SIZE], line[512];
        struct stat st;
        FILE *fp;
        int64_t current_id = 0, stale_id = 0;
        bool state_on = false, state_seen = false;
        if (maintenance_notice_state_path(ch, path, sizeof(path)) != 0) return -1;
        if (lstat(path, &st) != 0) {
            if (errno == ENOENT) continue;
            return -1;
        }
        if (S_ISLNK(st.st_mode) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
            (st.st_mode & (S_IRWXG | S_IRWXO)) != 0) { errno = EPERM; return -1; }
        fp = fopen(path, "r");
        if (!fp) return -1;
        if (!fgets(line, sizeof(line), fp) || strncmp(line, "TGNOTICE 1", 10) != 0) {
            fclose(fp); errno = EINVAL; return -1;
        }
        while (fgets(line, sizeof(line), fp)) {
            char *p = trim(line), *eq = strchr(p, '=');
            int64_t v;
            if (!eq) continue;
            *eq++ = '\0';
            if (strcmp(p, "current_message_id") == 0 && parse_i64_strict(eq, &v) == 0 && v > 0) current_id = v;
            else if (strcmp(p, "stale_message_id") == 0 && parse_i64_strict(eq, &v) == 0 && v > 0) stale_id = v;
            else if (strcmp(p, "state") == 0) {
                state_seen = true;
                if (strcmp(eq, "on") == 0) state_on = true;
                else if (strcmp(eq, "off") == 0) state_on = false;
                else { fclose(fp); errno = EINVAL; return -1; }
            }
        }
        fclose(fp);
        ch->maintenance_notice_message_id = current_id;
        ch->maintenance_notice_stale_message_id = stale_id;
        ch->maintenance_notice_state_valid = state_seen;
        ch->maintenance_notice_state_on = state_on;
        log_msg(LOG_NOTICE,
                "event=MAINTENANCE_NOTICE_STATE_RESTORED version=%s listen_port=%d label=%s current_message_id=%lld stale_message_id=%lld state=%s file=%s",
                PROGRAM_VERSION, ch->port, ch->label, (long long)current_id,
                (long long)stale_id, state_on ? "on" : "off", path);
    }
    return 0;
}

static void maintenance_clear_locked(struct channel *ch)
{
    ch->maintenance_suppress = false;
    ch->maintenance_since_ms = 0;
    ch->maintenance_expires_ms = 0;
    ch->maintenance_reason[0] = '\0';
    ch->maintenance_enabled_by[0] = '\0';
    ch->maintenance_suppressed_count = 0;
}

static bool maintenance_expire_if_needed(struct channel *ch, const char *source)
{
    bool expired = false;
    int cleanup_rc = 0;
    int64_t now = realtime_ms();
    int64_t old_since = 0, old_expires = 0;
    uint64_t old_count = 0;
    char old_reason[MAINTENANCE_REASON_SIZE] = "";
    char old_actor[NI_MAXHOST] = "";
    struct maintenance_notice_event notice_ev;
    bool have_notice_ev = false;

    if (!ch) return false;
    pthread_mutex_lock(&maintenance_mutex);
    if (ch->maintenance_suppress && ch->maintenance_expires_ms > 0 &&
        now >= ch->maintenance_expires_ms) {
        expired = true;
        old_since = ch->maintenance_since_ms;
        old_expires = ch->maintenance_expires_ms;
        old_count = ch->maintenance_suppressed_count;
        snprintf(old_reason, sizeof(old_reason), "%s", ch->maintenance_reason);
        snprintf(old_actor, sizeof(old_actor), "%s", ch->maintenance_enabled_by);
        cleanup_rc = maintenance_persist_off(ch);
        maintenance_clear_locked(ch);
        ch->maintenance_generation++;
        memset(&notice_ev, 0, sizeof(notice_ev));
        notice_ev.ch = ch;
        notice_ev.enabled = false;
        notice_ev.generation = ch->maintenance_generation;
        notice_ev.since_ms = old_since;
        notice_ev.expires_ms = old_expires;
        notice_ev.suppressed_count = old_count;
        snprintf(notice_ev.token, sizeof(notice_ev.token), "%s", ch->token);
        snprintf(notice_ev.chat_id, sizeof(notice_ev.chat_id), "%s", ch->chat_id);
        snprintf(notice_ev.label, sizeof(notice_ev.label), "%s", ch->label);
        snprintf(notice_ev.reason, sizeof(notice_ev.reason), "%s", old_reason);
        snprintf(notice_ev.actor, sizeof(notice_ev.actor), "%s", old_actor[0] ? old_actor : "timer");
        snprintf(notice_ev.trigger, sizeof(notice_ev.trigger), "%s", "auto-expire");
        have_notice_ev = true;
    }
    pthread_mutex_unlock(&maintenance_mutex);

    if (expired) {
        metric_record(METRIC_MAINTENANCE_TOGGLE);
        metric_record(METRIC_MAINTENANCE_AUTO_EXPIRE);
        log_msg(cleanup_rc == 0 ? LOG_WARNING : LOG_ERR,
                "event=MAINTENANCE_AUTO_EXPIRE version=%s listen_port=%d label=%s chat_id=%s source=%s since_ms=%lld expires_ms=%lld suppressed_count=%llu reason=\"%s\" persistent_cleanup=%s",
                PROGRAM_VERSION, ch->port, ch->label, ch->chat_id,
                source ? source : "timer", (long long)old_since,
                (long long)old_expires, (unsigned long long)old_count,
                old_reason, cleanup_rc == 0 ? "yes" : "no");
        if (cleanup_rc == 0 && have_notice_ev)
            maintenance_spawn_auto_off_notice(&notice_ev);
    }
    return expired;
}

static void maintenance_get_snapshot(struct channel *ch,
                                     struct maintenance_snapshot *snap)
{
    if (!snap) return;
    memset(snap, 0, sizeof(*snap));
    if (!ch) return;
    (void)maintenance_expire_if_needed(ch, "state-check");
    pthread_mutex_lock(&maintenance_mutex);
    snap->on = ch->maintenance_suppress;
    snap->since_ms = ch->maintenance_since_ms;
    snap->expires_ms = ch->maintenance_expires_ms;
    snap->suppressed_count = ch->maintenance_suppressed_count;
    snprintf(snap->reason, sizeof(snap->reason), "%s", ch->maintenance_reason);
    snprintf(snap->enabled_by, sizeof(snap->enabled_by), "%s", ch->maintenance_enabled_by);
    pthread_mutex_unlock(&maintenance_mutex);
}

static bool maintenance_get_state(struct channel *ch, int64_t *since_ms)
{
    struct maintenance_snapshot snap;
    maintenance_get_snapshot(ch, &snap);
    if (since_ms) *since_ms = snap.since_ms;
    return snap.on;
}

static size_t maintenance_active_channels(void)
{
    size_t i, count = 0U;
    for (i = 0U; i < channel_count; i++) {
        struct maintenance_snapshot snap;
        if (!channels[i].selected) continue;
        maintenance_get_snapshot(&channels[i], &snap);
        if (snap.on) count++;
    }
    return count;
}

static int maintenance_enable(struct channel *ch,
                              unsigned long long ttl_sec,
                              const char *reason,
                              const char *client_ip, unsigned client_port,
                              const char *source)
{
    bool old_on;
    int rc;
    int64_t now = realtime_ms();
    int64_t since_ms, expires_ms;
    uint64_t suppressed_count;
    char next_reason[MAINTENANCE_REASON_SIZE];
    const char *actor = (client_ip && *client_ip) ? client_ip : "local";

    if (!ch || ttl_sec > MAINTENANCE_MAX_TTL_SEC) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&maintenance_mutex);
    old_on = ch->maintenance_suppress;
    since_ms = old_on && ch->maintenance_since_ms > 0 ? ch->maintenance_since_ms : now;
    expires_ms = ttl_sec > 0ULL ? now + (int64_t)(ttl_sec * 1000ULL) : 0;
    suppressed_count = old_on ? ch->maintenance_suppressed_count : 0U;
    if (reason && *reason) snprintf(next_reason, sizeof(next_reason), "%s", reason);
    else if (old_on) snprintf(next_reason, sizeof(next_reason), "%s", ch->maintenance_reason);
    else next_reason[0] = '\0';

    rc = maintenance_write_state_values(ch, since_ms, expires_ms, next_reason,
                                        actor, suppressed_count);
    if (rc == 0) {
        ch->maintenance_suppress = true;
        ch->maintenance_since_ms = since_ms;
        ch->maintenance_expires_ms = expires_ms;
        snprintf(ch->maintenance_reason, sizeof(ch->maintenance_reason), "%s", next_reason);
        snprintf(ch->maintenance_enabled_by, sizeof(ch->maintenance_enabled_by), "%s", actor);
        ch->maintenance_suppressed_count = suppressed_count;
        ch->maintenance_generation++;
    }
    pthread_mutex_unlock(&maintenance_mutex);

    if (rc != 0) {
        log_msg(LOG_ERR,
                "event=MAINTENANCE_ENABLE_FAIL version=%s client_ip=%s client_port=%u listen_port=%d label=%s source=%s ttl_sec=%llu error=%s",
                PROGRAM_VERSION, actor, client_port, ch->port, ch->label,
                source ? source : "unknown", ttl_sec, strerror(errno));
        return -1;
    }
    if (!old_on) metric_record(METRIC_MAINTENANCE_TOGGLE);
    log_msg(LOG_WARNING,
            "event=%s version=%s client_ip=%s client_port=%u listen_port=%d label=%s chat_id=%s source=%s state=on ttl_sec=%llu expires_ms=%lld reason=\"%s\" suppressed_count=%llu persistent=yes",
            old_on ? "MAINTENANCE_REFRESH" : "MAINTENANCE_TOGGLE",
            PROGRAM_VERSION, actor, client_port, ch->port, ch->label, ch->chat_id,
            source ? source : "unknown", ttl_sec, (long long)expires_ms,
            next_reason, (unsigned long long)suppressed_count);
    return 0;
}

static int maintenance_disable(struct channel *ch,
                               const char *client_ip, unsigned client_port,
                               const char *source)
{
    bool old_on;
    int rc;
    uint64_t old_count = 0;
    char old_reason[MAINTENANCE_REASON_SIZE] = "";
    const char *actor = (client_ip && *client_ip) ? client_ip : "local";

    if (!ch) { errno = EINVAL; return -1; }
    (void)maintenance_expire_if_needed(ch, "off-command");
    pthread_mutex_lock(&maintenance_mutex);
    old_on = ch->maintenance_suppress;
    if (!old_on) {
        pthread_mutex_unlock(&maintenance_mutex);
        log_msg(LOG_NOTICE,
                "event=MAINTENANCE_TOGGLE_NOOP version=%s client_ip=%s client_port=%u listen_port=%d label=%s source=%s state=off",
                PROGRAM_VERSION, actor, client_port, ch->port, ch->label,
                source ? source : "unknown");
        return 0;
    }
    old_count = ch->maintenance_suppressed_count;
    snprintf(old_reason, sizeof(old_reason), "%s", ch->maintenance_reason);
    rc = maintenance_persist_off(ch);
    if (rc == 0) {
        maintenance_clear_locked(ch);
        ch->maintenance_generation++;
    }
    pthread_mutex_unlock(&maintenance_mutex);
    if (rc != 0) return -1;
    metric_record(METRIC_MAINTENANCE_TOGGLE);
    log_msg(LOG_WARNING,
            "event=MAINTENANCE_TOGGLE version=%s client_ip=%s client_port=%u listen_port=%d label=%s chat_id=%s source=%s old=on new=off suppressed_count=%llu reason=\"%s\" persistent=yes",
            PROGRAM_VERSION, actor, client_port, ch->port, ch->label, ch->chat_id,
            source ? source : "unknown", (unsigned long long)old_count, old_reason);
    return 0;
}

/* Return 0 on success, -2 when maintenance is OFF, -3 when it is indefinite. */
static int maintenance_extend(struct channel *ch,
                              unsigned long long ttl_sec,
                              const char *client_ip, unsigned client_port,
                              const char *source)
{
    int rc;
    int64_t now = realtime_ms(), old_expires, new_expires;
    const char *actor = (client_ip && *client_ip) ? client_ip : "local";
    if (!ch || ttl_sec == 0ULL || ttl_sec > MAINTENANCE_MAX_TTL_SEC) { errno = EINVAL; return -1; }
    (void)maintenance_expire_if_needed(ch, "extend-command");
    pthread_mutex_lock(&maintenance_mutex);
    if (!ch->maintenance_suppress) { pthread_mutex_unlock(&maintenance_mutex); return -2; }
    if (ch->maintenance_expires_ms == 0) { pthread_mutex_unlock(&maintenance_mutex); return -3; }
    old_expires = ch->maintenance_expires_ms;
    new_expires = (old_expires > now ? old_expires : now) + (int64_t)(ttl_sec * 1000ULL);
    rc = maintenance_write_state_values(ch, ch->maintenance_since_ms, new_expires,
                                        ch->maintenance_reason, ch->maintenance_enabled_by,
                                        ch->maintenance_suppressed_count);
    if (rc == 0) ch->maintenance_expires_ms = new_expires;
    pthread_mutex_unlock(&maintenance_mutex);
    if (rc != 0) return -1;
    log_msg(LOG_WARNING,
            "event=MAINTENANCE_EXTEND version=%s client_ip=%s client_port=%u listen_port=%d label=%s source=%s extend_sec=%llu old_expires_ms=%lld new_expires_ms=%lld",
            PROGRAM_VERSION, actor, client_port, ch->port, ch->label,
            source ? source : "unknown", ttl_sec,
            (long long)old_expires, (long long)new_expires);
    return 0;
}

static int maintenance_checkpoint_state(struct channel *ch)
{
    int rc = 0;
    if (!ch) return -1;
    pthread_mutex_lock(&maintenance_mutex);
    if (ch->maintenance_suppress)
        rc = maintenance_write_state_values(ch, ch->maintenance_since_ms,
                                            ch->maintenance_expires_ms,
                                            ch->maintenance_reason,
                                            ch->maintenance_enabled_by,
                                            ch->maintenance_suppressed_count);
    pthread_mutex_unlock(&maintenance_mutex);
    return rc;
}

static void maintenance_checkpoint_all(void)
{
    size_t i;
    for (i = 0U; i < channel_count; i++) {
        if (maintenance_checkpoint_state(&channels[i]) != 0)
            log_msg(LOG_ERR,
                    "event=MAINTENANCE_CHECKPOINT_FAIL version=%s listen_port=%d error=%s",
                    PROGRAM_VERSION, channels[i].port, strerror(errno));
    }
}

static void maintenance_expire_all(void)
{
    size_t i;
    for (i = 0U; i < channel_count; i++)
        (void)maintenance_expire_if_needed(&channels[i], "timer");
}

static int maintenance_load_states(void)
{
    size_t i;
    for (i = 0U; i < channel_count; i++) {
        char path[SPOOL_PATH_SIZE], line[1024];
        struct stat st;
        struct channel *ch = &channels[i];
        FILE *fp;
        int version = 0;
        int64_t since_ms = 0, expires_ms = 0;
        uint64_t suppressed_count = 0;
        char reason[MAINTENANCE_REASON_SIZE] = "";
        char enabled_by[NI_MAXHOST] = "";
        if (maintenance_state_path(ch, path, sizeof(path)) != 0) return -1;
        if (lstat(path, &st) != 0) {
            if (errno == ENOENT) continue;
            return -1;
        }
        if (S_ISLNK(st.st_mode) || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
            (st.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
            errno = EPERM;
            return -1;
        }
        fp = fopen(path, "r");
        if (!fp) return -1;
        if (!fgets(line, sizeof(line), fp)) { fclose(fp); errno = EINVAL; return -1; }
        if (strncmp(line, "TGMAINT 2", 9) == 0) version = 2;
        else if (strncmp(line, "TGMAINT 1", 9) == 0) version = 1;
        else { fclose(fp); errno = EINVAL; return -1; }
        while (fgets(line, sizeof(line), fp)) {
            char *p = trim(line), *eq = strchr(p, '=');
            if (!eq) continue;
            *eq++ = '\0';
            if (strcmp(p, "since_ms") == 0) (void)parse_i64_strict(eq, &since_ms);
            else if (strcmp(p, "expires_ms") == 0) (void)parse_i64_strict(eq, &expires_ms);
            else if (strcmp(p, "reason") == 0) snprintf(reason, sizeof(reason), "%s", eq);
            else if (strcmp(p, "enabled_by") == 0) snprintf(enabled_by, sizeof(enabled_by), "%s", eq);
            else if (strcmp(p, "suppressed_count") == 0) {
                char *endp = NULL;
                unsigned long long v;
                errno = 0;
                v = strtoull(eq, &endp, 10);
                if (!errno && endp && *endp == '\0') suppressed_count = (uint64_t)v;
            }
        }
        fclose(fp);
        if (since_ms <= 0) {
#if defined(__linux__)
            since_ms = (int64_t)st.st_mtim.tv_sec * 1000LL + st.st_mtim.tv_nsec / 1000000LL;
#else
            since_ms = (int64_t)st.st_mtime * 1000LL;
#endif
        }
        if (version == 1) expires_ms = 0;
        if (expires_ms > 0 && realtime_ms() >= expires_ms) {
            int cleanup_rc = maintenance_persist_off(ch);
            metric_record(METRIC_MAINTENANCE_AUTO_EXPIRE);
            log_msg(cleanup_rc == 0 ? LOG_WARNING : LOG_ERR,
                    "event=MAINTENANCE_EXPIRED_AT_START version=%s listen_port=%d label=%s expires_ms=%lld persistent_cleanup=%s",
                    PROGRAM_VERSION, ch->port, ch->label, (long long)expires_ms,
                    cleanup_rc == 0 ? "yes" : "no");
            continue;
        }
        pthread_mutex_lock(&maintenance_mutex);
        ch->maintenance_suppress = true;
        ch->maintenance_since_ms = since_ms;
        ch->maintenance_expires_ms = expires_ms;
        ch->maintenance_suppressed_count = suppressed_count;
        ch->maintenance_generation++;
        snprintf(ch->maintenance_reason, sizeof(ch->maintenance_reason), "%s", reason);
        snprintf(ch->maintenance_enabled_by, sizeof(ch->maintenance_enabled_by), "%s", enabled_by);
        pthread_mutex_unlock(&maintenance_mutex);
        log_msg(LOG_WARNING,
                "event=MAINTENANCE_STATE_RESTORED version=%s listen_port=%d label=%s chat_id=%s state=on expires_ms=%lld reason=\"%s\" suppressed_count=%llu file=%s",
                PROGRAM_VERSION, ch->port, ch->label, ch->chat_id,
                (long long)expires_ms, reason, (unsigned long long)suppressed_count, path);
    }
    return 0;
}

static bool maintenance_valid_single_line(const char *s, size_t len)
{
    size_t i = 0U;
    if (!s || len == 0U) return false;
    while (i < len) {
        size_t seq;
        unsigned char c = (unsigned char)s[i];
        if (c == '\r' || c == '\n' || c == '\0' || c < 0x20U || c == 0x7fU) return false;
        seq = utf8_sequence_len((const unsigned char *)s + i, len - i);
        if (seq == 0U) return false;
        i += seq;
    }
    return true;
}

static bool maintenance_valid_test_text(const char *s, size_t len)
{
    size_t i = 0U;
    if (!s || len == 0U || len >= MAGIC_TEST_TEXT_SIZE) return false;
    while (i < len) {
        size_t seq;
        if ((unsigned char)s[i] == 0U) return false;
        seq = utf8_sequence_len((const unsigned char *)s + i, len - i);
        if (seq == 0U) return false;
        i += seq;
    }
    return true;
}

static int maintenance_parse_ttl(const char *s, size_t len, unsigned long long *out)
{
    char buf[32], *endp = NULL;
    unsigned long long v;
    if (!s || !out || len == 0U || len >= sizeof(buf)) return -1;
    memcpy(buf, s, len); buf[len] = '\0';
    errno = 0;
    v = strtoull(buf, &endp, 10);
    if (errno || !endp || *endp != '\0' || v == 0ULL || v > MAINTENANCE_MAX_TTL_SEC) return -1;
    *out = v;
    return 0;
}

static void maintenance_parse_command(const struct http_request *req,
                                      struct maintenance_command *cmd)
{
    const unsigned char *data = NULL;
    size_t len = 0U, begin = 0U, end;
    char *form_text = NULL;
    const char *text;
    size_t tlen;

    memset(cmd, 0, sizeof(*cmd));
    if (!req || strcmp(req->path, "/sendMessage") != 0) return;
    if (strncasecmp(req->content_type, "application/x-www-form-urlencoded", 33) == 0) {
        form_text = form_get_value(req->body, req->content_length, "text");
        if (!form_text) return;
        data = (const unsigned char *)form_text;
        len = strlen(form_text);
    } else {
        data = req->body;
        len = req->content_length;
    }
    if (!data) goto out;
    end = len;
    while (begin < end && (data[begin] == ' ' || data[begin] == '\t' || data[begin] == '\r' || data[begin] == '\n')) begin++;
    while (end > begin && (data[end - 1U] == ' ' || data[end - 1U] == '\t' || data[end - 1U] == '\r' || data[end - 1U] == '\n')) end--;
    text = (const char *)data + begin;
    tlen = end - begin;

#define EXACT_MAGIC(lit_, type_) do { \
    if (tlen == strlen(lit_) && memcmp(text, (lit_), tlen) == 0) { cmd->type = (type_); goto out; } \
} while (0)
    EXACT_MAGIC(MAINTENANCE_MAGIC_STATUS, MAINT_CMD_STATUS);
    EXACT_MAGIC(MAINTENANCE_MAGIC_OFF, MAINT_CMD_OFF);
    EXACT_MAGIC(MAINTENANCE_MAGIC_ON, MAINT_CMD_ON);
    if (tlen == strlen(MAINTENANCE_MAGIC_ON_30M) &&
        memcmp(text, MAINTENANCE_MAGIC_ON_30M, tlen) == 0) {
        cmd->type = MAINT_CMD_ON;
        cmd->ttl_sec = 1800ULL;
        goto out;
    }
#undef EXACT_MAGIC

    if (tlen >= strlen(MAINTENANCE_MAGIC_ON_PREFIX) &&
        memcmp(text, MAINTENANCE_MAGIC_ON_PREFIX, strlen(MAINTENANCE_MAGIC_ON_PREFIX)) == 0) {
        const char *arg = text + strlen(MAINTENANCE_MAGIC_ON_PREFIX);
        size_t alen = tlen - strlen(MAINTENANCE_MAGIC_ON_PREFIX);
        const char *colon = memchr(arg, ':', alen);
        size_t ttl_len = colon ? (size_t)(colon - arg) : alen;
        cmd->type = MAINT_CMD_INVALID;
        if (maintenance_parse_ttl(arg, ttl_len, &cmd->ttl_sec) != 0) {
            snprintf(cmd->error, sizeof(cmd->error), "maintenance TTL must be 1..604800 seconds");
            goto out;
        }
        if (colon) {
            const char *reason = colon + 1;
            size_t rlen = alen - ttl_len - 1U;
            if (rlen == 0U || rlen >= sizeof(cmd->reason) || !maintenance_valid_single_line(reason, rlen)) {
                snprintf(cmd->error, sizeof(cmd->error), "maintenance reason must be valid single-line UTF-8 and <=255 bytes");
                goto out;
            }
            memcpy(cmd->reason, reason, rlen); cmd->reason[rlen] = '\0';
        }
        cmd->type = MAINT_CMD_ON;
        goto out;
    }

    if (tlen >= strlen(MAINTENANCE_MAGIC_EXTEND_PREFIX) &&
        memcmp(text, MAINTENANCE_MAGIC_EXTEND_PREFIX, strlen(MAINTENANCE_MAGIC_EXTEND_PREFIX)) == 0) {
        const char *arg = text + strlen(MAINTENANCE_MAGIC_EXTEND_PREFIX);
        size_t alen = tlen - strlen(MAINTENANCE_MAGIC_EXTEND_PREFIX);
        cmd->type = MAINT_CMD_INVALID;
        if (memchr(arg, ':', alen) || maintenance_parse_ttl(arg, alen, &cmd->ttl_sec) != 0) {
            snprintf(cmd->error, sizeof(cmd->error), "extend TTL must be 1..604800 seconds");
            goto out;
        }
        cmd->type = MAINT_CMD_EXTEND;
        goto out;
    }

    if (tlen >= strlen(MAINTENANCE_MAGIC_MARK_PREFIX) &&
        memcmp(text, MAINTENANCE_MAGIC_MARK_PREFIX, strlen(MAINTENANCE_MAGIC_MARK_PREFIX)) == 0) {
        const char *arg = text + strlen(MAINTENANCE_MAGIC_MARK_PREFIX);
        size_t alen = tlen - strlen(MAINTENANCE_MAGIC_MARK_PREFIX);
        cmd->type = MAINT_CMD_INVALID;
        if (alen == 0U || alen >= sizeof(cmd->reason) || !maintenance_valid_single_line(arg, alen)) {
            snprintf(cmd->error, sizeof(cmd->error), "marker must be valid single-line UTF-8 and <=255 bytes");
            goto out;
        }
        memcpy(cmd->reason, arg, alen); cmd->reason[alen] = '\0';
        cmd->type = MAINT_CMD_MARK;
        goto out;
    }

    if (tlen >= strlen(TEST_LOG_ONLY_PREFIX) &&
        memcmp(text, TEST_LOG_ONLY_PREFIX, strlen(TEST_LOG_ONLY_PREFIX)) == 0) {
        const char *arg = text + strlen(TEST_LOG_ONLY_PREFIX);
        size_t alen = tlen - strlen(TEST_LOG_ONLY_PREFIX);
        cmd->type = MAINT_CMD_INVALID;
        if (!maintenance_valid_test_text(arg, alen)) {
            snprintf(cmd->error, sizeof(cmd->error), "test log text must be non-empty valid UTF-8 and <8192 bytes");
            goto out;
        }
        memcpy(cmd->payload, arg, alen); cmd->payload[alen] = '\0';
        cmd->type = MAINT_CMD_TEST_LOG_ONLY;
        goto out;
    }

    /* A typo that starts with our reserved namespace must fail closed instead
     * of being delivered to Telegram as an ordinary message. */
    if ((tlen >= 5U && memcmp(text, "__TG_", 5U) == 0) ||
        (tlen >= 17U && memcmp(text, "__TG_MAINTENANCE_", 17U) == 0)) {
        cmd->type = MAINT_CMD_INVALID;
        snprintf(cmd->error, sizeof(cmd->error), "unknown or malformed reserved magic command");
    }
out:
    free(form_text);
}

static int maintenance_make_audit_id(char out[JOB_ID_SIZE])
{
    char rnd[33];
    int n;
    if (random_hex(rnd) != 0) snprintf(rnd, sizeof(rnd), "fallback%ld", (long)getpid());
    n = snprintf(out, JOB_ID_SIZE, "logonly-%lld-%s", (long long)realtime_ms(), rnd);
    return (n < 0 || n >= JOB_ID_SIZE) ? -1 : 0;
}

static void maintenance_log_suppressed(const struct ingest_ctx *ctx,
                                       const struct http_request *req,
                                       const char *source)
{
    char audit_id[JOB_ID_SIZE] = "suppressed";
    int64_t since_ms = 0;
    int64_t age_sec = 0;
    uint64_t channel_count_now = 0;
    bool checkpoint = false;
    if (!ctx || !req) return;
    (void)maintenance_make_audit_id(audit_id);
    (void)maintenance_get_state(ctx->ch, &since_ms);
    if (since_ms > 0 && realtime_ms() > since_ms) age_sec = (realtime_ms() - since_ms) / 1000LL;
    pthread_mutex_lock(&maintenance_mutex);
    if (ctx->ch->maintenance_suppress) {
        ctx->ch->maintenance_suppressed_count++;
        channel_count_now = ctx->ch->maintenance_suppressed_count;
        checkpoint = (channel_count_now % MAINTENANCE_COUNT_CHECKPOINT) == 0U;
    }
    pthread_mutex_unlock(&maintenance_mutex);
    if (checkpoint && maintenance_checkpoint_state(ctx->ch) != 0)
        log_msg(LOG_WARNING,
                "event=MAINTENANCE_COUNT_CHECKPOINT_FAIL version=%s listen_port=%d error=%s",
                PROGRAM_VERSION, ctx->ch->port, strerror(errno));
    metric_record(METRIC_SUPPRESSED);
    log_msg(LOG_NOTICE,
            "event=MAINTENANCE_SUPPRESSED version=%s audit_id=%s client_ip=%s client_port=%u listen_port=%d label=%s chat_id=%s endpoint=%s source=%s bytes=%zu maintenance_age_sec=%lld suppressed_count=%llu action=log_only queued=no telegram_sent=no",
            PROGRAM_VERSION, audit_id, ctx->client_ip, ctx->client_port,
            ctx->ch->port, ctx->ch->label, ctx->ch->chat_id, req->path,
            source ? source : "unknown", req->content_length, (long long)age_sec,
            (unsigned long long)channel_count_now);
    audit_log_request(audit_id, ctx->client_ip, ctx->ch, req);
}

static void maintenance_send_status_response(int fd, struct channel *ch,
                                             bool raw, const char *result)
{
    struct maintenance_snapshot snap;
    int64_t now = realtime_ms();
    int64_t age_sec = 0, remain_sec = -1;
    char reason_json[MAINTENANCE_REASON_SIZE * 2U];
    char actor_json[NI_MAXHOST * 2U];
    char label_json[512];
    char body[2048];
    int64_t notice_message_id = 0;
    bool notice_state_valid = false, notice_state_on = false;
    int n;
    maintenance_get_snapshot(ch, &snap);
    pthread_mutex_lock(&maintenance_notice_mutex);
    notice_message_id = ch->maintenance_notice_message_id;
    notice_state_valid = ch->maintenance_notice_state_valid;
    notice_state_on = ch->maintenance_notice_state_on;
    pthread_mutex_unlock(&maintenance_notice_mutex);
    if (snap.on && snap.since_ms > 0 && now > snap.since_ms) age_sec = (now - snap.since_ms) / 1000LL;
    if (snap.on && snap.expires_ms > 0) {
        remain_sec = snap.expires_ms > now ? (snap.expires_ms - now + 999LL) / 1000LL : 0;
    }
    if (raw) {
        n = snprintf(body, sizeof(body),
                     "OK RESULT=%s MAINTENANCE=%s PORT=%d AGE_SEC=%lld TTL_REMAIN_SEC=%lld SUPPRESSED=%llu REASON=\"%s\" ENABLED_BY=%s PINNED_MESSAGE_ID=%lld PIN_STATE=%s\n",
                     result ? result : "STATUS", snap.on ? "ON" : "OFF", ch->port,
                     (long long)age_sec, (long long)remain_sec,
                     (unsigned long long)snap.suppressed_count,
                     snap.reason[0] ? snap.reason : "-",
                     snap.enabled_by[0] ? snap.enabled_by : "-",
                     (long long)notice_message_id,
                     notice_state_valid ? (notice_state_on ? "ON" : "OFF") : "UNKNOWN");
        if (n > 0) (void)send_all(fd, body, (size_t)n < sizeof(body) ? (size_t)n : sizeof(body) - 1U);
        return;
    }
    json_escape(snap.reason, reason_json, sizeof(reason_json));
    json_escape(snap.enabled_by, actor_json, sizeof(actor_json));
    json_escape(ch->label, label_json, sizeof(label_json));
    n = snprintf(body, sizeof(body),
                 "{\"ok\":true,\"result\":\"%s\",\"maintenance_suppress\":%s,\"port\":%d,\"label\":\"%s\","
                 "\"since_ms\":%lld,\"age_sec\":%lld,\"expires_ms\":%lld,\"ttl_remaining_sec\":%lld,"
                 "\"reason\":\"%s\",\"enabled_by\":\"%s\",\"suppressed_count\":%llu,"
                 "\"pinned_message_id\":%lld,\"pinned_state\":\"%s\","
                 "\"queued\":false,\"telegram_sent\":false}\n",
                 result ? result : "STATUS", snap.on ? "true" : "false", ch->port, label_json,
                 (long long)snap.since_ms, (long long)age_sec, (long long)snap.expires_ms,
                 (long long)remain_sec, reason_json, actor_json,
                 (unsigned long long)snap.suppressed_count,
                 (long long)notice_message_id,
                 notice_state_valid ? (notice_state_on ? "ON" : "OFF") : "UNKNOWN");
    if (n < 0) n = 0;
    if ((size_t)n >= sizeof(body)) n = (int)sizeof(body) - 1;
    (void)send_http_response(fd, 200, "application/json; charset=utf-8", body, (size_t)n);
}

static void maintenance_send_command_error(int fd, bool raw, long status,
                                           const char *msg)
{
    if (raw) {
        char body[256];
        int n = snprintf(body, sizeof(body), "ERROR status=%ld message=\"%s\"\n", status, msg ? msg : "invalid command");
        if (n > 0) (void)send_all(fd, body, (size_t)n < sizeof(body) ? (size_t)n : sizeof(body) - 1U);
    } else {
        send_json_error(fd, status, msg ? msg : "invalid command");
    }
}

static void maintenance_build_notice_event(struct maintenance_notice_event *ev,
                                           struct channel *ch,
                                           bool enabled,
                                           const struct maintenance_snapshot *details,
                                           const char *actor,
                                           const char *trigger)
{
    if (!ev || !ch) return;
    memset(ev, 0, sizeof(*ev));
    ev->ch = ch;
    ev->enabled = enabled;
    if (details) {
        ev->since_ms = details->since_ms;
        ev->expires_ms = details->expires_ms;
        ev->suppressed_count = details->suppressed_count;
        snprintf(ev->reason, sizeof(ev->reason), "%s", details->reason);
    }
    pthread_mutex_lock(&maintenance_mutex);
    ev->generation = ch->maintenance_generation;
    snprintf(ev->token, sizeof(ev->token), "%s", ch->token);
    snprintf(ev->chat_id, sizeof(ev->chat_id), "%s", ch->chat_id);
    snprintf(ev->label, sizeof(ev->label), "%s", ch->label);
    pthread_mutex_unlock(&maintenance_mutex);
    snprintf(ev->actor, sizeof(ev->actor), "%s", (actor && *actor) ? actor : "unknown");
    snprintf(ev->trigger, sizeof(ev->trigger), "%s", (trigger && *trigger) ? trigger : "magic");
}

static bool maintenance_handle_magic_command(struct ingest_ctx *ctx,
                                             struct http_request *req,
                                             bool raw)
{
    struct maintenance_command cmd;
    struct maintenance_snapshot snap;
    struct maintenance_snapshot before;
    struct maintenance_notice_event notice_ev;
    char escaped[MAGIC_TEST_TEXT_SIZE * 2U];
    char audit_id[JOB_ID_SIZE] = "logonly";
    int rc;

    maintenance_parse_command(req, &cmd);
    if (cmd.type == MAINT_CMD_NONE) return false;
    if (!maintenance_control_is_allowed(ctx->client_ip)) {
        log_msg(LOG_WARNING,
                "event=MAINTENANCE_CONTROL_DENIED version=%s client_ip=%s client_port=%u proxy_ip=%s proxy_port=%u proxy_protocol=%s listen_port=%d label=%s reason=source-not-allowed",
                PROGRAM_VERSION, ctx->client_ip, ctx->client_port,
                ctx->peer_ip[0] ? ctx->peer_ip : ctx->client_ip, ctx->peer_port,
                ctx->proxy_protocol_used ? "yes" : "no",
                ctx->ch->port, ctx->ch->label);
        maintenance_send_command_error(ctx->fd, raw, 403, "maintenance control source not allowed");
        return true;
    }
    if (cmd.type == MAINT_CMD_INVALID) {
        log_msg(LOG_WARNING,
                "event=MAGIC_COMMAND_REJECT version=%s client_ip=%s client_port=%u listen_port=%d label=%s error=\"%s\"",
                PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port,
                ctx->ch->label, cmd.error[0] ? cmd.error : "invalid");
        maintenance_send_command_error(ctx->fd, raw, 400, cmd.error[0] ? cmd.error : "invalid magic command");
        return true;
    }

    switch (cmd.type) {
    case MAINT_CMD_STATUS:
        maintenance_get_snapshot(ctx->ch, &snap);
        log_msg(LOG_NOTICE,
                "event=MAINTENANCE_STATUS version=%s client_ip=%s client_port=%u listen_port=%d label=%s state=%s expires_ms=%lld suppressed_count=%llu reason=\"%s\"",
                PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port,
                ctx->ch->label, snap.on ? "on" : "off", (long long)snap.expires_ms,
                (unsigned long long)snap.suppressed_count, snap.reason);
        maintenance_send_status_response(ctx->fd, ctx->ch, raw, "STATUS");
        return true;
    case MAINT_CMD_ON:
        rc = maintenance_enable(ctx->ch, cmd.ttl_sec, cmd.reason,
                                ctx->client_ip, ctx->client_port,
                                raw ? "raw-magic" : "http-magic");
        if (rc != 0) {
            maintenance_send_command_error(ctx->fd, raw, 500, "cannot persist maintenance state");
        } else {
            maintenance_get_snapshot(ctx->ch, &snap);
            maintenance_build_notice_event(&notice_ev, ctx->ch, true, &snap,
                                           ctx->client_ip, raw ? "raw-magic" : "http-magic");
            (void)maintenance_publish_notice(&notice_ev);
            maintenance_send_status_response(ctx->fd, ctx->ch, raw, "ON");
        }
        return true;
    case MAINT_CMD_OFF:
        maintenance_get_snapshot(ctx->ch, &before);
        rc = maintenance_disable(ctx->ch, ctx->client_ip, ctx->client_port,
                                 raw ? "raw-magic" : "http-magic");
        if (rc != 0) {
            maintenance_send_command_error(ctx->fd, raw, 500, "cannot persist maintenance state");
        } else {
            if (before.on) {
                maintenance_build_notice_event(&notice_ev, ctx->ch, false, &before,
                                               ctx->client_ip, raw ? "raw-magic" : "http-magic");
                (void)maintenance_publish_notice(&notice_ev);
            }
            maintenance_send_status_response(ctx->fd, ctx->ch, raw, "OFF");
        }
        return true;
    case MAINT_CMD_EXTEND:
        rc = maintenance_extend(ctx->ch, cmd.ttl_sec, ctx->client_ip, ctx->client_port,
                                raw ? "raw-magic" : "http-magic");
        if (rc == -2) maintenance_send_command_error(ctx->fd, raw, 409, "maintenance is OFF");
        else if (rc == -3) maintenance_send_command_error(ctx->fd, raw, 409, "maintenance is indefinite; EXTEND requires a finite TTL");
        else if (rc != 0) maintenance_send_command_error(ctx->fd, raw, 500, "cannot persist extended maintenance state");
        else maintenance_send_status_response(ctx->fd, ctx->ch, raw, "EXTEND");
        return true;
    case MAINT_CMD_MARK:
        audit_escape((const unsigned char *)cmd.reason, strlen(cmd.reason), escaped, sizeof(escaped));
        maintenance_get_snapshot(ctx->ch, &snap);
        metric_record(METRIC_MAINTENANCE_MARK);
        log_msg(LOG_NOTICE,
                "event=MAINTENANCE_MARK version=%s client_ip=%s client_port=%u listen_port=%d label=%s state=%s marker=\"%s\" queued=no telegram_sent=no",
                PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port,
                ctx->ch->label, snap.on ? "on" : "off", escaped);
        if (raw) {
            char ack[512]; int n = snprintf(ack, sizeof(ack), "OK MARK LOGGED PORT=%d STATE=%s\n", ctx->ch->port, snap.on ? "ON" : "OFF");
            if (n > 0) (void)send_all(ctx->fd, ack, (size_t)n);
        } else {
            const char ok[] = "{\"ok\":true,\"marker_logged\":true,\"queued\":false,\"telegram_sent\":false}\n";
            (void)send_http_response(ctx->fd, 200, "application/json; charset=utf-8", ok, sizeof(ok) - 1U);
        }
        return true;
    case MAINT_CMD_TEST_LOG_ONLY:
        audit_escape((const unsigned char *)cmd.payload, strlen(cmd.payload), escaped, sizeof(escaped));
        (void)maintenance_make_audit_id(audit_id);
        metric_record(METRIC_TEST_LOG_ONLY);
        log_msg(LOG_NOTICE,
                "event=TEST_LOG_ONLY version=%s audit_id=%s client_ip=%s client_port=%u listen_port=%d label=%s message=\"%s\" action=log_only queued=no telegram_sent=no",
                PROGRAM_VERSION, audit_id, ctx->client_ip, ctx->client_port,
                ctx->ch->port, ctx->ch->label, escaped);
        audit_log_text(audit_id, ctx->client_ip, ctx->ch, "/sendMessage",
                       "test_log_only", (const unsigned char *)cmd.payload, strlen(cmd.payload));
        audit_log_plain_send_message((const unsigned char *)cmd.payload, strlen(cmd.payload));
        if (raw) {
            char ack[256]; int n = snprintf(ack, sizeof(ack), "OK TEST_LOG_ONLY LOGGED PORT=%d\n", ctx->ch->port);
            if (n > 0) (void)send_all(ctx->fd, ack, (size_t)n);
        } else {
            const char ok[] = "{\"ok\":true,\"test_log_only\":true,\"logged\":true,\"queued\":false,\"telegram_sent\":false}\n";
            (void)send_http_response(ctx->fd, 200, "application/json; charset=utf-8", ok, sizeof(ok) - 1U);
        }
        return true;
    default:
        break;
    }
    return false;
}

static int spool_enqueue(const char *client_ip, unsigned client_port,
                         const struct channel *ch, const struct http_request *req,
                         char job_id[JOB_ID_SIZE])
{
    char rnd[33], tmp_path[SPOOL_PATH_SIZE], final_path[SPOOL_PATH_SIZE], basename[NAME_MAX + 1];
    char *b_token = NULL, *b_chat = NULL, *b_label = NULL, *b_ct = NULL, *b_caption = NULL, *b_pm = NULL, *b_fn = NULL;
    int fd = -1, hlen;
    int64_t now = realtime_ms();
    char header[8192];
    char body_sha256[65];
    int rc = -1;
    bool renamed = false;

    if (!spool_has_space(req->content_length)) { errno = ENOSPC; return -1; }
    if (sha256_hex(req->body ? req->body : (const unsigned char *)"",
                   req->content_length, body_sha256) != 0) return -1;
    if (random_hex(rnd) != 0) return -1;
    if (snprintf(job_id, JOB_ID_SIZE, "%lld-%ld-%s", (long long)now, (long)getpid(), rnd) >= JOB_ID_SIZE)
        return -1;
    if (snprintf(basename, sizeof(basename), "q-%013lld-a00-r000000-%s.job", (long long)now, job_id) >= (int)sizeof(basename))
        return -1;
    if (snprintf(tmp_path, sizeof(tmp_path), "%s/.tmp-%s", spool_tmp, job_id) >= (int)sizeof(tmp_path) ||
        snprintf(final_path, sizeof(final_path), "%s/%s", spool_pending, basename) >= (int)sizeof(final_path))
        return -1;

    b_token = base64_encode_alloc((const unsigned char *)ch->token, strlen(ch->token));
    b_chat = base64_encode_alloc((const unsigned char *)ch->chat_id, strlen(ch->chat_id));
    b_label = base64_encode_alloc((const unsigned char *)ch->label, strlen(ch->label));
    b_ct = base64_encode_alloc((const unsigned char *)req->content_type, strlen(req->content_type));
    b_caption = base64_encode_alloc((const unsigned char *)req->caption, strlen(req->caption));
    b_pm = base64_encode_alloc((const unsigned char *)req->parse_mode, strlen(req->parse_mode));
    b_fn = base64_encode_alloc((const unsigned char *)req->filename, strlen(req->filename));
    if (!b_token || !b_chat || !b_label || !b_ct || !b_caption || !b_pm || !b_fn) goto out;

    hlen = snprintf(header, sizeof(header),
                    "TGPSPOOL %d\njob_id=%s\ncreated_ms=%lld\nlisten_port=%d\n"
                    "client_ip=%s\nclient_port=%u\nendpoint=%s\n"
                    "token_b64=%s\nchat_id_b64=%s\nlabel_b64=%s\ncontent_type_b64=%s\n"
                    "caption_b64=%s\nparse_mode_b64=%s\nfilename_b64=%s\n"
                    "body_sha256=%s\nbody_len=%zu\n\n",
                    SPOOL_FORMAT_VERSION, job_id, (long long)now, ch->port,
                    client_ip, client_port, req->path,
                    b_token, b_chat, b_label, b_ct, b_caption, b_pm, b_fn,
                    body_sha256, req->content_length);
    if (hlen < 0 || (size_t)hlen >= sizeof(header)) goto out;

    fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) goto out;
    if (write_all_fd(fd, header, (size_t)hlen) != 0 ||
        (req->content_length && write_all_fd(fd, req->body, req->content_length) != 0) ||
        fsync(fd) != 0) goto out;
    if (close(fd) != 0) { fd = -1; goto out; }
    fd = -1;

    if (rename(tmp_path, final_path) != 0) goto out;
    renamed = true;

    /* Once rename succeeds the job is visible to workers.  A directory fsync
     * failure is therefore reported as "accepted, durability uncertain"
     * rather than a hard failure that could make the client submit a duplicate. */
    if (fsync_dir(spool_pending) != 0) {
        rc = 1;
        goto out;
    }
    rc = 0;
out:
    if (fd >= 0) close(fd);
    if (rc < 0 && !renamed) unlink(tmp_path);
    free(b_token); free(b_chat); free(b_label); free(b_ct); free(b_caption); free(b_pm); free(b_fn);
    return rc;
}

/* Idempotency result:
 *   0 = not found/new key
 *   1 = duplicate, same request hash (job_id returned)
 *   2 = key conflict, different request hash
 *  -1 = error
 */
static int idempotency_lookup_locked(const char *key, const char *request_sha,
                                     char job_id[JOB_ID_SIZE])
{
    char key_hash[65], path[SPOOL_PATH_SIZE];
    FILE *fp;
    char line[256], stored_job[JOB_ID_SIZE] = "", stored_sha[65] = "";
    int64_t created_ms = 0;
    int64_t now = realtime_ms();

    if (!key || !*key) return 0;
    if (sha256_hex((const unsigned char *)key, strlen(key), key_hash) != 0) return -1;
    if (snprintf(path, sizeof(path), "%s/%s.idem", spool_idempotency, key_hash) >= (int)sizeof(path)) {
        errno = ENAMETOOLONG; return -1;
    }
    fp = fopen(path, "r");
    if (!fp) {
        if (errno == ENOENT) return 0;
        return -1;
    }
    while (fgets(line, sizeof(line), fp)) {
        char *p = trim(line), *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = '\0';
        if (strcmp(p, "created_ms") == 0) (void)parse_i64_strict(eq + 1, &created_ms);
        else if (strcmp(p, "job_id") == 0) snprintf(stored_job, sizeof(stored_job), "%s", eq + 1);
        else if (strcmp(p, "request_sha256") == 0) snprintf(stored_sha, sizeof(stored_sha), "%s", eq + 1);
    }
    fclose(fp);
    if (created_ms <= 0 || !stored_job[0] || strlen(stored_sha) != 64U ||
        (now > created_ms && (now - created_ms) / 1000LL > IDEMPOTENCY_RETENTION_SEC)) {
        (void)unlink(path);
        (void)fsync_dir(spool_idempotency);
        return 0;
    }
    if (strcmp(stored_sha, request_sha) != 0) return 2;
    snprintf(job_id, JOB_ID_SIZE, "%s", stored_job);
    return 1;
}

static int idempotency_store_locked(const char *key, const char *request_sha,
                                    const char *job_id)
{
    char key_hash[65], tmp[SPOOL_PATH_SIZE], path[SPOOL_PATH_SIZE], body[512];
    int fd, n;
    if (sha256_hex((const unsigned char *)key, strlen(key), key_hash) != 0) return -1;
    if (snprintf(tmp, sizeof(tmp), "%s/.tmp-%s-%ld", spool_idempotency, key_hash, (long)getpid()) >= (int)sizeof(tmp) ||
        snprintf(path, sizeof(path), "%s/%s.idem", spool_idempotency, key_hash) >= (int)sizeof(path)) {
        errno = ENAMETOOLONG; return -1;
    }
    n = snprintf(body, sizeof(body), "created_ms=%lld\njob_id=%s\nrequest_sha256=%s\n",
                 (long long)realtime_ms(), job_id, request_sha);
    if (n < 0 || (size_t)n >= sizeof(body)) { errno = EINVAL; return -1; }
    fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (write_all_fd(fd, body, (size_t)n) != 0 || fsync(fd) != 0) {
        int e = errno; close(fd); unlink(tmp); errno = e; return -1;
    }
    if (close(fd) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    if (rename(tmp, path) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    return fsync_dir(spool_idempotency);
}

static int spool_enqueue_idempotent(const char *client_ip, unsigned client_port,
                                    const struct channel *ch,
                                    const struct http_request *req,
                                    char job_id[JOB_ID_SIZE], bool *duplicate)
{
    char request_sha[65];
    int lookup, rc;
    if (duplicate) *duplicate = false;
    if (!req->idempotency_key[0])
        return spool_enqueue(client_ip, client_port, ch, req, job_id);
    if (request_sha256_hex(req, ch, request_sha) != 0) return -1;

    pthread_mutex_lock(&idempotency_mutex);
    lookup = idempotency_lookup_locked(req->idempotency_key, request_sha, job_id);
    if (lookup == 1) {
        if (duplicate) *duplicate = true;
        pthread_mutex_unlock(&idempotency_mutex);
        return 0;
    }
    if (lookup == 2) {
        pthread_mutex_unlock(&idempotency_mutex);
        errno = EEXIST;
        return -2;
    }
    if (lookup < 0) {
        pthread_mutex_unlock(&idempotency_mutex);
        return -1;
    }

    rc = spool_enqueue(client_ip, client_port, ch, req, job_id);
    if (rc >= 0 && idempotency_store_locked(req->idempotency_key, request_sha, job_id) != 0) {
        log_msg(LOG_ERR,
                "event=IDEMPOTENCY_STORE_FAIL version=%s job_id=%s error=%s",
                PROGRAM_VERSION, job_id, strerror(errno));
        /* The job is already queued, so do not turn this into a client failure. */
    }
    pthread_mutex_unlock(&idempotency_mutex);
    return rc;
}

static int decode_meta(const char *src, char *dst, size_t dstsz)
{
    size_t outlen = 0;
    if (base64_decode_into(src, (unsigned char *)dst, dstsz - 1U, &outlen) != 0) return -1;
    if (outlen >= dstsz) return -1;
    dst[outlen] = '\0';
    return 0;
}

static int parse_i64_strict(const char *s, int64_t *out)
{
    char *end = NULL;
    long long v;
    errno = 0;
    v = strtoll(s, &end, 10);
    if (errno || end == s || *end != '\0') return -1;
    *out = (int64_t)v;
    return 0;
}

static int parse_uint_strict(const char *s, unsigned *out)
{
    char *end = NULL;
    unsigned long v;
    errno = 0;
    v = strtoul(s, &end, 10);
    if (errno || end == s || *end != '\0' || v > UINT_MAX) return -1;
    *out = (unsigned)v;
    return 0;
}

static int parse_size_strict(const char *s, size_t *out)
{
    char *end = NULL;
    unsigned long long v;
    errno = 0;
    v = strtoull(s, &end, 10);
    if (errno || end == s || *end != '\0' || v > MAX_REQUEST_BODY) return -1;
    *out = (size_t)v;
    return 0;
}

static int load_spool_job(const char *path, struct spool_job *job)
{
    FILE *fp = NULL;
    char *line = NULL;
    size_t cap = 0;
    ssize_t n;
    bool got_magic = false, got_body_len = false, got_body_sha = false;
    long body_pos;

    memset(job, 0, sizeof(*job));
    fp = fopen(path, "rb");
    if (!fp) return -1;
    while ((n = getline(&line, &cap, fp)) >= 0) {
        char *p, *eq;
        if (n == 1 && line[0] == '\n') break;
        if (n == 2 && line[0] == '\r' && line[1] == '\n') break;
        p = trim(line);
        if (!got_magic) {
            if (strcmp(p, "TGPSPOOL 1") == 0) job->spool_version = 1;
            else if (strcmp(p, "TGPSPOOL 2") == 0) job->spool_version = 2;
            else goto fail;
            got_magic = true;
            continue;
        }
        eq = strchr(p, '=');
        if (!eq) goto fail;
        *eq = '\0';
        if (strcmp(p, "job_id") == 0) snprintf(job->job_id, sizeof(job->job_id), "%s", eq + 1);
        else if (strcmp(p, "created_ms") == 0) { if (parse_i64_strict(eq + 1, &job->created_ms) != 0) goto fail; }
        else if (strcmp(p, "listen_port") == 0) { int port; if (parse_port(eq + 1, &port) != 0) goto fail; job->listen_port = port; }
        else if (strcmp(p, "client_ip") == 0) snprintf(job->client_ip, sizeof(job->client_ip), "%s", eq + 1);
        else if (strcmp(p, "client_port") == 0) { if (parse_uint_strict(eq + 1, &job->client_port) != 0 || job->client_port > 65535U) goto fail; }
        else if (strcmp(p, "endpoint") == 0) snprintf(job->endpoint, sizeof(job->endpoint), "%s", eq + 1);
        else if (strcmp(p, "token_b64") == 0) { if (decode_meta(eq + 1, job->token, sizeof(job->token)) != 0) goto fail; }
        else if (strcmp(p, "chat_id_b64") == 0) { if (decode_meta(eq + 1, job->chat_id, sizeof(job->chat_id)) != 0) goto fail; }
        else if (strcmp(p, "label_b64") == 0) { if (decode_meta(eq + 1, job->label, sizeof(job->label)) != 0) goto fail; }
        else if (strcmp(p, "content_type_b64") == 0) { if (decode_meta(eq + 1, job->content_type, sizeof(job->content_type)) != 0) goto fail; }
        else if (strcmp(p, "caption_b64") == 0) { if (decode_meta(eq + 1, job->caption, sizeof(job->caption)) != 0) goto fail; }
        else if (strcmp(p, "parse_mode_b64") == 0) { if (decode_meta(eq + 1, job->parse_mode, sizeof(job->parse_mode)) != 0) goto fail; }
        else if (strcmp(p, "filename_b64") == 0) { if (decode_meta(eq + 1, job->filename, sizeof(job->filename)) != 0) goto fail; }
        else if (strcmp(p, "body_sha256") == 0) {
            if (strlen(eq + 1) != 64U) goto fail;
            snprintf(job->body_sha256, sizeof(job->body_sha256), "%s", eq + 1);
            got_body_sha = true;
        }
        else if (strcmp(p, "body_len") == 0) {
            if (parse_size_strict(eq + 1, &job->body_len) != 0) goto fail;
            got_body_len = true;
        }
    }
    if (!got_magic || !got_body_len || !job->job_id[0] || !job->endpoint[0] || !job->token[0] || !job->chat_id[0]) goto fail;
    if (job->spool_version >= 2 && !got_body_sha) goto fail;
    body_pos = ftell(fp);
    if (body_pos < 0) goto fail;
    job->body = malloc(job->body_len + 1U);
    if (!job->body) goto fail;
    if (job->body_len && fread(job->body, 1, job->body_len, fp) != job->body_len) goto fail;
    job->body[job->body_len] = '\0';
    if (fgetc(fp) != EOF) { errno = EBADMSG; goto fail; }
    if (job->spool_version >= 2) {
        char actual_sha[65];
        if (sha256_hex(job->body, job->body_len, actual_sha) != 0 ||
            strcmp(actual_sha, job->body_sha256) != 0) {
            errno = EBADMSG;
            goto fail;
        }
    }
    free(line); fclose(fp); return 0;
fail:
    free(job->body); job->body = NULL;
    free(line); if (fp) fclose(fp); return -1;
}

static void free_spool_job(struct spool_job *job)
{
    free(job->body); job->body = NULL;
}

static int parse_pending_name(const char *name, struct pending_item *it)
{
    long long due;
    unsigned attempts, deferrals = 0U;
    char jobid[JOB_ID_SIZE];
    int consumed = 0;

    /* v3.10.2+: rate-limit deferrals are persisted in the queue filename.
     * Backward compatibility: v3.10.1 and older q-...-aNN-JOB.job names
     * are accepted with deferrals=0.
     */
    if (sscanf(name, "q-%lld-a%u-r%u-%95[^.]%n.job",
               &due, &attempts, &deferrals, jobid, &consumed) != 4) {
        consumed = 0;
        if (sscanf(name, "q-%lld-a%u-%95[^.]%n.job",
                   &due, &attempts, jobid, &consumed) != 3) return -1;
        deferrals = 0U;
    }
    if ((size_t)consumed + 4U != strlen(name)) return -1;
    it->due_ms = (int64_t)due;
    it->attempts_done = attempts;
    it->rate_limit_deferrals = deferrals;
    snprintf(it->job_id, sizeof(it->job_id), "%s", jobid);
    snprintf(it->basename, sizeof(it->basename), "%s", name);
    return 0;
}

static int scan_next_pending(struct pending_item *best, int64_t *wait_ms)
{
    DIR *d = opendir(spool_pending);
    struct dirent *de;
    bool have = false;
    int64_t now = realtime_ms();
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        struct pending_item cur;
        if (de->d_name[0] == '.') continue;
        if (parse_pending_name(de->d_name, &cur) != 0) continue;
        if (!have || cur.due_ms < best->due_ms ||
            (cur.due_ms == best->due_ms && strcmp(cur.basename, best->basename) < 0)) {
            *best = cur; have = true;
        }
    }
    closedir(d);
    if (!have) { *wait_ms = WORKER_IDLE_WAKE_SEC * 1000LL; return 1; }
    if (best->due_ms > now) { *wait_ms = best->due_ms - now; return 2; }
    *wait_ms = 0; return 0;
}

static int claim_job(const struct pending_item *it, char working_path[SPOOL_PATH_SIZE])
{
    char src[SPOOL_PATH_SIZE];
    if (snprintf(src, sizeof(src), "%s/%s", spool_pending, it->basename) >= (int)sizeof(src) ||
        snprintf(working_path, SPOOL_PATH_SIZE, "%s/%s", spool_working, it->basename) >= SPOOL_PATH_SIZE)
        return -1;
    if (rename(src, working_path) != 0) return -1;
    (void)fsync_dir(spool_pending); (void)fsync_dir(spool_working);
    return 0;
}

static int requeue_working(const char *working_path, const char *job_id,
                           unsigned attempts_done, unsigned rate_limit_deferrals,
                           int64_t due_ms)
{
    char dest[SPOOL_PATH_SIZE], name[NAME_MAX + 1];
    if (snprintf(name, sizeof(name), "q-%013lld-a%02u-r%06u-%s.job",
                 (long long)due_ms, attempts_done, rate_limit_deferrals,
                 job_id) >= (int)sizeof(name)) return -1;
    if (snprintf(dest, sizeof(dest), "%s/%s", spool_pending, name) >= (int)sizeof(dest)) return -1;
    if (rename(working_path, dest) != 0) return -1;
    (void)fsync_dir(spool_working); (void)fsync_dir(spool_pending);
    pthread_mutex_lock(&queue_mutex);
    pthread_cond_broadcast(&queue_cond);
    pthread_mutex_unlock(&queue_mutex);
    return 0;
}

static int write_failed_metadata(const char *failed_job_path,
                                 const char *reason,
                                 long telegram_http,
                                 int curl_code,
                                 const char *telegram_error,
                                 bool ambiguous,
                                 unsigned rate_limit_deferrals,
                                 int64_t job_created_ms)
{
    char meta_path[SPOOL_PATH_SIZE], tmp_path[SPOOL_PATH_SIZE];
    char *tg_b64 = NULL;
    char body[2048];
    int fd = -1, n, rc = -1;

    if (!failed_job_path) { errno = EINVAL; return -1; }
    if (snprintf(meta_path, sizeof(meta_path), "%s.meta", failed_job_path) >= (int)sizeof(meta_path) ||
        snprintf(tmp_path, sizeof(tmp_path), "%s.tmp-%ld", meta_path, (long)getpid()) >= (int)sizeof(tmp_path)) {
        errno = ENAMETOOLONG; return -1;
    }
    tg_b64 = base64_encode_alloc((const unsigned char *)(telegram_error ? telegram_error : ""),
                                  strlen(telegram_error ? telegram_error : ""));
    if (!tg_b64) return -1;
    n = snprintf(body, sizeof(body),
                 "failed_at_ms=%lld\nreason=%s\ntelegram_http=%ld\ncurl_code=%d\n"
                 "ambiguous=%s\nrate_limit_deferrals=%u\njob_age_sec=%lld\ntelegram_error_b64=%s\n",
                 (long long)realtime_ms(), reason ? reason : "unknown",
                 telegram_http, curl_code, ambiguous ? "yes" : "no",
                 rate_limit_deferrals,
                 (long long)age_seconds_from_ms(job_created_ms), tg_b64);
    if (n < 0 || (size_t)n >= sizeof(body)) { errno = EINVAL; goto out; }
    fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) goto out;
    if (write_all_fd(fd, body, (size_t)n) != 0 || fsync(fd) != 0) goto out;
    if (close(fd) != 0) { fd = -1; goto out; }
    fd = -1;
    if (rename(tmp_path, meta_path) != 0) goto out;
    if (fsync_dir(spool_failed) != 0) goto out;
    rc = 0;
out:
    if (fd >= 0) close(fd);
    if (rc != 0) unlink(tmp_path);
    free(tg_b64);
    return rc;
}

static int fail_working_with_metadata(const char *working_path,
                                      const char *job_id,
                                      unsigned attempts_done,
                                      unsigned rate_limit_deferrals,
                                      int64_t job_created_ms,
                                      const char *reason,
                                      long telegram_http,
                                      int curl_code,
                                      const char *telegram_error,
                                      bool ambiguous)
{
    char dest[SPOOL_PATH_SIZE];
    int64_t now = realtime_ms();
    if (snprintf(dest, sizeof(dest), "%s/f-%013lld-a%02u-r%06u-%s.job",
                 spool_failed, (long long)now, attempts_done,
                 rate_limit_deferrals, job_id) >= (int)sizeof(dest)) return -1;
    if (rename(working_path, dest) != 0) return -1;
    (void)fsync_dir(spool_working);
    (void)fsync_dir(spool_failed);
    if (write_failed_metadata(dest, reason, telegram_http, curl_code,
                              telegram_error, ambiguous, rate_limit_deferrals,
                              job_created_ms) != 0) {
        log_msg(LOG_ERR,
                "event=FAILED_META_WRITE_ERROR version=%s job_id=%s error=%s",
                PROGRAM_VERSION, job_id, strerror(errno));
    }
    return 0;
}

static int complete_working(const char *working_path)
{
    if (unlink(working_path) != 0) return -1;
    (void)fsync_dir(spool_working);
    return 0;
}

static int recover_working_jobs(void)
{
    DIR *d = opendir(spool_working);
    struct dirent *de;
    unsigned recovered = 0;
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        char src[SPOOL_PATH_SIZE], dst[SPOOL_PATH_SIZE];
        if (de->d_name[0] == '.') continue;
        if (strncmp(de->d_name, "q-", 2) != 0) continue;
        if (snprintf(src, sizeof(src), "%s/%s", spool_working, de->d_name) >= (int)sizeof(src) ||
            snprintf(dst, sizeof(dst), "%s/%s", spool_pending, de->d_name) >= (int)sizeof(dst)) continue;
        if (rename(src, dst) == 0) recovered++;
    }
    closedir(d);
    (void)fsync_dir(spool_working); (void)fsync_dir(spool_pending);
    if (recovered)
        log_msg(LOG_WARNING, "event=SPOOL_RECOVERY version=%s recovered=%u delivery_semantics=at_least_once",
                PROGRAM_VERSION, recovered);
    return 0;
}

static int64_t age_seconds_from_ms(int64_t when_ms)
{
    int64_t now = realtime_ms();
    if (when_ms <= 0 || now <= when_ms) return 0;
    return (now - when_ms) / 1000LL;
}

static int health_level(const struct queue_summary *q)
{
    int64_t oldest_pending_sec = age_seconds_from_ms(q->pending.oldest_mtime_ms);
    if (q->pending.count + q->working.count >= MAX_PENDING_JOBS ||
        q->failed.count >= MAX_FAILED_JOBS ||
        q->total_bytes >= MAX_SPOOL_BYTES ||
        q->free_bytes <= SPOOL_MIN_FREE_BYTES)
        return 2;
    if (q->failed.count > 0 || q->pending.count >= HEALTH_PENDING_DEGRADED ||
        oldest_pending_sec >= HEALTH_OLDEST_PENDING_SEC)
        return 1;
    return 0;
}

static int verify_existing_spool_dirs(void)
{
    const char *paths[] = {spool_root, spool_pending, spool_working, spool_failed,
                           spool_tmp, spool_rate};
    uid_t owner = (uid_t)-1;
    size_t i;
    for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        struct stat st;
        if (lstat(paths[i], &st) != 0) return -1;
        if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
        if ((st.st_mode & 0777) != 0700) { errno = EPERM; return -1; }
        if (i == 0) owner = st.st_uid;
        else if (st.st_uid != owner) { errno = EPERM; return -1; }
    }
    /* idempotency/ was introduced in v3.10.  Older v3.9 spools remain
     * readable by one-shot admin commands before the daemon creates it. */
    {
        struct stat st;
        if (lstat(spool_idempotency, &st) == 0) {
            if (S_ISLNK(st.st_mode) || !S_ISDIR(st.st_mode) ||
                (st.st_mode & 0777) != 0700 || st.st_uid != owner) {
                errno = EPERM;
                return -1;
            }
        } else if (errno != ENOENT) {
            return -1;
        }
    }
    return 0;
}

struct failed_item {
    char basename[NAME_MAX + 1];
    int64_t failed_ms;
    unsigned attempts_done;
    unsigned rate_limit_deferrals;
    char job_id[JOB_ID_SIZE];
};

static int parse_failed_name(const char *name, struct failed_item *it)
{
    long long failed;
    unsigned attempts, deferrals = 0U;
    char jobid[JOB_ID_SIZE];
    int consumed = 0;
    if (sscanf(name, "f-%lld-a%u-r%u-%95[^.]%n.job",
               &failed, &attempts, &deferrals, jobid, &consumed) != 4) {
        consumed = 0;
        if (sscanf(name, "f-%lld-a%u-%95[^.]%n.job",
                   &failed, &attempts, jobid, &consumed) != 3) return -1;
        deferrals = 0U;
    }
    if ((size_t)consumed + 4U != strlen(name)) return -1;
    it->failed_ms = (int64_t)failed;
    it->attempts_done = attempts;
    it->rate_limit_deferrals = deferrals;
    snprintf(it->job_id, sizeof(it->job_id), "%s", jobid);
    snprintf(it->basename, sizeof(it->basename), "%s", name);
    return 0;
}

static int find_failed_job(const char *job_id, struct failed_item *found, char path[SPOOL_PATH_SIZE])
{
    DIR *d = opendir(spool_failed);
    struct dirent *de;
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        struct failed_item it;
        if (de->d_name[0] == '.' || parse_failed_name(de->d_name, &it) != 0) continue;
        if (strcmp(it.job_id, job_id) == 0) {
            if (snprintf(path, SPOOL_PATH_SIZE, "%s/%s", spool_failed, de->d_name) >= SPOOL_PATH_SIZE) {
                closedir(d); errno = ENAMETOOLONG; return -1;
            }
            if (found) *found = it;
            closedir(d);
            return 0;
        }
    }
    closedir(d);
    errno = ENOENT;
    return -1;
}

static int admin_queue_status(void)
{
    struct queue_summary q;
    if (get_queue_summary(&q) != 0) return -1;
    printf("version=%s\n", PROGRAM_VERSION);
    printf("spool=%s\n", spool_root);
    printf("pending=%zu\nworking=%zu\nfailed=%zu\n", q.pending.count, q.working.count, q.failed.count);
    printf("pending_bytes=%llu\nworking_bytes=%llu\nfailed_bytes=%llu\nspool_bytes=%llu\nfree_bytes=%llu\n",
           q.pending.bytes, q.working.bytes, q.failed.bytes, q.total_bytes, q.free_bytes);
    printf("oldest_pending_sec=%lld\noldest_failed_sec=%lld\n",
           (long long)age_seconds_from_ms(q.pending.oldest_mtime_ms),
           (long long)age_seconds_from_ms(q.failed.oldest_mtime_ms));
    printf("max_pending_jobs=%u\nmax_failed_jobs=%u\nmax_spool_bytes=%llu\nmin_free_bytes=%llu\n",
           MAX_PENDING_JOBS, MAX_FAILED_JOBS,
           (unsigned long long)MAX_SPOOL_BYTES,
           (unsigned long long)SPOOL_MIN_FREE_BYTES);
    printf("status=%s\n", health_level(&q) == 2 ? "critical" : health_level(&q) == 1 ? "degraded" : "healthy");
    return 0;
}

static int admin_failed_list(void)
{
    DIR *d = opendir(spool_failed);
    struct dirent *de;
    if (!d) return -1;
    printf("JOB_ID\tATTEMPTS\t429_DEFERS\tAGE_SEC\tPORT\tENDPOINT\tBYTES\tLABEL\n");
    while ((de = readdir(d)) != NULL) {
        struct failed_item it;
        char path[SPOOL_PATH_SIZE];
        struct spool_job job;
        if (de->d_name[0] == '.' || parse_failed_name(de->d_name, &it) != 0) continue;
        if (snprintf(path, sizeof(path), "%s/%s", spool_failed, de->d_name) >= (int)sizeof(path)) continue;
        if (load_spool_job(path, &job) == 0) {
            printf("%s\t%u\t%u\t%lld\t%d\t%s\t%zu\t%s\n",
                   it.job_id, it.attempts_done, it.rate_limit_deferrals,
                   (long long)age_seconds_from_ms(it.failed_ms),
                   job.listen_port, job.endpoint, job.body_len, job.label);
            free_spool_job(&job);
        } else {
            printf("%s\t%u\t%u\t%lld\tCORRUPT\n", it.job_id, it.attempts_done,
                   it.rate_limit_deferrals, (long long)age_seconds_from_ms(it.failed_ms));
        }
    }
    closedir(d);
    return 0;
}

struct failed_metadata {
    int64_t failed_at_ms;
    char reason[128];
    long telegram_http;
    int curl_code;
    bool ambiguous;
    unsigned rate_limit_deferrals;
    int64_t job_age_sec;
    char telegram_error[512];
};

static int read_failed_metadata(const char *job_path, struct failed_metadata *m)
{
    char meta_path[SPOOL_PATH_SIZE], line[1024];
    FILE *fp;
    memset(m, 0, sizeof(*m));
    if (snprintf(meta_path, sizeof(meta_path), "%s.meta", job_path) >= (int)sizeof(meta_path)) return -1;
    fp = fopen(meta_path, "r");
    if (!fp) return -1;
    while (fgets(line, sizeof(line), fp)) {
        char *p = trim(line), *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = '\0';
        if (strcmp(p, "failed_at_ms") == 0) (void)parse_i64_strict(eq + 1, &m->failed_at_ms);
        else if (strcmp(p, "reason") == 0) snprintf(m->reason, sizeof(m->reason), "%s", eq + 1);
        else if (strcmp(p, "telegram_http") == 0) m->telegram_http = strtol(eq + 1, NULL, 10);
        else if (strcmp(p, "curl_code") == 0) m->curl_code = (int)strtol(eq + 1, NULL, 10);
        else if (strcmp(p, "ambiguous") == 0) m->ambiguous = strcmp(eq + 1, "yes") == 0;
        else if (strcmp(p, "rate_limit_deferrals") == 0) m->rate_limit_deferrals = (unsigned)strtoul(eq + 1, NULL, 10);
        else if (strcmp(p, "job_age_sec") == 0) (void)parse_i64_strict(eq + 1, &m->job_age_sec);
        else if (strcmp(p, "telegram_error_b64") == 0) {
            (void)decode_meta(eq + 1, m->telegram_error, sizeof(m->telegram_error));
        }
    }
    fclose(fp);
    return 0;
}

static int admin_failed_show(const char *job_id)
{
    struct failed_item it;
    char path[SPOOL_PATH_SIZE];
    struct spool_job job;
    struct failed_metadata meta;
    char sha[65] = "unavailable";
    if (find_failed_job(job_id, &it, path) != 0) return -1;
    if (load_spool_job(path, &job) != 0) { errno = EINVAL; return -1; }
    (void)sha256_hex(job.body, job.body_len, sha);
    printf("job_id=%s\nfailed_age_sec=%lld\njob_age_sec=%lld\nattempts=%u\nrate_limit_deferrals=%u\ncreated_ms=%lld\nlisten_port=%d\nclient_ip=%s\nclient_port=%u\n",
           job.job_id, (long long)age_seconds_from_ms(it.failed_ms),
           (long long)age_seconds_from_ms(job.created_ms), it.attempts_done,
           it.rate_limit_deferrals, (long long)job.created_ms,
           job.listen_port, job.client_ip, job.client_port);
    printf("endpoint=%s\nchat_id=%s\nlabel=%s\ncontent_type=%s\nfilename=%s\nbody_len=%zu\nsha256=%s\n",
           job.endpoint, job.chat_id, job.label, job.content_type, job.filename, job.body_len, sha);
    if (read_failed_metadata(path, &meta) == 0) {
        printf("failure_reason=%s\ntelegram_http=%ld\ncurl_code=%d\nambiguous=%s\n"
               "metadata_rate_limit_deferrals=%u\nmetadata_job_age_sec=%lld\ntelegram_error=%s\n",
               meta.reason[0] ? meta.reason : "unknown", meta.telegram_http,
               meta.curl_code, meta.ambiguous ? "yes" : "no",
               meta.rate_limit_deferrals, (long long)meta.job_age_sec,
               meta.telegram_error[0] ? meta.telegram_error : "none");
    }
    printf("bot_token=<redacted>\n");
    free_spool_job(&job);
    return 0;
}

static int retry_failed_item(const struct failed_item *it, const char *src)
{
    char dst[SPOOL_PATH_SIZE], name[NAME_MAX + 1];
    char meta[SPOOL_PATH_SIZE];
    int64_t now = realtime_ms();
    if (snprintf(name, sizeof(name), "q-%013lld-a00-r000000-%s.job", (long long)now, it->job_id) >= (int)sizeof(name)) {
        errno = ENAMETOOLONG; return -1;
    }
    if (snprintf(dst, sizeof(dst), "%s/%s", spool_pending, name) >= (int)sizeof(dst)) {
        errno = ENAMETOOLONG; return -1;
    }
    if (access(dst, F_OK) == 0) { errno = EEXIST; return -1; }
    if (rename(src, dst) != 0) return -1;
    if (snprintf(meta, sizeof(meta), "%s.meta", src) < (int)sizeof(meta)) (void)unlink(meta);
    (void)fsync_dir(spool_failed);
    (void)fsync_dir(spool_pending);
    return 0;
}

static int admin_failed_retry(const char *job_id)
{
    struct failed_item it;
    char src[SPOOL_PATH_SIZE];
    if (find_failed_job(job_id, &it, src) != 0) return -1;
    if (retry_failed_item(&it, src) != 0) return -1;
    printf("retried=%s attempts_reset=0\n", job_id);
    return 0;
}

static int admin_failed_retry_all(void)
{
    DIR *d = opendir(spool_failed);
    struct dirent *de;
    unsigned moved = 0, skipped = 0;
    if (!d) return -1;
    while ((de = readdir(d)) != NULL) {
        struct failed_item it;
        char src[SPOOL_PATH_SIZE];
        if (de->d_name[0] == '.' || parse_failed_name(de->d_name, &it) != 0) continue;
        if (snprintf(src, sizeof(src), "%s/%s", spool_failed, de->d_name) >= (int)sizeof(src)) { skipped++; continue; }
        if (retry_failed_item(&it, src) == 0) moved++; else skipped++;
    }
    closedir(d);
    printf("retried=%u skipped=%u\n", moved, skipped);
    return skipped ? 1 : 0;
}

static int admin_failed_delete(const char *job_id)
{
    struct failed_item it;
    char path[SPOOL_PATH_SIZE];
    char meta[SPOOL_PATH_SIZE];
    if (find_failed_job(job_id, &it, path) != 0) return -1;
    if (unlink(path) != 0) return -1;
    if (snprintf(meta, sizeof(meta), "%s.meta", path) < (int)sizeof(meta)) (void)unlink(meta);
    (void)fsync_dir(spool_failed);
    printf("deleted=%s\n", job_id);
    return 0;
}

static int persistent_rate_reserve_or_defer(const struct spool_job *job,
                                            unsigned attempt_no,
                                            int64_t *defer_until_ms)
{
    char hash[65], path[SPOOL_PATH_SIZE], buf[64];
    struct flock lk;
    int fd;
    ssize_t n;
    int64_t next = 0, now, newnext;

    *defer_until_ms = 0;
    if (sha256_hex((const unsigned char *)job->chat_id, strlen(job->chat_id), hash) != 0) return -1;
    if (snprintf(path, sizeof(path), "%s/%s.state", spool_rate, hash) >= (int)sizeof(path)) return -1;

    pthread_mutex_lock(&rate_mutex);
    fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) { pthread_mutex_unlock(&rate_mutex); return -1; }

    memset(&lk, 0, sizeof(lk));
    lk.l_type = F_WRLCK;
    lk.l_whence = SEEK_SET;
    if (fcntl(fd, F_SETLKW, &lk) != 0) {
        close(fd);
        pthread_mutex_unlock(&rate_mutex);
        return -1;
    }

    n = pread(fd, buf, sizeof(buf) - 1U, 0);
    if (n > 0) {
        char *end = NULL;
        long long v;
        buf[n] = '\0';
        errno = 0;
        v = strtoll(buf, &end, 10);
        while (end && *end && isspace((unsigned char)*end)) end++;
        if (errno || end == buf || (end && *end != '\0')) {
            lk.l_type = F_UNLCK; (void)fcntl(fd, F_SETLK, &lk);
            close(fd); pthread_mutex_unlock(&rate_mutex); errno = EINVAL; return -1;
        }
        next = (int64_t)v;
    }

    now = realtime_ms();
    if (next > now) {
        *defer_until_ms = next;
        lk.l_type = F_UNLCK; (void)fcntl(fd, F_SETLK, &lk);
        close(fd);
        pthread_mutex_unlock(&rate_mutex);
        metric_record(METRIC_RATE_DEFER);
        log_msg(LOG_INFO,
                "event=RATE_LIMIT_DEFER version=%s job_id=%s client_ip=%s listen_port=%d label=%s "
                "endpoint=%s attempt=%u max_per_minute=%ld defer_ms=%lld",
                PROGRAM_VERSION, job->job_id, job->client_ip, job->listen_port, job->label,
                job->endpoint, attempt_no, CHANNEL_MAX_PER_MINUTE, (long long)(next - now));
        return 1;
    }

    newnext = now + CHANNEL_SPACING_MS;
    snprintf(buf, sizeof(buf), "%lld\n", (long long)newnext);
    if (ftruncate(fd, 0) != 0 ||
        pwrite(fd, buf, strlen(buf), 0) != (ssize_t)strlen(buf) ||
        fsync(fd) != 0) {
        lk.l_type = F_UNLCK; (void)fcntl(fd, F_SETLK, &lk);
        close(fd); pthread_mutex_unlock(&rate_mutex); return -1;
    }

    lk.l_type = F_UNLCK; (void)fcntl(fd, F_SETLK, &lk);
    close(fd);
    pthread_mutex_unlock(&rate_mutex);
    return 0;
}

static int token_hash_hex(const char *token, char out[65])
{
    return sha256_hex((const unsigned char *)token, strlen(token), out);
}

static long adaptive_429_floor_ms(unsigned consecutive_429)
{
    if (consecutive_429 <= 1U) return RATE_LIMIT_ADAPTIVE_1_MS;
    if (consecutive_429 == 2U) return RATE_LIMIT_ADAPTIVE_2_MS;
    if (consecutive_429 == 3U) return RATE_LIMIT_ADAPTIVE_3_MS;
    if (consecutive_429 == 4U) return RATE_LIMIT_ADAPTIVE_4_MS;
    return RATE_LIMIT_ADAPTIVE_5_MS;
}

static int bot_rate_state_path_hash(const char *hash, char path[SPOOL_PATH_SIZE])
{
    if (!hash || strlen(hash) != 64U) { errno = EINVAL; return -1; }
    if (snprintf(path, SPOOL_PATH_SIZE, "%s/bot-%s.cooldown", spool_rate, hash) >= SPOOL_PATH_SIZE) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

static int bot_rate_state_read_locked_hash(const char *hash,
                                           struct bot_rate_state *st)
{
    char path[SPOOL_PATH_SIZE], buf[512];
    int fd;
    ssize_t n;

    if (!st) { errno = EINVAL; return -1; }
    memset(st, 0, sizeof(*st));
    if (bot_rate_state_path_hash(hash, path) != 0) return -1;

    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT) return 0;
        return -1;
    }
    n = read(fd, buf, sizeof(buf) - 1U);
    if (n < 0) { int e = errno; close(fd); errno = e; return -1; }
    close(fd);
    if (n == 0) return 0;
    buf[n] = '\0';

    /* Backward compatibility with v3.10-v3.10.2, where this file contained
     * only one integer cooldown timestamp. Such a file was created by a 429,
     * so require one serialized recovery probe after the timestamp expires.
     */
    if (isdigit((unsigned char)buf[0]) || buf[0] == '-') {
        int64_t v = 0;
        char *pbuf = trim(buf);
        if (parse_i64_strict(pbuf, &v) != 0) return -1;
        st->cooldown_until_ms = v;
        st->consecutive_429 = 0;
        st->recovery_required = (v != 0);
        return 0;
    }

    {
        char *save = NULL, *line = strtok_r(buf, "\n", &save);
        bool saw_version = false;
        while (line) {
            char *p = trim(line), *eq = strchr(p, '=');
            if (eq) {
                int64_t v = 0;
                *eq = '\0';
                if (strcmp(p, "version") == 0) {
                    if (strcmp(eq + 1, "2") != 0) { errno = EINVAL; return -1; }
                    saw_version = true;
                } else if (strcmp(p, "cooldown_until_ms") == 0) {
                    if (parse_i64_strict(eq + 1, &v) != 0) return -1;
                    st->cooldown_until_ms = v;
                } else if (strcmp(p, "consecutive_429") == 0) {
                    char *endp = NULL;
                    unsigned long uv;
                    errno = 0;
                    uv = strtoul(eq + 1, &endp, 10);
                    if (errno || endp == eq + 1 || *endp != '\0' || uv > UINT_MAX) {
                        errno = EINVAL; return -1;
                    }
                    st->consecutive_429 = (unsigned)uv;
                } else if (strcmp(p, "recovery_required") == 0) {
                    if (strcmp(eq + 1, "1") == 0) st->recovery_required = true;
                    else if (strcmp(eq + 1, "0") == 0) st->recovery_required = false;
                    else { errno = EINVAL; return -1; }
                }
            }
            line = strtok_r(NULL, "\n", &save);
        }
        if (!saw_version) { errno = EINVAL; return -1; }
    }
    return 0;
}

static int bot_rate_state_write_locked_hash(const char *hash,
                                            const struct bot_rate_state *st)
{
    char path[SPOOL_PATH_SIZE], tmp[SPOOL_PATH_SIZE], body[256];
    int fd, n;

    if (!st) { errno = EINVAL; return -1; }
    if (bot_rate_state_path_hash(hash, path) != 0) return -1;
    if (snprintf(tmp, sizeof(tmp), "%s/.tmp-bot-%s-%ld", spool_rate, hash, (long)getpid()) >= (int)sizeof(tmp)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    n = snprintf(body, sizeof(body),
                 "version=2\ncooldown_until_ms=%lld\nconsecutive_429=%u\nrecovery_required=%u\n",
                 (long long)st->cooldown_until_ms, st->consecutive_429,
                 st->recovery_required ? 1U : 0U);
    if (n < 0 || (size_t)n >= sizeof(body)) { errno = EINVAL; return -1; }

    fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (write_all_fd(fd, body, (size_t)n) != 0 || fsync(fd) != 0) {
        int e = errno; close(fd); unlink(tmp); errno = e; return -1;
    }
    if (close(fd) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    if (rename(tmp, path) != 0) { int e = errno; unlink(tmp); errno = e; return -1; }
    return fsync_dir(spool_rate);
}

static struct token_rate_probe_state *bot_rate_probe_locked_hash(const char *hash)
{
    size_t i;
    for (i = 0; i < token_rate_probe_count; i++)
        if (strcmp(token_rate_probes[i].token_hash, hash) == 0)
            return &token_rate_probes[i];
    if (token_rate_probe_count >= MAX_TOKEN_STATES) return NULL;
    snprintf(token_rate_probes[token_rate_probe_count].token_hash,
             sizeof(token_rate_probes[token_rate_probe_count].token_hash), "%s", hash);
    token_rate_probes[token_rate_probe_count].probe_inflight = false;
    return &token_rate_probes[token_rate_probe_count++];
}

static int persistent_bot_rate_peek(const struct spool_job *job,
                                    int64_t *defer_until_ms)
{
    char hash[65];
    struct bot_rate_state st;
    int64_t now = realtime_ms();
    int rc = 0;

    if (!defer_until_ms) { errno = EINVAL; return -1; }
    *defer_until_ms = 0;
    if (token_hash_hex(job->token, hash) != 0) return -1;
    pthread_mutex_lock(&rate_mutex);
    if (bot_rate_state_read_locked_hash(hash, &st) != 0) {
        int e = errno; pthread_mutex_unlock(&rate_mutex); errno = e; return -1;
    }
    if (st.cooldown_until_ms > now) {
        *defer_until_ms = st.cooldown_until_ms;
        rc = 1;
    }
    pthread_mutex_unlock(&rate_mutex);
    return rc;
}

/* Final gate immediately before the upstream request. Return values:
 * 0 = normal send allowed
 * 1 = defer (another recovery probe is active or cooldown reappeared)
 * 2 = this worker acquired the single BOT_TOKEN recovery probe
 * -1 = state error
 */
static int persistent_bot_rate_acquire_send(const struct spool_job *job,
                                            int64_t *defer_until_ms,
                                            unsigned *streak_out)
{
    char hash[65];
    struct bot_rate_state st;
    struct token_rate_probe_state *ps;
    int64_t now = realtime_ms();
    int rc = 0;

    if (!defer_until_ms) { errno = EINVAL; return -1; }
    *defer_until_ms = 0;
    if (streak_out) *streak_out = 0;
    if (token_hash_hex(job->token, hash) != 0) return -1;

    pthread_mutex_lock(&rate_mutex);
    if (bot_rate_state_read_locked_hash(hash, &st) != 0) {
        int e = errno; pthread_mutex_unlock(&rate_mutex); errno = e; return -1;
    }
    if (streak_out) *streak_out = st.consecutive_429;
    if (st.cooldown_until_ms > now) {
        *defer_until_ms = st.cooldown_until_ms;
        rc = 1;
    } else if (st.recovery_required) {
        ps = bot_rate_probe_locked_hash(hash);
        if (!ps) {
            pthread_mutex_unlock(&rate_mutex);
            errno = ENOSPC;
            return -1;
        }
        if (ps->probe_inflight) {
            *defer_until_ms = now + 1000LL;
            rc = 1;
        } else {
            ps->probe_inflight = true;
            rc = 2;
        }
    }
    pthread_mutex_unlock(&rate_mutex);
    return rc;
}

static void persistent_bot_rate_release_probe(const struct spool_job *job)
{
    char hash[65];
    struct token_rate_probe_state *ps;
    if (token_hash_hex(job->token, hash) != 0) return;
    pthread_mutex_lock(&rate_mutex);
    ps = bot_rate_probe_locked_hash(hash);
    if (ps) ps->probe_inflight = false;
    pthread_mutex_unlock(&rate_mutex);
}

static int persistent_bot_rate_record_429(const struct spool_job *job,
                                          long telegram_floor_ms,
                                          unsigned *streak_out,
                                          long *delay_out,
                                          int64_t *due_out,
                                          bool *entered_recovery)
{
    char hash[65];
    struct bot_rate_state st;
    struct token_rate_probe_state *ps;
    int64_t now = realtime_ms();
    long adaptive, actual;
    bool entered;

    if (token_hash_hex(job->token, hash) != 0) return -1;
    pthread_mutex_lock(&rate_mutex);
    if (bot_rate_state_read_locked_hash(hash, &st) != 0) {
        int e = errno; pthread_mutex_unlock(&rate_mutex); errno = e; return -1;
    }
    entered = !st.recovery_required;
    if (st.consecutive_429 < UINT_MAX) st.consecutive_429++;
    st.recovery_required = true;
    adaptive = adaptive_429_floor_ms(st.consecutive_429);
    actual = telegram_floor_ms > adaptive ? telegram_floor_ms : adaptive;
    if (actual < RATE_LIMIT_ADAPTIVE_1_MS) actual = RATE_LIMIT_ADAPTIVE_1_MS;
    if (now > INT64_MAX - actual) st.cooldown_until_ms = INT64_MAX;
    else st.cooldown_until_ms = now + actual;

    if (bot_rate_state_write_locked_hash(hash, &st) != 0) {
        int e = errno;
        ps = bot_rate_probe_locked_hash(hash);
        if (ps) ps->probe_inflight = false;
        pthread_mutex_unlock(&rate_mutex);
        errno = e;
        return -1;
    }
    ps = bot_rate_probe_locked_hash(hash);
    if (ps) ps->probe_inflight = false;
    pthread_mutex_unlock(&rate_mutex);

    if (streak_out) *streak_out = st.consecutive_429;
    if (delay_out) *delay_out = actual;
    if (due_out) *due_out = st.cooldown_until_ms;
    if (entered_recovery) *entered_recovery = entered;
    return 0;
}

static int persistent_bot_rate_record_success(const struct spool_job *job,
                                              bool *cleared_recovery,
                                              unsigned *previous_streak)
{
    char hash[65], path[SPOOL_PATH_SIZE];
    struct bot_rate_state st;
    struct token_rate_probe_state *ps;
    bool cleared = false;

    if (cleared_recovery) *cleared_recovery = false;
    if (previous_streak) *previous_streak = 0;
    if (token_hash_hex(job->token, hash) != 0) return -1;

    pthread_mutex_lock(&rate_mutex);
    if (bot_rate_state_read_locked_hash(hash, &st) != 0) {
        int e = errno; pthread_mutex_unlock(&rate_mutex); errno = e; return -1;
    }
    if (previous_streak) *previous_streak = st.consecutive_429;
    cleared = st.recovery_required || st.consecutive_429 != 0U || st.cooldown_until_ms != 0;
    if (bot_rate_state_path_hash(hash, path) != 0) {
        int e = errno; pthread_mutex_unlock(&rate_mutex); errno = e; return -1;
    }
    if (cleared) {
        if (unlink(path) != 0 && errno != ENOENT) {
            int e = errno; pthread_mutex_unlock(&rate_mutex); errno = e; return -1;
        }
        (void)fsync_dir(spool_rate);
    }
    ps = bot_rate_probe_locked_hash(hash);
    if (ps) ps->probe_inflight = false;
    pthread_mutex_unlock(&rate_mutex);
    if (cleared_recovery) *cleared_recovery = cleared;
    return 0;
}

static struct token_circuit_state *circuit_state_locked(const char *token)
{
    char hash[65];
    size_t i;
    if (token_hash_hex(token, hash) != 0) return NULL;
    for (i = 0; i < token_state_count; i++)
        if (strcmp(token_states[i].token_hash, hash) == 0) return &token_states[i];
    if (token_state_count >= MAX_TOKEN_STATES) return NULL;
    snprintf(token_states[token_state_count].token_hash,
             sizeof(token_states[token_state_count].token_hash), "%s", hash);
    token_states[token_state_count].consecutive_failures = 0;
    token_states[token_state_count].open_until_ms = 0;
    token_states[token_state_count].half_open = false;
    token_states[token_state_count].probe_inflight = false;
    return &token_states[token_state_count++];
}

static int circuit_defer_until(const struct spool_job *job, int64_t *until_ms)
{
    struct token_circuit_state *st;
    int64_t now = realtime_ms();
    int rc = 0;
    *until_ms = 0;
    pthread_mutex_lock(&circuit_mutex);
    st = circuit_state_locked(job->token);
    if (!st) { pthread_mutex_unlock(&circuit_mutex); return -1; }
    if (st->open_until_ms > now) {
        *until_ms = st->open_until_ms;
        rc = 1;
    } else if (st->open_until_ms != 0) {
        /* The open interval expired. Enter half-open and permit one probe. */
        st->open_until_ms = 0;
        st->half_open = true;
        st->probe_inflight = false;
    }
    if (rc == 0 && st->half_open) {
        if (st->probe_inflight) {
            *until_ms = now + 1000LL;
            rc = 1;
        } else {
            st->probe_inflight = true;
        }
    }
    pthread_mutex_unlock(&circuit_mutex);
    return rc;
}

static void circuit_record_success(const struct spool_job *job)
{
    struct token_circuit_state *st;
    pthread_mutex_lock(&circuit_mutex);
    st = circuit_state_locked(job->token);
    if (st) {
        st->consecutive_failures = 0;
        st->open_until_ms = 0;
        st->half_open = false;
        st->probe_inflight = false;
    }
    pthread_mutex_unlock(&circuit_mutex);
}

static void circuit_record_failure(const struct spool_job *job,
                                   bool upstream_availability_failure)
{
    struct token_circuit_state *st;
    int64_t now = realtime_ms();
    pthread_mutex_lock(&circuit_mutex);
    st = circuit_state_locked(job->token);
    if (st) {
        if (!upstream_availability_failure) {
            st->consecutive_failures = 0;
            st->open_until_ms = 0;
            st->half_open = false;
            st->probe_inflight = false;
        } else {
            bool reopen_now = st->half_open;
            st->half_open = false;
            st->probe_inflight = false;
            st->consecutive_failures++;
            if (reopen_now || st->consecutive_failures >= CIRCUIT_FAILURE_THRESHOLD) {
                st->open_until_ms = now + CIRCUIT_OPEN_MS;
                log_msg(LOG_WARNING,
                        "event=CIRCUIT_OPEN version=%s job_id=%s listen_port=%d label=%s failures=%u open_ms=%lld",
                        PROGRAM_VERSION, job->job_id, job->listen_port, job->label,
                        st->consecutive_failures, (long long)CIRCUIT_OPEN_MS);
                st->consecutive_failures = 0;
            }
        }
    }
    pthread_mutex_unlock(&circuit_mutex);
}

static void mem_buf_reset(struct mem_buf *m)
{
    if (m->data && m->cap) m->data[0] = '\0';
    m->len = 0; m->overflow = false;
}

static size_t curl_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    struct mem_buf *m = userdata;
    size_t n;
    if (size && nmemb > SIZE_MAX / size) return 0;
    n = size * nmemb;
    if (m->overflow || m->len + n > MAX_RESPONSE_BODY) { m->overflow = true; return 0; }
    if (m->len + n + 1 > m->cap) {
        size_t nc = m->cap ? m->cap : 4096;
        char *tmp;
        while (nc < m->len + n + 1) nc *= 2;
        if (nc > MAX_RESPONSE_BODY + 1U) nc = MAX_RESPONSE_BODY + 1U;
        tmp = realloc(m->data, nc); if (!tmp) return 0;
        m->data = tmp; m->cap = nc;
    }
    memcpy(m->data + m->len, ptr, n); m->len += n; m->data[m->len] = '\0';
    return n;
}

static size_t curl_header_cb(char *buffer, size_t size, size_t nitems, void *userdata)
{
    struct retry_header_state *st = userdata;
    size_t n = size * nitems;
    const char *prefix = "Retry-After:";
    if (n > strlen(prefix) && strncasecmp(buffer, prefix, strlen(prefix)) == 0) {
        const char *p = buffer + strlen(prefix);
        while (p < buffer + n && isspace((unsigned char)*p)) p++;
        if (isdigit((unsigned char)*p)) st->retry_after_sec = strtol(p, NULL, 10);
    }
    return n;
}

static void parse_json_description(const char *json, char *out, size_t outsz)
{
    const char *p;
    size_t o = 0;

    if (!out || outsz == 0) return;
    out[0] = '\0';
    if (!json) return;
    p = strstr(json, "\"description\"");
    if (!p) return;
    p = strchr(p + strlen("\"description\""), ':');
    if (!p) return;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (*p != '"') return;
    p++;

    while (*p && *p != '"' && o + 1U < outsz) {
        unsigned char c = (unsigned char)*p++;
        if (c != '\\') {
            out[o++] = (char)c;
            continue;
        }
        if (!*p) break;
        c = (unsigned char)*p++;
        switch (c) {
            case '"': out[o++] = '"'; break;
            case '\\': out[o++] = '\\'; break;
            case '/': out[o++] = '/'; break;
            case 'b': out[o++] = '\b'; break;
            case 'f': out[o++] = '\f'; break;
            case 'n': out[o++] = '\n'; break;
            case 'r': out[o++] = '\r'; break;
            case 't': out[o++] = '\t'; break;
            case 'u':
                /* Telegram descriptions are normally ASCII. Keep \uXXXX
                 * escaped for diagnostics rather than implementing a full
                 * surrogate-pair decoder here. */
                if (strlen(p) >= 4U && o + 6U < outsz) {
                    size_t j;
                    out[o++] = '\\';
                    out[o++] = 'u';
                    for (j = 0; j < 4U; j++) out[o++] = *p++;
                } else {
                    out[o] = '\0';
                    return;
                }
                break;
            default:
                if (o + 2U < outsz) {
                    out[o++] = '\\';
                    out[o++] = (char)c;
                }
                break;
        }
    }
    out[o] = '\0';
}

static long parse_json_retry_after(const char *json)
{
    const char *p;
    if (!json) return -1;
    p = strstr(json, "\"retry_after\"");
    if (!p) return -1;
    p = strchr(p, ':'); if (!p) return -1; p++;
    while (*p && isspace((unsigned char)*p)) p++;
    if (!isdigit((unsigned char)*p)) return -1;
    return strtol(p, NULL, 10);
}


static int64_t parse_json_message_id(const char *json)
{
    const char *p;
    char *end = NULL;
    long long v;
    if (!json) return 0;
    p = strstr(json, "\"message_id\"");
    if (!p) return 0;
    p = strchr(p, ':');
    if (!p) return 0;
    p++;
    while (*p && isspace((unsigned char)*p)) p++;
    errno = 0;
    v = strtoll(p, &end, 10);
    if (errno || end == p || v <= 0) return 0;
    return (int64_t)v;
}

static bool curl_pre_request_retryable(CURLcode rc)
{
    return rc == CURLE_COULDNT_RESOLVE_PROXY || rc == CURLE_COULDNT_RESOLVE_HOST ||
           rc == CURLE_COULDNT_CONNECT ||
           rc == CURLE_SSL_CONNECT_ERROR || rc == CURLE_SSL_ENGINE_INITFAILED;
}

static bool curl_ambiguous(CURLcode rc)
{
    return rc == CURLE_OPERATION_TIMEDOUT || rc == CURLE_SEND_ERROR ||
           rc == CURLE_RECV_ERROR || rc == CURLE_GOT_NOTHING;
}

static bool http_retryable(long code)
{
    return code == 500 || code == 502 || code == 503 || code == 504;
}

static long exponential_backoff_ms(unsigned attempt_no)
{
    long v = UPSTREAM_BACKOFF_BASE_MS;
    unsigned i;
    for (i = 1; i < attempt_no; i++) {
        if (v >= UPSTREAM_BACKOFF_MAX_MS / 2) { v = UPSTREAM_BACKOFF_MAX_MS; break; }
        v *= 2;
    }
    if (v > UPSTREAM_BACKOFF_MAX_MS) v = UPSTREAM_BACKOFF_MAX_MS;
    return v;
}

static long jitter_ms(long base_ms)
{
    uint32_t rnd = 0;
    long span, offset;
    if (base_ms <= 1 || RETRY_JITTER_PERCENT <= 0) return base_ms;
    if (getrandom(&rnd, sizeof(rnd), 0) != (ssize_t)sizeof(rnd)) return base_ms;
    span = (base_ms * RETRY_JITTER_PERCENT) / 100L;
    if (span <= 0) return base_ms;
    offset = (long)(rnd % (uint32_t)(span * 2L + 1L)) - span;
    if (base_ms + offset < 1L) return 1L;
    return base_ms + offset;
}

static void set_common_curl_options(CURL *curl, struct mem_buf *resp,
                                    struct retry_header_state *hdr,
                                    char errorbuf[CURL_ERROR_SIZE])
{
    errorbuf[0] = '\0'; hdr->retry_after_sec = -1;
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, UPSTREAM_CONNECT_SEC);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, UPSTREAM_TOTAL_SEC);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_TCP_KEEPALIVE, 1L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
#if LIBCURL_VERSION_NUM >= 0x075500
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "https");
#else
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, CURLPROTO_HTTPS);
#endif
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "tg_https_proxy-relay/" PROGRAM_VERSION);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, resp);
    curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, curl_header_cb);
    curl_easy_setopt(curl, CURLOPT_HEADERDATA, hdr);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, errorbuf);
}

static int maintenance_telegram_send_message(const struct maintenance_notice_event *ev,
                                             int64_t *message_id,
                                             long *http_code,
                                             char *description, size_t description_size)
{
    CURL *curl = NULL;
    struct mem_buf resp = {0};
    struct retry_header_state hdr;
    char errorbuf[CURL_ERROR_SIZE], url[512], text[MAINT_NOTICE_TEXT_SIZE];
    char *e_chat = NULL, *e_text = NULL, *post = NULL;
    size_t postlen;
    CURLcode rc;
    long http = 0;
    int n;
    int64_t remain_sec = -1;

    if (!ev || !message_id) { errno = EINVAL; return -1; }
    *message_id = 0;
    if (http_code) *http_code = 0;
    if (description && description_size) description[0] = '\0';
    if (ev->enabled && ev->expires_ms > 0) {
        int64_t now = realtime_ms();
        remain_sec = ev->expires_ms > now ? (ev->expires_ms - now + 999LL) / 1000LL : 0;
    }
    if (ev->enabled && remain_sec >= 0) {
        n = snprintf(text, sizeof(text),
                     "MAINTENANCE ALERT SUPPRESSION ENABLED\n"
                     "Channel: %s\nPort: %d\nReason: %s\nOperator: %s\n"
                     "TTL remaining: %lld seconds\n"
                     "Alerts during maintenance are logged only and are not queued or replayed.",
                     ev->label, ev->ch ? ev->ch->port : 0,
                     ev->reason[0] ? ev->reason : "-", ev->actor,
                     (long long)remain_sec);
    } else if (ev->enabled) {
        n = snprintf(text, sizeof(text),
                     "MAINTENANCE ALERT SUPPRESSION ENABLED\n"
                     "Channel: %s\nPort: %d\nReason: %s\nOperator: %s\n"
                     "TTL remaining: until manual OFF\n"
                     "Alerts during maintenance are logged only and are not queued or replayed.",
                     ev->label, ev->ch ? ev->ch->port : 0,
                     ev->reason[0] ? ev->reason : "-", ev->actor);
    } else {
        n = snprintf(text, sizeof(text),
                     "MAINTENANCE ALERT SUPPRESSION DISABLED\n"
                     "Channel: %s\nPort: %d\nReason: %s\nOperator: %s\n"
                     "Suppressed messages: %llu\n"
                     "Normal Telegram alert delivery is now enabled.",
                     ev->label, ev->ch ? ev->ch->port : 0,
                     ev->reason[0] ? ev->reason : "-", ev->actor,
                     (unsigned long long)ev->suppressed_count);
    }
    if (n < 0 || (size_t)n >= sizeof(text)) { errno = EOVERFLOW; return -1; }
    if (snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendMessage", ev->token) >= (int)sizeof(url)) {
        errno = ENAMETOOLONG; return -1;
    }
    curl = curl_easy_init();
    if (!curl) { errno = ENOMEM; return -1; }
    e_chat = curl_easy_escape(curl, ev->chat_id, 0);
    e_text = curl_easy_escape(curl, text, (int)strlen(text));
    if (!e_chat || !e_text) { errno = ENOMEM; goto fail; }
    postlen = strlen(e_chat) + strlen(e_text) + 32U;
    post = malloc(postlen);
    if (!post) { errno = ENOMEM; goto fail; }
    snprintf(post, postlen, "chat_id=%s&text=%s", e_chat, e_text);
    set_common_curl_options(curl, &resp, &hdr, errorbuf);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, MAINT_NOTICE_CONNECT_SEC);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, MAINT_NOTICE_TOTAL_SEC);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, post);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(post));
    rc = curl_easy_perform(curl);
    if (rc == CURLE_OK) (void)curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http);
    if (http_code) *http_code = http;
    if (description && description_size) {
        if (rc == CURLE_OK) parse_json_description(resp.data, description, description_size);
        else snprintf(description, description_size, "%s", errorbuf[0] ? errorbuf : curl_easy_strerror(rc));
    }
    if (rc != CURLE_OK || http < 200 || http >= 300) goto fail;
    *message_id = parse_json_message_id(resp.data);
    if (*message_id <= 0) {
        if (description && description_size && !description[0])
            snprintf(description, description_size, "%s", "Telegram response missing message_id");
        goto fail;
    }
    curl_free(e_chat); curl_free(e_text); free(post); free(resp.data); curl_easy_cleanup(curl);
    return 0;
fail:
    curl_free(e_chat); curl_free(e_text); free(post); free(resp.data); curl_easy_cleanup(curl);
    return -1;
}

static int maintenance_telegram_pin_action(const struct maintenance_notice_event *ev,
                                           int64_t message_id, bool pin,
                                           long *http_code,
                                           char *description, size_t description_size)
{
    CURL *curl = NULL;
    struct mem_buf resp = {0};
    struct retry_header_state hdr;
    char errorbuf[CURL_ERROR_SIZE], url[512], mid[64];
    char *e_chat = NULL, *post = NULL;
    size_t postlen;
    CURLcode rc;
    long http = 0;
    const char *method = pin ? "pinChatMessage" : "unpinChatMessage";

    if (!ev || message_id <= 0) { errno = EINVAL; return -1; }
    if (http_code) *http_code = 0;
    if (description && description_size) description[0] = '\0';
    if (snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/%s", ev->token, method) >= (int)sizeof(url)) {
        errno = ENAMETOOLONG; return -1;
    }
    snprintf(mid, sizeof(mid), "%lld", (long long)message_id);
    curl = curl_easy_init();
    if (!curl) { errno = ENOMEM; return -1; }
    e_chat = curl_easy_escape(curl, ev->chat_id, 0);
    if (!e_chat) { errno = ENOMEM; goto fail; }
    postlen = strlen(e_chat) + strlen(mid) + 80U;
    post = malloc(postlen);
    if (!post) { errno = ENOMEM; goto fail; }
    snprintf(post, postlen, "chat_id=%s&message_id=%s%s", e_chat, mid,
             pin ? "&disable_notification=false" : "");
    set_common_curl_options(curl, &resp, &hdr, errorbuf);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, MAINT_NOTICE_CONNECT_SEC);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, MAINT_NOTICE_TOTAL_SEC);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, post);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(post));
    rc = curl_easy_perform(curl);
    if (rc == CURLE_OK) (void)curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http);
    if (http_code) *http_code = http;
    if (description && description_size) {
        if (rc == CURLE_OK) parse_json_description(resp.data, description, description_size);
        else snprintf(description, description_size, "%s", errorbuf[0] ? errorbuf : curl_easy_strerror(rc));
    }
    if (rc != CURLE_OK || http < 200 || http >= 300) goto fail;
    curl_free(e_chat); free(post); free(resp.data); curl_easy_cleanup(curl);
    return 0;
fail:
    curl_free(e_chat); free(post); free(resp.data); curl_easy_cleanup(curl);
    return -1;
}

static int maintenance_unpin_already_clear(long http_code, const char *description)
{
    /* Telegram returns HTTP 400 when the requested message is no longer pinned
     * (or otherwise no longer available to unpin). For our state machine this is
     * an idempotent success: the desired post-condition "message is not pinned"
     * has already been reached, so the stale managed ID must not be retained. */
    return http_code == 400 && description != NULL &&
           strstr(description, "message to unpin not found") != NULL;
}

static void maintenance_log_unpin_already_clear(const struct maintenance_notice_event *ev,
                                                 int64_t message_id, long http_code,
                                                 const char *description)
{
    if (!ev || !ev->ch || message_id <= 0) return;
    log_msg(LOG_NOTICE,
            "event=MAINTENANCE_NOTICE_UNPIN_ALREADY_CLEAR version=%s listen_port=%d label=%s message_id=%lld telegram_http=%ld result=already-unpinned error=\"%s\"",
            PROGRAM_VERSION, ev->ch->port, ev->label, (long long)message_id,
            http_code, description && description[0] ? description : "message to unpin not found");
}

static int maintenance_notice_event_is_current(const struct maintenance_notice_event *ev)
{
    bool on;
    uint64_t generation;
    if (!ev || !ev->ch) return 0;
    pthread_mutex_lock(&maintenance_mutex);
    on = ev->ch->maintenance_suppress;
    generation = ev->ch->maintenance_generation;
    pthread_mutex_unlock(&maintenance_mutex);
    return generation == ev->generation && on == ev->enabled;
}

static int maintenance_publish_notice(const struct maintenance_notice_event *ev)
{
    int64_t new_id = 0, old_id = 0, stale_id = 0, remaining_stale = 0;
    long http = 0, pin_http = 0;
    char desc[512] = "", pin_desc[512] = "";
    int send_rc, pin_rc = -1;

    if (!ev || !ev->ch) return -1;
    if (!maintenance_notice_event_is_current(ev)) {
        log_msg(LOG_NOTICE,
                "event=MAINTENANCE_NOTICE_STALE_SKIP version=%s listen_port=%d label=%s requested_state=%s generation=%llu",
                PROGRAM_VERSION, ev->ch->port, ev->label, ev->enabled ? "on" : "off",
                (unsigned long long)ev->generation);
        return 1;
    }

    pthread_mutex_lock(&maintenance_notice_mutex);
    if (!maintenance_notice_event_is_current(ev)) {
        pthread_mutex_unlock(&maintenance_notice_mutex);
        return 1;
    }
    old_id = ev->ch->maintenance_notice_message_id;
    stale_id = ev->ch->maintenance_notice_stale_message_id;
    send_rc = maintenance_telegram_send_message(ev, &new_id, &http, desc, sizeof(desc));
    if (send_rc != 0) {
        int64_t failed_unpin = 0;
        metric_record(METRIC_MAINTENANCE_NOTICE_FAIL);
        log_msg(LOG_ERR,
                "event=MAINTENANCE_NOTICE_SEND_FAIL version=%s listen_port=%d label=%s chat_id=%s state=%s trigger=%s telegram_http=%ld error=\"%s\" maintenance_state_retained=yes",
                PROGRAM_VERSION, ev->ch->port, ev->label, ev->chat_id,
                ev->enabled ? "on" : "off", ev->trigger, http,
                desc[0] ? desc : "sendMessage failed");
        /* Never intentionally leave a stale opposite-state maintenance pin.
         * If Telegram is reachable enough to unpin, remove the old managed pin
         * even when publishing the replacement message failed. */
        if (stale_id > 0 && stale_id != old_id) {
            pin_http = 0; pin_desc[0] = '\0';
            if (maintenance_telegram_pin_action(ev, stale_id, false, &pin_http, pin_desc, sizeof(pin_desc)) != 0) {
                if (maintenance_unpin_already_clear(pin_http, pin_desc))
                    maintenance_log_unpin_already_clear(ev, stale_id, pin_http, pin_desc);
                else
                    failed_unpin = stale_id;
            }
        }
        if (old_id > 0) {
            pin_http = 0; pin_desc[0] = '\0';
            if (maintenance_telegram_pin_action(ev, old_id, false, &pin_http, pin_desc, sizeof(pin_desc)) != 0) {
                if (maintenance_unpin_already_clear(pin_http, pin_desc))
                    maintenance_log_unpin_already_clear(ev, old_id, pin_http, pin_desc);
                else
                    failed_unpin = old_id;
            }
        }
        if (failed_unpin == 0)
            (void)maintenance_notice_persist(ev->ch, 0, 0, ev->enabled);
        else
            (void)maintenance_notice_persist(ev->ch, 0, failed_unpin, ev->enabled);
        pthread_mutex_unlock(&maintenance_notice_mutex);
        return -1;
    }
    metric_record(METRIC_MAINTENANCE_NOTICE_SENT);

    if (stale_id > 0 && stale_id != old_id) {
        if (maintenance_telegram_pin_action(ev, stale_id, false, &pin_http, pin_desc, sizeof(pin_desc)) != 0) {
            if (maintenance_unpin_already_clear(pin_http, pin_desc)) {
                maintenance_log_unpin_already_clear(ev, stale_id, pin_http, pin_desc);
            } else {
                remaining_stale = stale_id;
                log_msg(LOG_WARNING,
                        "event=MAINTENANCE_NOTICE_UNPIN_FAIL version=%s listen_port=%d label=%s message_id=%lld telegram_http=%ld error=\"%s\"",
                        PROGRAM_VERSION, ev->ch->port, ev->label, (long long)stale_id,
                        pin_http, pin_desc[0] ? pin_desc : "unpinChatMessage failed");
            }
        }
    }
    pin_http = 0; pin_desc[0] = '\0';
    if (old_id > 0) {
        if (maintenance_telegram_pin_action(ev, old_id, false, &pin_http, pin_desc, sizeof(pin_desc)) != 0) {
            if (maintenance_unpin_already_clear(pin_http, pin_desc)) {
                maintenance_log_unpin_already_clear(ev, old_id, pin_http, pin_desc);
            } else {
                remaining_stale = old_id;
                log_msg(LOG_WARNING,
                        "event=MAINTENANCE_NOTICE_UNPIN_FAIL version=%s listen_port=%d label=%s message_id=%lld telegram_http=%ld error=\"%s\"",
                        PROGRAM_VERSION, ev->ch->port, ev->label, (long long)old_id,
                        pin_http, pin_desc[0] ? pin_desc : "unpinChatMessage failed");
            }
        }
    }

    pin_http = 0; pin_desc[0] = '\0';
    pin_rc = maintenance_telegram_pin_action(ev, new_id, true, &pin_http, pin_desc, sizeof(pin_desc));
    if (pin_rc == 0) {
        metric_record(METRIC_MAINTENANCE_NOTICE_PIN);
    } else {
        metric_record(METRIC_MAINTENANCE_NOTICE_FAIL);
        log_msg(LOG_ERR,
                "event=MAINTENANCE_NOTICE_PIN_FAIL version=%s listen_port=%d label=%s chat_id=%s state=%s message_id=%lld telegram_http=%ld error=\"%s\" notice_sent=yes",
                PROGRAM_VERSION, ev->ch->port, ev->label, ev->chat_id,
                ev->enabled ? "on" : "off", (long long)new_id, pin_http,
                pin_desc[0] ? pin_desc : "pinChatMessage failed");
    }

    if (maintenance_notice_persist(ev->ch, pin_rc == 0 ? new_id : 0,
                                   remaining_stale, ev->enabled) != 0) {
        log_msg(LOG_ERR,
                "event=MAINTENANCE_NOTICE_STATE_PERSIST_FAIL version=%s listen_port=%d label=%s error=%s",
                PROGRAM_VERSION, ev->ch->port, ev->label, strerror(errno));
    }
    log_msg(LOG_NOTICE,
            "event=MAINTENANCE_NOTICE_SENT version=%s listen_port=%d label=%s chat_id=%s state=%s trigger=%s message_id=%lld pin=%s telegram_http=%ld pin_http=%ld previous_message_id=%lld stale_message_id=%lld",
            PROGRAM_VERSION, ev->ch->port, ev->label, ev->chat_id,
            ev->enabled ? "on" : "off", ev->trigger, (long long)new_id,
            pin_rc == 0 ? "yes" : "no", http, pin_http,
            (long long)old_id, (long long)remaining_stale);
    pthread_mutex_unlock(&maintenance_notice_mutex);
    return pin_rc == 0 ? 0 : -1;
}

static void *maintenance_auto_notice_thread(void *arg)
{
    struct maintenance_notice_event *ev = arg;
    if (ev) {
        (void)maintenance_publish_notice(ev);
        free(ev);
    }
    pthread_mutex_lock(&maintenance_notice_thread_mutex);
    if (maintenance_notice_threads > 0U) maintenance_notice_threads--;
    pthread_cond_broadcast(&maintenance_notice_thread_cond);
    pthread_mutex_unlock(&maintenance_notice_thread_mutex);
    return NULL;
}

static void maintenance_spawn_auto_off_notice(const struct maintenance_notice_event *ev)
{
    pthread_t tid;
    struct maintenance_notice_event *copy;
    int rc;
    if (!ev) return;
    copy = malloc(sizeof(*copy));
    if (!copy) {
        log_msg(LOG_ERR, "event=MAINTENANCE_NOTICE_THREAD_FAIL version=%s reason=oom", PROGRAM_VERSION);
        return;
    }
    *copy = *ev;
    pthread_mutex_lock(&maintenance_notice_thread_mutex);
    maintenance_notice_threads++;
    pthread_mutex_unlock(&maintenance_notice_thread_mutex);
    rc = pthread_create(&tid, NULL, maintenance_auto_notice_thread, copy);
    if (rc != 0) {
        pthread_mutex_lock(&maintenance_notice_thread_mutex);
        if (maintenance_notice_threads > 0U) maintenance_notice_threads--;
        pthread_cond_broadcast(&maintenance_notice_thread_cond);
        pthread_mutex_unlock(&maintenance_notice_thread_mutex);
        free(copy);
        log_msg(LOG_ERR, "event=MAINTENANCE_NOTICE_THREAD_FAIL version=%s error=%s", PROGRAM_VERSION, strerror(rc));
        return;
    }
    (void)pthread_detach(tid);
}

static void maintenance_wait_notice_threads(void)
{
    pthread_mutex_lock(&maintenance_notice_thread_mutex);
    while (maintenance_notice_threads > 0U)
        pthread_cond_wait(&maintenance_notice_thread_cond, &maintenance_notice_thread_mutex);
    pthread_mutex_unlock(&maintenance_notice_thread_mutex);
}

static void maintenance_reconcile_notice_states(void)
{
    size_t i;
    for (i = 0U; i < channel_count; i++) {
        struct channel *ch = &channels[i];
        struct maintenance_snapshot snap;
        struct maintenance_notice_event ev;
        bool mismatch;
        if (!ch->selected || !ch->maintenance_notice_state_valid) continue;
        maintenance_get_snapshot(ch, &snap);
        pthread_mutex_lock(&maintenance_notice_mutex);
        mismatch = ch->maintenance_notice_state_valid &&
                   (ch->maintenance_notice_state_on != snap.on ||
                    ch->maintenance_notice_message_id <= 0 ||
                    ch->maintenance_notice_stale_message_id > 0);
        pthread_mutex_unlock(&maintenance_notice_mutex);
        if (!mismatch) continue;
        maintenance_build_notice_event(&ev, ch, snap.on, &snap,
                                       snap.enabled_by[0] ? snap.enabled_by : "startup",
                                       "startup-reconcile");
        (void)maintenance_publish_notice(&ev);
    }
}

static int validate_config_tokens(void)
{
    size_t i, j;
    unsigned group = 0, ok = 0, failed = 0;

    for (i = 0; i < channel_count; i++) {
        CURL *curl;
        struct mem_buf resp = {0};
        struct retry_header_state hdr;
        char errorbuf[CURL_ERROR_SIZE];
        char url[512];
        CURLcode rc;
        long http = 0;
        char desc[512] = "";
        bool seen = false;

        if (!channels[i].selected) continue;
        for (j = 0; j < i; j++) {
            if (channels[j].selected && strcmp(channels[j].token, channels[i].token) == 0) { seen = true; break; }
        }
        if (seen) continue;
        group++;
        if (snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/getMe", channels[i].token) >= (int)sizeof(url)) {
            fprintf(stderr, "token_group=%u label=%s result=FAIL reason=token-too-long\n", group, channels[i].label);
            failed++;
            continue;
        }
        curl = curl_easy_init();
        if (!curl) {
            fprintf(stderr, "token_group=%u label=%s result=FAIL reason=curl-init\n", group, channels[i].label);
            failed++;
            continue;
        }
        set_common_curl_options(curl, &resp, &hdr, errorbuf);
        curl_easy_setopt(curl, CURLOPT_URL, url);
        curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
        rc = curl_easy_perform(curl);
        if (rc == CURLE_OK) (void)curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http);
        parse_json_description(resp.data, desc, sizeof(desc));
        if (rc == CURLE_OK && http >= 200 && http < 300) {
            printf("token_group=%u label=%s result=OK http=%ld\n", group, channels[i].label, http);
            ok++;
        } else {
            char esc[1200];
            const char *why = desc[0] ? desc : (rc == CURLE_OK ? "Telegram HTTP failure" : (errorbuf[0] ? errorbuf : curl_easy_strerror(rc)));
            audit_escape((const unsigned char *)why, strlen(why), esc, sizeof(esc));
            printf("token_group=%u label=%s result=FAIL http=%ld curl_code=%d error=\"%s\"\n",
                   group, channels[i].label, http, (int)rc, esc);
            failed++;
        }
        free(resp.data);
        curl_easy_cleanup(curl);
    }
    printf("unique_tokens=%u ok=%u failed=%u\n", group, ok, failed);
    return failed ? -1 : 0;
}

static int telegram_send_message_once(CURL *curl, const struct spool_job *job,
                                      struct mem_buf *resp, struct send_result *r)
{
    char url[512], errorbuf[CURL_ERROR_SIZE];
    char *text = NULL, *parse_mode = NULL, *e_chat = NULL, *e_text = NULL, *e_parse = NULL, *post = NULL;
    size_t postlen;
    struct retry_header_state hdr;
    bool is_form = strncasecmp(job->content_type, "application/x-www-form-urlencoded", 33) == 0;

    memset(r, 0, sizeof(*r)); r->retry_after_sec = -1;
    if (is_form) {
        text = form_get_value(job->body, job->body_len, "text");
        parse_mode = form_get_value(job->body, job->body_len, "parse_mode");
        if ((!parse_mode || !*parse_mode) && job->parse_mode[0]) {
            free(parse_mode);
            parse_mode = strdup(job->parse_mode);
        }
    } else {
        text = malloc(job->body_len + 1U);
        if (text) { memcpy(text, job->body, job->body_len); text[job->body_len] = '\0'; }
        if (job->parse_mode[0]) parse_mode = strdup(job->parse_mode);
    }
    if (!text || !*text) { snprintf(r->error, sizeof(r->error), "message text is empty"); goto local_fail; }
    if (parse_mode && strcasecmp(parse_mode, "HTML") == 0)
        normalize_html_newline_escapes(text);
    if (snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendMessage", job->token) >= (int)sizeof(url)) {
        snprintf(r->error, sizeof(r->error), "token too long"); goto local_fail;
    }
    if (!curl) { snprintf(r->error, sizeof(r->error), "curl handle unavailable"); goto local_fail; }
    curl_easy_reset(curl);
    e_chat = curl_easy_escape(curl, job->chat_id, 0);
    e_text = curl_easy_escape(curl, text, (int)strlen(text));
    if (parse_mode && *parse_mode) e_parse = curl_easy_escape(curl, parse_mode, 0);
    if (!e_chat || !e_text || ((parse_mode && *parse_mode) && !e_parse)) { snprintf(r->error, sizeof(r->error), "URL encoding failed"); goto local_fail; }
    postlen = strlen(e_chat) + strlen(e_text) + 32U + (e_parse ? strlen(e_parse) + 16U : 0U);
    post = malloc(postlen); if (!post) { snprintf(r->error, sizeof(r->error), "out of memory"); goto local_fail; }
    snprintf(post, postlen, "chat_id=%s&text=%s%s%s", e_chat, e_text,
             e_parse ? "&parse_mode=" : "", e_parse ? e_parse : "");

    mem_buf_reset(resp);
    set_common_curl_options(curl, resp, &hdr, errorbuf);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, post);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(post));
    r->curl_code = curl_easy_perform(curl);
    if (r->curl_code == CURLE_OK) (void)curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &r->http_code);
    else snprintf(r->error, sizeof(r->error), "%s", errorbuf[0] ? errorbuf : curl_easy_strerror(r->curl_code));
    r->retry_after_sec = hdr.retry_after_sec;
    {
        long jr = parse_json_retry_after(resp->data);
        if (jr > r->retry_after_sec) r->retry_after_sec = jr;
    }
    parse_json_description(resp->data, r->telegram_description, sizeof(r->telegram_description));
    curl_free(e_chat); curl_free(e_text); curl_free(e_parse); free(post); free(text); free(parse_mode);
    return 0;
local_fail:
    curl_free(e_chat); curl_free(e_text); curl_free(e_parse); free(post); free(text); free(parse_mode);
    r->curl_code = CURLE_FAILED_INIT;
    return -1;
}

static int telegram_send_photo_once(CURL *curl, const struct spool_job *job,
                                    struct mem_buf *resp, struct send_result *r)
{
    CURLcode rc;
    curl_mime *mime = NULL;
    curl_mimepart *part;
    char url[512], errorbuf[CURL_ERROR_SIZE];
    const char *mime_type, *filename;
    struct retry_header_state hdr;

    memset(r, 0, sizeof(*r)); r->retry_after_sec = -1;
    if (!job->body_len) { snprintf(r->error, sizeof(r->error), "photo body empty"); return -1; }
    if (strncasecmp(job->content_type, "image/png", 9) == 0) { mime_type = "image/png"; filename = "upload.png"; }
    else if (strncasecmp(job->content_type, "image/jpeg", 10) == 0 || strncasecmp(job->content_type, "image/jpg", 9) == 0) {
        mime_type = "image/jpeg"; filename = "upload.jpg";
    } else { snprintf(r->error, sizeof(r->error), "unsupported image content type"); return -1; }
    if (snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendPhoto", job->token) >= (int)sizeof(url)) {
        snprintf(r->error, sizeof(r->error), "token too long"); return -1;
    }
    if (!curl) { snprintf(r->error, sizeof(r->error), "curl handle unavailable"); return -1; }
    curl_easy_reset(curl);
    mime = curl_mime_init(curl); if (!mime) { snprintf(r->error, sizeof(r->error), "curl_mime_init failed"); return -1; }
    part = curl_mime_addpart(mime); curl_mime_name(part, "chat_id"); curl_mime_data(part, job->chat_id, CURL_ZERO_TERMINATED);
    if (job->caption[0]) { part = curl_mime_addpart(mime); curl_mime_name(part, "caption"); curl_mime_data(part, job->caption, CURL_ZERO_TERMINATED); }
    if (job->parse_mode[0]) { part = curl_mime_addpart(mime); curl_mime_name(part, "parse_mode"); curl_mime_data(part, job->parse_mode, CURL_ZERO_TERMINATED); }
    part = curl_mime_addpart(mime); curl_mime_name(part, "photo"); curl_mime_filename(part, filename); curl_mime_type(part, mime_type);
    curl_mime_data(part, (const char *)job->body, job->body_len);

    mem_buf_reset(resp);
    set_common_curl_options(curl, resp, &hdr, errorbuf);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);
    rc = curl_easy_perform(curl); r->curl_code = rc;
    if (rc == CURLE_OK) (void)curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &r->http_code);
    else snprintf(r->error, sizeof(r->error), "%s", errorbuf[0] ? errorbuf : curl_easy_strerror(rc));
    r->retry_after_sec = hdr.retry_after_sec;
    {
        long jr = parse_json_retry_after(resp->data);
        if (jr > r->retry_after_sec) r->retry_after_sec = jr;
    }
    parse_json_description(resp->data, r->telegram_description, sizeof(r->telegram_description));
    curl_mime_free(mime);
    return 0;
}

static int telegram_send_document_once(CURL *curl, const struct spool_job *job,
                                       struct mem_buf *resp, struct send_result *r)
{
    CURLcode rc;
    curl_mime *mime = NULL;
    curl_mimepart *part;
    char url[512], errorbuf[CURL_ERROR_SIZE];
    struct retry_header_state hdr;
    const char *filename = job->filename[0] ? job->filename : "upload.bin";
    const char *ctype = job->content_type[0] ? job->content_type : "application/octet-stream";

    memset(r, 0, sizeof(*r)); r->retry_after_sec = -1;
    if (!job->body_len) { snprintf(r->error, sizeof(r->error), "document body empty"); return -1; }
    if (snprintf(url, sizeof(url), "https://api.telegram.org/bot%s/sendDocument", job->token) >= (int)sizeof(url)) {
        snprintf(r->error, sizeof(r->error), "token too long"); return -1;
    }
    if (!curl) { snprintf(r->error, sizeof(r->error), "curl handle unavailable"); return -1; }
    curl_easy_reset(curl);
    mime = curl_mime_init(curl);
    if (!mime) { snprintf(r->error, sizeof(r->error), "curl_mime_init failed"); return -1; }

    part = curl_mime_addpart(mime); curl_mime_name(part, "chat_id"); curl_mime_data(part, job->chat_id, CURL_ZERO_TERMINATED);
    if (job->caption[0]) { part = curl_mime_addpart(mime); curl_mime_name(part, "caption"); curl_mime_data(part, job->caption, CURL_ZERO_TERMINATED); }
    if (job->parse_mode[0]) { part = curl_mime_addpart(mime); curl_mime_name(part, "parse_mode"); curl_mime_data(part, job->parse_mode, CURL_ZERO_TERMINATED); }
    part = curl_mime_addpart(mime); curl_mime_name(part, "document"); curl_mime_filename(part, filename); curl_mime_type(part, ctype);
    curl_mime_data(part, (const char *)job->body, job->body_len);

    mem_buf_reset(resp);
    set_common_curl_options(curl, resp, &hdr, errorbuf);
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_MIMEPOST, mime);
    rc = curl_easy_perform(curl); r->curl_code = rc;
    if (rc == CURLE_OK) (void)curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &r->http_code);
    else snprintf(r->error, sizeof(r->error), "%s", errorbuf[0] ? errorbuf : curl_easy_strerror(rc));
    r->retry_after_sec = hdr.retry_after_sec;
    { long jr = parse_json_retry_after(resp->data); if (jr > r->retry_after_sec) r->retry_after_sec = jr; }
    parse_json_description(resp->data, r->telegram_description, sizeof(r->telegram_description));
    curl_mime_free(mime);
    return 0;
}

static long choose_retry_delay_ms(unsigned attempt_no, const struct send_result *r)
{
    (void)r;
    return jitter_ms(exponential_backoff_ms(attempt_no));
}

static long choose_rate_limit_defer_ms(const struct send_result *r,
                                       long *effective_retry_after_sec)
{
    long retry_sec = r ? r->retry_after_sec : -1;
    long delay;

    if (retry_sec < 0) {
        delay = RATE_LIMIT_DEFAULT_DEFER_MS;
        if (effective_retry_after_sec) *effective_retry_after_sec = -1;
    } else {
        if (retry_sec > UPSTREAM_RETRY_AFTER_MAX_SEC)
            retry_sec = UPSTREAM_RETRY_AFTER_MAX_SEC;
        delay = retry_sec * 1000L;
        if (effective_retry_after_sec) *effective_retry_after_sec = retry_sec;
    }
    if (delay < UPSTREAM_BACKOFF_BASE_MS) delay = UPSTREAM_BACKOFF_BASE_MS;
    if (delay > LONG_MAX - RATE_LIMIT_SAFETY_MARGIN_MS)
        return LONG_MAX;
    return delay + RATE_LIMIT_SAFETY_MARGIN_MS;
}

static void *worker_main(void *arg)
{
    unsigned worker_id = (unsigned)(uintptr_t)arg;
    struct mem_buf resp = {0};
    CURL *worker_curl = curl_easy_init();

    if (!worker_curl) {
        log_msg(LOG_ERR, "event=WORKER_CURL_INIT_FAIL version=%s worker=%u",
                PROGRAM_VERSION, worker_id);
        fatal_flag = 1;
        stop_flag = 1;
        pthread_mutex_lock(&queue_mutex);
        pthread_cond_broadcast(&queue_cond);
        pthread_mutex_unlock(&queue_mutex);
        return NULL;
    }

    log_msg(LOG_NOTICE, "event=WORKER_START version=%s worker=%u", PROGRAM_VERSION, worker_id);
    while (!stop_flag) {
        struct pending_item it;
        int64_t wait_ms = 0;
        int src = scan_next_pending(&it, &wait_ms);
        char working_path[SPOOL_PATH_SIZE];
        struct spool_job job;
        unsigned attempt_no;
        struct send_result sr;
        int send_rc;
        bool bot_recovery_probe = false;
        unsigned bot_recovery_streak = 0;

        if (src < 0) { sleep_ms_interruptible(1000); continue; }
        if (src == 1 || src == 2) {
            struct timespec ts;
            int64_t wake = realtime_ms() + (wait_ms > 1000 ? 1000 : wait_ms);
            ts.tv_sec = (time_t)(wake / 1000); ts.tv_nsec = (long)((wake % 1000) * 1000000L);
            pthread_mutex_lock(&queue_mutex);
            if (!stop_flag) (void)pthread_cond_timedwait(&queue_cond, &queue_mutex, &ts);
            pthread_mutex_unlock(&queue_mutex);
            continue;
        }
        if (claim_job(&it, working_path) != 0) continue;
        if (load_spool_job(working_path, &job) != 0) {
            log_msg(LOG_ERR, "event=JOB_CORRUPT version=%s worker=%u file=%s", PROGRAM_VERSION, worker_id, it.basename);
            (void)fail_working_with_metadata(working_path, it.job_id,
                    it.attempts_done, it.rate_limit_deferrals, 0,
                    "spool-corrupt", 0, 0, "", false);
            continue;
        }
        attempt_no = it.attempts_done + 1U;
        log_msg(LOG_INFO,
                "event=JOB_DEQUEUE version=%s worker=%u job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s attempt=%u",
                PROGRAM_VERSION, worker_id, job.job_id, job.client_ip, job.listen_port, job.label, job.endpoint, attempt_no);

        {
            int64_t bot_until = 0, circuit_until = 0, defer_until = 0;
            int prc = persistent_bot_rate_peek(&job, &bot_until);
            int brc = circuit_defer_until(&job, &circuit_until);
            int64_t now = realtime_ms();
            if (prc < 0 || brc < 0) {
                log_msg(LOG_ERR,
                        "event=BOT_GATE_ERROR version=%s worker=%u job_id=%s error=%s",
                        PROGRAM_VERSION, worker_id, job.job_id, strerror(errno));
            }
            if (bot_until > now) defer_until = bot_until;
            if (circuit_until > defer_until) defer_until = circuit_until;
            if (defer_until > now) {
                log_msg(LOG_INFO,
                        "event=BOT_GATE_DEFER version=%s worker=%u job_id=%s listen_port=%d label=%s defer_ms=%lld reason=%s",
                        PROGRAM_VERSION, worker_id, job.job_id, job.listen_port, job.label,
                        (long long)(defer_until - now),
                        circuit_until >= bot_until ? "circuit-breaker" : "bot-rate-cooldown");
                if (requeue_working(working_path, job.job_id, it.attempts_done, it.rate_limit_deferrals, defer_until) != 0) {
                    (void)fail_working_with_metadata(working_path, job.job_id,
                            it.attempts_done, it.rate_limit_deferrals, job.created_ms,
                            "bot-gate-requeue-error", 0, 0, "", false);
                }
                free_spool_job(&job);
                continue;
            }
        }

        {
            int64_t defer_until = 0;
            int rrc = persistent_rate_reserve_or_defer(&job, attempt_no, &defer_until);
            if (rrc > 0) {
                if (requeue_working(working_path, job.job_id, it.attempts_done, it.rate_limit_deferrals, defer_until) != 0) {
                    log_msg(LOG_ERR, "event=RATE_LIMIT_REQUEUE_ERROR version=%s worker=%u job_id=%s error=%s",
                            PROGRAM_VERSION, worker_id, job.job_id, strerror(errno));
                    (void)fail_working_with_metadata(working_path, job.job_id,
                            it.attempts_done, it.rate_limit_deferrals, job.created_ms,
                            "rate-limit-requeue-error", 0, 0, "", false);
                }
                free_spool_job(&job);
                continue;
            }
            if (rrc < 0) {
                log_msg(LOG_ERR, "event=RATE_LIMIT_ERROR version=%s worker=%u job_id=%s error=%s",
                        PROGRAM_VERSION, worker_id, job.job_id, strerror(errno));
                (void)fail_working_with_metadata(working_path, job.job_id,
                        it.attempts_done, it.rate_limit_deferrals, job.created_ms,
                        "rate-limit-error", 0, 0, "", false);
                free_spool_job(&job);
                continue;
            }
        }
        if (stop_flag) {
            (void)requeue_working(working_path, job.job_id, it.attempts_done, it.rate_limit_deferrals, realtime_ms());
            free_spool_job(&job); break;
        }

        {
            int64_t bot_defer_until = 0;
            int arc = persistent_bot_rate_acquire_send(&job, &bot_defer_until, &bot_recovery_streak);
            if (arc < 0) {
                log_msg(LOG_ERR,
                        "event=BOT_RATE_GATE_ERROR version=%s worker=%u job_id=%s error=%s",
                        PROGRAM_VERSION, worker_id, job.job_id, strerror(errno));
                (void)fail_working_with_metadata(working_path, job.job_id,
                        it.attempts_done, it.rate_limit_deferrals, job.created_ms,
                        "bot-rate-gate-error", 0, 0, "", false);
                free_spool_job(&job);
                continue;
            }
            if (arc == 1) {
                int64_t now = realtime_ms();
                if (bot_defer_until <= now) bot_defer_until = now + 1000LL;
                log_msg(LOG_INFO,
                        "event=BOT_GATE_DEFER version=%s worker=%u job_id=%s listen_port=%d label=%s "
                        "defer_ms=%lld reason=bot-recovery-probe-inflight",
                        PROGRAM_VERSION, worker_id, job.job_id, job.listen_port, job.label,
                        (long long)(bot_defer_until - now));
                if (requeue_working(working_path, job.job_id, it.attempts_done,
                                    it.rate_limit_deferrals, bot_defer_until) != 0) {
                    (void)fail_working_with_metadata(working_path, job.job_id,
                            it.attempts_done, it.rate_limit_deferrals, job.created_ms,
                            "bot-rate-probe-requeue-error", 0, 0, "", false);
                }
                free_spool_job(&job);
                continue;
            }
            if (arc == 2) {
                bot_recovery_probe = true;
                log_msg(LOG_NOTICE,
                        "event=BOT_RATE_RECOVERY_PROBE version=%s worker=%u job_id=%s listen_port=%d label=%s "
                        "consecutive_429=%u",
                        PROGRAM_VERSION, worker_id, job.job_id, job.listen_port, job.label,
                        bot_recovery_streak);
            }
        }

        if (strcmp(job.endpoint, "/sendMessage") == 0)
            send_rc = telegram_send_message_once(worker_curl, &job, &resp, &sr);
        else if (strcmp(job.endpoint, "/sendPhoto") == 0)
            send_rc = telegram_send_photo_once(worker_curl, &job, &resp, &sr);
        else if (strcmp(job.endpoint, "/sendDocument") == 0)
            send_rc = telegram_send_document_once(worker_curl, &job, &resp, &sr);
        else {
            memset(&sr, 0, sizeof(sr)); snprintf(sr.error, sizeof(sr.error), "unknown endpoint"); send_rc = -1;
        }

        if (send_rc == 0 && sr.curl_code == CURLE_OK && sr.http_code >= 200 && sr.http_code < 300) {
            bool cleared_recovery = false;
            unsigned previous_429_streak = 0;
            if (persistent_bot_rate_record_success(&job, &cleared_recovery, &previous_429_streak) != 0) {
                log_msg(LOG_ERR,
                        "event=BOT_RATE_RECOVERY_CLEAR_ERROR version=%s worker=%u job_id=%s error=%s",
                        PROGRAM_VERSION, worker_id, job.job_id, strerror(errno));
                persistent_bot_rate_release_probe(&job);
            } else if (cleared_recovery) {
                log_msg(LOG_NOTICE,
                        "event=BOT_RATE_RECOVERY_CLEAR version=%s worker=%u job_id=%s listen_port=%d label=%s "
                        "previous_consecutive_429=%u telegram_http=%ld",
                        PROGRAM_VERSION, worker_id, job.job_id, job.listen_port, job.label,
                        previous_429_streak, sr.http_code);
            }
            circuit_record_success(&job);
            metric_record(METRIC_SENT);
            log_msg(LOG_INFO,
                    "event=JOB_SENT version=%s worker=%u job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s "
                    "attempt=%u telegram_http=%ld response_bytes=%zu",
                    PROGRAM_VERSION, worker_id, job.job_id, job.client_ip, job.listen_port, job.label,
                    job.endpoint, attempt_no, sr.http_code, resp.len);
            if (complete_working(working_path) != 0)
                log_msg(LOG_ERR, "event=SPOOL_COMPLETE_ERROR version=%s job_id=%s error=%s",
                        PROGRAM_VERSION, job.job_id, strerror(errno));
        } else {
            /* Telegram HTTP 429 is flow control, not a delivery failure.
             * Do not consume UPSTREAM_MAX_ATTEMPTS. Persist a separate
             * rate-limit deferral counter and honor the strongest Retry-After
             * (HTTP header vs JSON parameters.retry_after) plus a safety margin.
             */
            if (send_rc == 0 && sr.curl_code == CURLE_OK && sr.http_code == 429) {
                unsigned new_deferrals = it.rate_limit_deferrals;
                unsigned consecutive_429 = 0;
                long effective_retry_after = -1;
                long telegram_floor = choose_rate_limit_defer_ms(&sr, &effective_retry_after);
                long delay = telegram_floor;
                int64_t now = realtime_ms();
                int64_t due = telegram_floor >= 0 && now <= INT64_MAX - telegram_floor ? now + telegram_floor : INT64_MAX;
                int64_t job_age = age_seconds_from_ms(job.created_ms);
                bool entered_recovery = false;
                int brs;

                if (new_deferrals < UINT_MAX) new_deferrals++;
                metric_record(METRIC_RATE_DEFER);
                metric_record(METRIC_TELEGRAM_429_DEFER);

                brs = persistent_bot_rate_record_429(&job, telegram_floor,
                                                      &consecutive_429, &delay, &due,
                                                      &entered_recovery);
                if (brs != 0) {
                    log_msg(LOG_ERR,
                            "event=BOT_RATE_STATE_ERROR version=%s worker=%u job_id=%s action=record-429 error=%s",
                            PROGRAM_VERSION, worker_id, job.job_id, strerror(errno));
                    persistent_bot_rate_release_probe(&job);
                    consecutive_429 = 0;
                    delay = telegram_floor;
                    due = delay >= 0 && now <= INT64_MAX - delay ? now + delay : INT64_MAX;
                } else {
                    if (entered_recovery) {
                        log_msg(LOG_NOTICE,
                                "event=BOT_RATE_RECOVERY_ENTER version=%s worker=%u job_id=%s listen_port=%d label=%s "
                                "consecutive_429=%u telegram_http=429",
                                PROGRAM_VERSION, worker_id, job.job_id, job.listen_port, job.label,
                                consecutive_429);
                    }
                    log_msg(LOG_WARNING,
                            "event=BOT_COOLDOWN_SET version=%s job_id=%s listen_port=%d label=%s "
                            "telegram_http=429 consecutive_429=%u retry_after_sec=%ld safety_margin_ms=%ld "
                            "telegram_floor_ms=%ld adaptive_floor_ms=%ld cooldown_ms=%ld",
                            PROGRAM_VERSION, job.job_id, job.listen_port, job.label,
                            consecutive_429, effective_retry_after, RATE_LIMIT_SAFETY_MARGIN_MS,
                            telegram_floor, adaptive_429_floor_ms(consecutive_429), delay);
                }

                if (job_age >= MAX_JOB_AGE_SEC) {
                    char tg_error[1200];
                    const char *tg_src = sr.telegram_description[0] ? sr.telegram_description : "none";
                    audit_escape((const unsigned char *)tg_src, strlen(tg_src), tg_error, sizeof(tg_error));
                    metric_record(METRIC_FAILED);
                    log_msg(LOG_ERR,
                            "event=JOB_FAILED version=%s worker=%u job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s "
                            "attempt=%u rate_limit_deferrals=%u consecutive_429=%u telegram_http=429 reason=rate-limit-expired "
                            "job_age_sec=%lld max_job_age_sec=%lld telegram_error=\"%s\"",
                            PROGRAM_VERSION, worker_id, job.job_id, job.client_ip,
                            job.listen_port, job.label, job.endpoint, it.attempts_done,
                            new_deferrals, consecutive_429, (long long)job_age,
                            (long long)MAX_JOB_AGE_SEC, tg_error);
                    if (fail_working_with_metadata(working_path, job.job_id,
                            it.attempts_done, new_deferrals, job.created_ms,
                            "rate-limit-expired", 429, 0,
                            sr.telegram_description, false) != 0)
                        log_msg(LOG_ERR,
                                "event=SPOOL_FAIL_MOVE_ERROR version=%s job_id=%s error=%s",
                                PROGRAM_VERSION, job.job_id, strerror(errno));
                    free_spool_job(&job);
                    continue;
                }

                log_msg(LOG_WARNING,
                        "event=RATE_LIMIT_DEFER version=%s worker=%u job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s "
                        "delivery_attempt=%u rate_limit_deferrals=%u consecutive_429=%u telegram_http=429 retry_after_sec=%ld "
                        "safety_margin_ms=%ld telegram_floor_ms=%ld adaptive_floor_ms=%ld defer_ms=%ld job_age_sec=%lld",
                        PROGRAM_VERSION, worker_id, job.job_id, job.client_ip,
                        job.listen_port, job.label, job.endpoint, attempt_no,
                        new_deferrals, consecutive_429, effective_retry_after,
                        RATE_LIMIT_SAFETY_MARGIN_MS, telegram_floor,
                        consecutive_429 ? adaptive_429_floor_ms(consecutive_429) : 0L,
                        delay, (long long)job_age);

                if (requeue_working(working_path, job.job_id, it.attempts_done,
                                    new_deferrals, due) != 0) {
                    log_msg(LOG_ERR,
                            "event=SPOOL_REQUEUE_ERROR version=%s job_id=%s error=%s",
                            PROGRAM_VERSION, job.job_id, strerror(errno));
                    (void)fail_working_with_metadata(working_path, job.job_id,
                            it.attempts_done, new_deferrals, job.created_ms,
                            "rate-limit-requeue-error", 429, 0,
                            sr.telegram_description, false);
                }
                free_spool_job(&job);
                continue;
            }

            bool retry = false, ambiguous = false;
            bool availability_failure = false;
            if (bot_recovery_probe) {
                persistent_bot_rate_release_probe(&job);
                bot_recovery_probe = false;
            }
            long delay = 0;
            const char *reason = "permanent";

            if (send_rc == 0 && sr.curl_code == CURLE_OK && http_retryable(sr.http_code)) {
                retry = true; reason = "http-retryable"; delay = choose_retry_delay_ms(attempt_no, &sr);
                if (delay < 0) retry = false;
                if (sr.http_code >= 500) availability_failure = true;
            } else if (send_rc == 0 && sr.curl_code != CURLE_OK && curl_pre_request_retryable(sr.curl_code)) {
                retry = true; reason = "pre-request-transport";
                delay = jitter_ms(exponential_backoff_ms(attempt_no));
                availability_failure = true;
            } else if (send_rc == 0 && sr.curl_code != CURLE_OK && curl_ambiguous(sr.curl_code)) {
                ambiguous = true; reason = "ambiguous-delivery";
            }

            if (availability_failure) circuit_record_failure(&job, true);
            else circuit_record_failure(&job, false);

            if (retry && attempt_no < UPSTREAM_MAX_ATTEMPTS) {
                int64_t due = realtime_ms() + delay;
                metric_record(METRIC_RETRY);
                log_msg(LOG_WARNING,
                        "event=JOB_RETRY version=%s worker=%u job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s "
                        "attempt=%u next_attempt=%u telegram_http=%ld curl_code=%d reason=%s backoff_ms=%ld",
                        PROGRAM_VERSION, worker_id, job.job_id, job.client_ip, job.listen_port, job.label,
                        job.endpoint, attempt_no, attempt_no + 1U, sr.http_code, (int)sr.curl_code, reason, delay);
                if (requeue_working(working_path, job.job_id, attempt_no, it.rate_limit_deferrals, due) != 0) {
                    log_msg(LOG_ERR, "event=SPOOL_REQUEUE_ERROR version=%s job_id=%s error=%s",
                            PROGRAM_VERSION, job.job_id, strerror(errno));
                    (void)fail_working_with_metadata(working_path, job.job_id,
                            attempt_no, it.rate_limit_deferrals, job.created_ms,
                            "requeue-error", sr.http_code, (int)sr.curl_code,
                            sr.telegram_description, ambiguous);
                }
            } else {
                char tg_error[1200], local_error[1200];
                metric_record(METRIC_FAILED);
                const char *tg_src = sr.telegram_description[0] ? sr.telegram_description : "none";
                const char *local_src = sr.error[0] ? sr.error : "none";
                audit_escape((const unsigned char *)tg_src, strlen(tg_src), tg_error, sizeof(tg_error));
                audit_escape((const unsigned char *)local_src, strlen(local_src), local_error, sizeof(local_error));
                log_msg(LOG_ERR,
                        "event=JOB_FAILED version=%s worker=%u job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s "
                        "attempt=%u telegram_http=%ld curl_code=%d reason=%s ambiguous=%s telegram_error=\"%s\" error=\"%s\"",
                        PROGRAM_VERSION, worker_id, job.job_id, job.client_ip, job.listen_port, job.label,
                        job.endpoint, attempt_no, sr.http_code, (int)sr.curl_code,
                        retry && attempt_no >= UPSTREAM_MAX_ATTEMPTS ? "max-attempts" : reason,
                        ambiguous ? "yes" : "no", tg_error, local_error);
                if (fail_working_with_metadata(working_path, job.job_id, attempt_no,
                        it.rate_limit_deferrals, job.created_ms,
                        retry && attempt_no >= UPSTREAM_MAX_ATTEMPTS ? "max-attempts" : reason,
                        sr.http_code, (int)sr.curl_code,
                        sr.telegram_description, ambiguous) != 0)
                    log_msg(LOG_ERR, "event=SPOOL_FAIL_MOVE_ERROR version=%s job_id=%s error=%s",
                            PROGRAM_VERSION, job.job_id, strerror(errno));
            }
        }
        free_spool_job(&job);
    }
    free(resp.data);
    curl_easy_cleanup(worker_curl);
    log_msg(LOG_NOTICE, "event=WORKER_STOP version=%s worker=%u", PROGRAM_VERSION, worker_id);
    return NULL;
}

static int get_peer_info(const struct sockaddr *sa, socklen_t salen,
                         char *ip, size_t ipsz, unsigned *port)
{
    char service[32];
    if (getnameinfo(sa, salen, ip, (socklen_t)ipsz, service, sizeof(service), NI_NUMERICHOST | NI_NUMERICSERV) != 0)
        return -1;
    *port = (unsigned)strtoul(service, NULL, 10);
    return 0;
}

static int create_listener(const char *bind_addr, int port)
{
    struct addrinfo hints, *res = NULL, *rp;
    char service[16];
    int fd = -1, yes = 1, rc;
    snprintf(service, sizeof(service), "%d", port);
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE; hints.ai_protocol = IPPROTO_TCP;
    rc = getaddrinfo(bind_addr, service, &hints, &res);
    if (rc != 0) { errno = EADDRNOTAVAIL; return -1; }
    for (rp = res; rp; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        if (bind(fd, rp->ai_addr, rp->ai_addrlen) == 0 && listen(fd, 128) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res); return fd;
}

static void send_health(int fd, struct channel *ch)
{
    char body[3600];
    char label_json[512], reason_json[MAINTENANCE_REASON_SIZE * 2U], actor_json[NI_MAXHOST * 2U];
    struct queue_summary q;
    struct runtime_metrics m;
    struct maintenance_snapshot ms;
    int level;
    int64_t oldest_pending_sec, oldest_failed_sec, last_success_age_sec, uptime_sec;
    int64_t maintenance_age_sec = 0, maintenance_remain_sec = -1;
    int64_t now = realtime_ms();
    int n;

    if (get_queue_summary(&q) != 0) {
        send_json_error(fd, 500, "cannot read spool health");
        return;
    }
    metrics_snapshot(&m);
    maintenance_get_snapshot(ch, &ms);
    level = health_level(&q);
    oldest_pending_sec = age_seconds_from_ms(q.pending.oldest_mtime_ms);
    oldest_failed_sec = age_seconds_from_ms(q.failed.oldest_mtime_ms);
    last_success_age_sec = m.last_success_ms > 0 ? age_seconds_from_ms(m.last_success_ms) : -1;
    uptime_sec = daemon_start_ms > 0 ? age_seconds_from_ms(daemon_start_ms) : 0;
    if (ms.on && ms.since_ms > 0 && now > ms.since_ms)
        maintenance_age_sec = (now - ms.since_ms) / 1000LL;
    if (ms.on && ms.expires_ms > 0)
        maintenance_remain_sec = ms.expires_ms > now ? (ms.expires_ms - now + 999LL) / 1000LL : 0;
    json_escape(ch->label, label_json, sizeof(label_json));
    json_escape(ms.reason, reason_json, sizeof(reason_json));
    json_escape(ms.enabled_by, actor_json, sizeof(actor_json));

    n = snprintf(body, sizeof(body),
        "{\"ok\":%s,\"status\":\"%s\",\"service\":\"tg_https_proxy\",\"mode\":\"persistent-queue\","
        "\"version\":\"%s\",\"port\":%d,\"label\":\"%s\",\"workers\":%d,\"uptime_sec\":%lld,"
        "\"maintenance\":{\"suppress\":%s,\"since_ms\":%lld,\"age_sec\":%lld,\"expires_ms\":%lld,"
        "\"ttl_remaining_sec\":%lld,\"reason\":\"%s\",\"enabled_by\":\"%s\",\"suppressed_count\":%llu},"
        "\"queue\":{\"pending\":%zu,\"working\":%zu,\"failed\":%zu,\"oldest_pending_sec\":%lld,\"oldest_failed_sec\":%lld},"
        "\"spool\":{\"bytes\":%llu,\"free_bytes\":%llu,\"max_bytes\":%llu,\"min_free_bytes\":%llu,"
        "\"max_pending_jobs\":%u,\"max_failed_jobs\":%u},"
        "\"runtime\":{\"enqueued_total\":%llu,\"sent_total\":%llu,\"failed_total\":%llu,"
        "\"retries_total\":%llu,\"rate_deferred_total\":%llu,\"telegram_429_deferred_total\":%llu,"
        "\"capacity_reject_total\":%llu,\"filtered_total\":%llu,\"suppressed_total\":%llu,"
        "\"maintenance_toggle_total\":%llu,\"maintenance_auto_expire_total\":%llu,"
        "\"maintenance_mark_total\":%llu,\"test_log_only_total\":%llu,"
        "\"maintenance_notice_sent_total\":%llu,\"maintenance_notice_pin_total\":%llu,"
        "\"maintenance_notice_fail_total\":%llu,\"last_success_age_sec\":%lld},"
        "\"channel_max_per_minute\":%ld,\"upstream_max_attempts\":%u,\"max_job_age_sec\":%lld}\n",
        level == 2 ? "false" : "true", level == 2 ? "critical" : level == 1 ? "degraded" : "healthy",
        PROGRAM_VERSION, ch->port, label_json, worker_count, (long long)uptime_sec,
        ms.on ? "true" : "false", (long long)ms.since_ms, (long long)maintenance_age_sec,
        (long long)ms.expires_ms, (long long)maintenance_remain_sec, reason_json, actor_json,
        (unsigned long long)ms.suppressed_count,
        q.pending.count, q.working.count, q.failed.count,
        (long long)oldest_pending_sec, (long long)oldest_failed_sec,
        q.total_bytes, q.free_bytes, (unsigned long long)MAX_SPOOL_BYTES,
        (unsigned long long)SPOOL_MIN_FREE_BYTES, MAX_PENDING_JOBS, MAX_FAILED_JOBS,
        (unsigned long long)m.enqueued_total, (unsigned long long)m.sent_total,
        (unsigned long long)m.failed_total, (unsigned long long)m.retries_total,
        (unsigned long long)m.rate_deferred_total,
        (unsigned long long)m.telegram_429_deferred_total,
        (unsigned long long)m.capacity_reject_total,
        (unsigned long long)m.filtered_total,
        (unsigned long long)m.suppressed_total,
        (unsigned long long)m.maintenance_toggle_total,
        (unsigned long long)m.maintenance_auto_expire_total,
        (unsigned long long)m.maintenance_mark_total,
        (unsigned long long)m.test_log_only_total,
        (unsigned long long)m.maintenance_notice_sent_total,
        (unsigned long long)m.maintenance_notice_pin_total,
        (unsigned long long)m.maintenance_notice_fail_total,
        (long long)last_success_age_sec,
        CHANNEL_MAX_PER_MINUTE, UPSTREAM_MAX_ATTEMPTS, (long long)MAX_JOB_AGE_SEC);
    if (n < 0) n = 0;
    if ((size_t)n >= sizeof(body)) n = (int)sizeof(body) - 1;
    (void)send_http_response(fd, 200, "application/json; charset=utf-8", body, (size_t)n);
}

static void send_live(int fd)
{
    char body[256];
    int n = snprintf(body, sizeof(body),
                     "{\"ok\":true,\"service\":\"tg_https_proxy\",\"version\":\"%s\",\"status\":\"alive\"}\n",
                     PROGRAM_VERSION);
    if (n < 0) n = 0;
    (void)send_http_response(fd, 200, "application/json; charset=utf-8", body, (size_t)n);
}

static void send_ready(int fd)
{
    struct queue_summary q;
    char body[512];
    int level, n;
    if (get_queue_summary(&q) != 0) {
        send_json_error(fd, 503, "spool unavailable");
        return;
    }
    level = health_level(&q);
    n = snprintf(body, sizeof(body),
                 "{\"ok\":%s,\"status\":\"%s\",\"pending\":%zu,\"working\":%zu,\"failed\":%zu,\"free_bytes\":%llu}\n",
                 level == 2 ? "false" : "true", level == 2 ? "critical" : level == 1 ? "degraded" : "ready",
                 q.pending.count, q.working.count, q.failed.count, q.free_bytes);
    if (n < 0) n = 0;
    (void)send_http_response(fd, level == 2 ? 503 : 200, "application/json; charset=utf-8", body, (size_t)n);
}

static void send_metrics(int fd)
{
    char body[4096];
    struct queue_summary q;
    struct runtime_metrics m;
    int64_t oldest_pending_sec, oldest_failed_sec, last_success_age_sec, uptime_sec;
    int n;
    if (get_queue_summary(&q) != 0) {
        send_http_response(fd, 500, "text/plain; charset=utf-8", "spool unavailable\n", 18);
        return;
    }
    metrics_snapshot(&m);
    oldest_pending_sec = age_seconds_from_ms(q.pending.oldest_mtime_ms);
    oldest_failed_sec = age_seconds_from_ms(q.failed.oldest_mtime_ms);
    last_success_age_sec = m.last_success_ms > 0 ? age_seconds_from_ms(m.last_success_ms) : -1;
    uptime_sec = daemon_start_ms > 0 ? age_seconds_from_ms(daemon_start_ms) : 0;
    n = snprintf(body, sizeof(body),
        "# TYPE tg_proxy_pending_jobs gauge\n"
        "tg_proxy_pending_jobs %zu\n"
        "# TYPE tg_proxy_working_jobs gauge\n"
        "tg_proxy_working_jobs %zu\n"
        "# TYPE tg_proxy_failed_jobs gauge\n"
        "tg_proxy_failed_jobs %zu\n"
        "tg_proxy_spool_bytes %llu\n"
        "tg_proxy_spool_free_bytes %llu\n"
        "tg_proxy_oldest_pending_seconds %lld\n"
        "tg_proxy_oldest_failed_seconds %lld\n"
        "tg_proxy_workers %d\n"
        "tg_proxy_uptime_seconds %lld\n"
        "# TYPE tg_proxy_messages_enqueued_total counter\n"
        "tg_proxy_messages_enqueued_total %llu\n"
        "# TYPE tg_proxy_messages_sent_total counter\n"
        "tg_proxy_messages_sent_total %llu\n"
        "# TYPE tg_proxy_messages_failed_total counter\n"
        "tg_proxy_messages_failed_total %llu\n"
        "# TYPE tg_proxy_retries_total counter\n"
        "tg_proxy_retries_total %llu\n"
        "# TYPE tg_proxy_rate_limit_deferred_total counter\n"
        "tg_proxy_rate_limit_deferred_total %llu\n"
        "# TYPE tg_proxy_telegram_429_deferred_total counter\n"
        "tg_proxy_telegram_429_deferred_total %llu\n"
        "# TYPE tg_proxy_capacity_reject_total counter\n"
        "tg_proxy_capacity_reject_total %llu\n"
        "# TYPE tg_proxy_messages_filtered_total counter\n"
        "tg_proxy_messages_filtered_total %llu\n"
        "# TYPE tg_proxy_messages_suppressed_total counter\n"
        "tg_proxy_messages_suppressed_total %llu\n"
        "# TYPE tg_proxy_maintenance_toggles_total counter\n"
        "tg_proxy_maintenance_toggles_total %llu\n"
        "# TYPE tg_proxy_maintenance_auto_expire_total counter\n"
        "tg_proxy_maintenance_auto_expire_total %llu\n"
        "# TYPE tg_proxy_maintenance_mark_total counter\n"
        "tg_proxy_maintenance_mark_total %llu\n"
        "# TYPE tg_proxy_test_log_only_total counter\n"
        "tg_proxy_test_log_only_total %llu\n"
        "# TYPE tg_proxy_maintenance_notice_sent_total counter\n"
        "tg_proxy_maintenance_notice_sent_total %llu\n"
        "# TYPE tg_proxy_maintenance_notice_pin_total counter\n"
        "tg_proxy_maintenance_notice_pin_total %llu\n"
        "# TYPE tg_proxy_maintenance_notice_fail_total counter\n"
        "tg_proxy_maintenance_notice_fail_total %llu\n"
        "# TYPE tg_proxy_maintenance_channels gauge\n"
        "tg_proxy_maintenance_channels %zu\n"
        "tg_proxy_last_success_age_seconds %lld\n",
        q.pending.count, q.working.count, q.failed.count,
        q.total_bytes, q.free_bytes,
        (long long)oldest_pending_sec, (long long)oldest_failed_sec,
        worker_count, (long long)uptime_sec,
        (unsigned long long)m.enqueued_total, (unsigned long long)m.sent_total,
        (unsigned long long)m.failed_total, (unsigned long long)m.retries_total,
        (unsigned long long)m.rate_deferred_total,
        (unsigned long long)m.telegram_429_deferred_total,
        (unsigned long long)m.capacity_reject_total,
        (unsigned long long)m.filtered_total,
        (unsigned long long)m.suppressed_total,
        (unsigned long long)m.maintenance_toggle_total,
        (unsigned long long)m.maintenance_auto_expire_total,
        (unsigned long long)m.maintenance_mark_total,
        (unsigned long long)m.test_log_only_total,
        (unsigned long long)m.maintenance_notice_sent_total,
        (unsigned long long)m.maintenance_notice_pin_total,
        (unsigned long long)m.maintenance_notice_fail_total,
        maintenance_active_channels(), (long long)last_success_age_sec);
    if (n < 0) n = 0;
    if ((size_t)n >= sizeof(body)) n = (int)sizeof(body) - 1;
    (void)send_http_response(fd, 200, "text/plain; version=0.0.4; charset=utf-8", body, (size_t)n);
}

static void ingest_done(void)
{
    pthread_mutex_lock(&ingest_mutex);
    if (ingest_threads > 0) ingest_threads--;
    pthread_cond_broadcast(&ingest_cond);
    pthread_mutex_unlock(&ingest_mutex);
}

static bool http_method_token_char(unsigned char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '!' || c == '#' || c == '$' ||
           c == '%' || c == '&' || c == '*' || c == '+' || c == '-' ||
           c == '.' || c == '^' || c == '_' || c == '`' || c == '|' ||
           c == '~';
}

static bool known_http_method_prefix(const unsigned char *data, size_t len)
{
    static const char *methods[] = {
        "GET ", "HEAD ", "POST ", "PUT ", "DELETE ",
        "CONNECT ", "OPTIONS ", "TRACE ", "PATCH "
    };
    size_t i, j;
    if (!data || len == 0U) return false;
    for (i = 0U; i < sizeof(methods) / sizeof(methods[0]); i++) {
        size_t mlen = strlen(methods[i]);
        size_t cmpn = len < mlen ? len : mlen;
        for (j = 0U; j < cmpn; j++) {
            unsigned char a = data[j];
            unsigned char b = (unsigned char)methods[i][j];
            if (tolower(a) != tolower(b)) break;
        }
        if (j == cmpn) return true;
    }
    return false;
}

static int proxy_protocol_parse_port(const char *s, unsigned *out)
{
    char *end = NULL;
    unsigned long v;
    if (!s || !*s || !out) return -1;
    errno = 0;
    v = strtoul(s, &end, 10);
    if (errno || end == s || *end != '\0' || v > 65535UL) return -1;
    *out = (unsigned)v;
    return 0;
}

/* Optional HAProxy PROXY protocol v1. When enabled, a trusted Host B can
 * prepend the original Host A address before either RAW data or HTTP. Direct
 * clients without a PROXY line remain compatible. The direct peer is still
 * retained separately for audit and should be restricted with -a in
 * production so an untrusted client cannot spoof an original source address.
 */
static int proxy_protocol_maybe_consume(struct ingest_ctx *ctx, int64_t deadline_ms)
{
    unsigned char probe[6];
    char line[108];
    size_t used = 0U;

    if (!ctx || !proxy_protocol_v1_enabled) return 0;

    for (;;) {
        ssize_t n;
        size_t i, cmp;
        do { n = recv(ctx->fd, probe, sizeof(probe), MSG_PEEK | MSG_DONTWAIT); }
        while (n < 0 && errno == EINTR);
        if (n == 0) return 0;
        if (n > 0) {
            cmp = (size_t)n < sizeof(probe) ? (size_t)n : sizeof(probe);
            for (i = 0U; i < cmp; i++) {
                if (probe[i] != (unsigned char)"PROXY "[i]) return 0;
            }
            if ((size_t)n >= sizeof(probe)) break;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            return -1;
        }
        {
            int64_t remain = deadline_ms - monotonic_ms();
            struct pollfd pfd;
            int prc;
            if (remain <= 0) { errno = ETIMEDOUT; return -1; }
            if (remain > 250) remain = 250;
            memset(&pfd, 0, sizeof(pfd));
            pfd.fd = ctx->fd; pfd.events = POLLIN;
            do { prc = poll(&pfd, 1, (int)remain); } while (prc < 0 && errno == EINTR);
            if (prc < 0) return -1;
        }
    }

    while (used + 1U < sizeof(line)) {
        unsigned char c;
        ssize_t n = recv_deadline(ctx->fd, &c, 1U, 0, deadline_ms);
        if (n != 1) return -1;
        line[used++] = (char)c;
        if (used >= 2U && line[used - 2U] == '\r' && line[used - 1U] == '\n') {
            char copy[108], *save = NULL;
            char *magic, *proto, *src, *dst, *sport, *dport, *extra;
            unsigned src_port = 0U, dst_port = 0U;
            int af;
            unsigned char addrbuf[16];

            line[used - 2U] = '\0';
            snprintf(copy, sizeof(copy), "%s", line);
            magic = strtok_r(copy, " ", &save);
            proto = strtok_r(NULL, " ", &save);
            if (!magic || !proto || strcmp(magic, "PROXY") != 0) return -2;
            if (strcmp(proto, "UNKNOWN") == 0) {
                ctx->proxy_protocol_used = true;
                log_msg(LOG_NOTICE,
                        "event=PROXY_PROTOCOL_ACCEPT version=%s proxy_ip=%s proxy_port=%u family=UNKNOWN effective_client_ip=%s",
                        PROGRAM_VERSION, ctx->peer_ip, ctx->peer_port, ctx->client_ip);
                return 1;
            }
            src = strtok_r(NULL, " ", &save);
            dst = strtok_r(NULL, " ", &save);
            sport = strtok_r(NULL, " ", &save);
            dport = strtok_r(NULL, " ", &save);
            extra = strtok_r(NULL, " ", &save);
            if (!src || !dst || !sport || !dport || extra) return -2;
            if (strcmp(proto, "TCP4") == 0) af = AF_INET;
            else if (strcmp(proto, "TCP6") == 0) af = AF_INET6;
            else return -2;
            if (inet_pton(af, src, addrbuf) != 1 || inet_pton(af, dst, addrbuf) != 1 ||
                proxy_protocol_parse_port(sport, &src_port) != 0 ||
                proxy_protocol_parse_port(dport, &dst_port) != 0)
                return -2;
            (void)dst_port;
            if (strlen(src) >= sizeof(ctx->client_ip)) return -2;
            snprintf(ctx->client_ip, sizeof(ctx->client_ip), "%s", src);
            ctx->client_port = src_port;
            ctx->proxy_protocol_used = true;
            log_msg(LOG_NOTICE,
                    "event=PROXY_PROTOCOL_ACCEPT version=%s proxy_ip=%s proxy_port=%u original_client_ip=%s original_client_port=%u family=%s",
                    PROGRAM_VERSION, ctx->peer_ip, ctx->peer_port,
                    ctx->client_ip, ctx->client_port, proto);
            return 1;
        }
    }
    errno = EMSGSIZE;
    return -2;
}

static int raw_message_available(int fd)
{
    unsigned char probe[64];
    int64_t deadline = monotonic_ms() + PROTOCOL_DETECT_TIMEOUT_MS;

    for (;;) {
        ssize_t n;
        bool possible_http = false;
        size_t i;

        do {
            n = recv(fd, probe, sizeof(probe), MSG_PEEK | MSG_DONTWAIT);
        } while (n < 0 && errno == EINTR);

        if (n == 0) return 1;
        if (n > 0) {
            size_t nn = (size_t)n;
            size_t sp = nn;

            /* Once METHOD + SP + / is visible, fail closed into the HTTP
             * parser even for an unknown method such as FOO or PROPFIND. */
            for (i = 0U; i < nn; i++) {
                if (probe[i] == ' ') { sp = i; break; }
            }
            if (sp < nn) {
                bool valid_method = sp > 0U && sp <= 15U;
                for (i = 0U; valid_method && i < sp; i++)
                    if (!http_method_token_char(probe[i])) valid_method = false;
                if (valid_method && sp + 1U < nn)
                    return probe[sp + 1U] == '/' ? 0 : 1;
                possible_http = valid_method && known_http_method_prefix(probe, nn);
            } else {
                /* Do not delay ordinary short RAW text such as `printf test`.
                 * Wait only while the bytes are still a prefix of a known
                 * HTTP method; unknown METHOD / requests are caught above as
                 * soon as their space and slash arrive. */
                possible_http = known_http_method_prefix(probe, nn);
            }
            if (!possible_http) return 1;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
            return -1;
        }

        {
            int64_t remain = deadline - monotonic_ms();
            struct pollfd pfd;
            int prc;
            if (remain <= 0) return 1;
            if (remain > 250) remain = 250;
            memset(&pfd, 0, sizeof(pfd));
            pfd.fd = fd;
            pfd.events = POLLIN;
            do { prc = poll(&pfd, 1, (int)remain); } while (prc < 0 && errno == EINTR);
            if (prc < 0) return -1;
        }
    }
}

static uint16_t read_le16(const unsigned char *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static bool zip_entry_name_has_prefix(const unsigned char *data, size_t len,
                                      const char *prefix)
{
    size_t i, prefix_len;

    if (!data || !prefix) return false;
    prefix_len = strlen(prefix);
    if (prefix_len == 0 || len < 30U) return false;

    /*
     * Prefer ZIP central-directory entries (PK 01 02). File names in the
     * central directory are stored uncompressed, which lets us distinguish
     * OOXML containers without decompressing the archive. Fall back to local
     * file headers (PK 03 04) for unusual/truncated-but-complete inputs.
     */
    for (i = 0; i + 46U <= len; i++) {
        size_t name_len;
        const unsigned char *name;
        if (memcmp(data + i, "PK\x01\x02", 4) != 0) continue;
        name_len = read_le16(data + i + 28U);
        if (i + 46U + name_len > len) continue;
        name = data + i + 46U;
        if (name_len >= prefix_len && memcmp(name, prefix, prefix_len) == 0)
            return true;
    }

    for (i = 0; i + 30U <= len; i++) {
        size_t name_len;
        const unsigned char *name;
        if (memcmp(data + i, "PK\x03\x04", 4) != 0) continue;
        name_len = read_le16(data + i + 26U);
        if (i + 30U + name_len > len) continue;
        name = data + i + 30U;
        if (name_len >= prefix_len && memcmp(name, prefix, prefix_len) == 0)
            return true;
    }
    return false;
}

static bool looks_like_json_text(const unsigned char *data, size_t len)
{
    size_t begin = 0, end = len, i;
    int object_depth = 0, array_depth = 0;
    bool in_string = false, escaped = false;

    if (!data || len == 0) return false;
    if (len >= 3U && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf)
        begin = 3U;
    while (begin < end && isspace((unsigned char)data[begin])) begin++;
    while (end > begin && isspace((unsigned char)data[end - 1U])) end--;
    if (begin >= end) return false;
    if (!((data[begin] == '{' && data[end - 1U] == '}') ||
          (data[begin] == '[' && data[end - 1U] == ']'))) return false;

    for (i = begin; i < end; i++) {
        unsigned char c = data[i];
        if (in_string) {
            if (escaped) { escaped = false; continue; }
            if (c == '\\') { escaped = true; continue; }
            if (c == '"') { in_string = false; continue; }
            if (c < 0x20) return false;
            continue;
        }
        if (c == '"') { in_string = true; continue; }
        if (c == '{') object_depth++;
        else if (c == '}') { if (--object_depth < 0) return false; }
        else if (c == '[') array_depth++;
        else if (c == ']') { if (--array_depth < 0) return false; }
        else if (c < 0x20 && !isspace(c)) return false;
    }
    return !in_string && !escaped && object_depth == 0 && array_depth == 0;
}

static size_t csv_delimiter_count(const unsigned char *line, size_t len,
                                  unsigned char delim)
{
    size_t i, count = 0;
    bool quoted = false;
    for (i = 0; i < len; i++) {
        unsigned char c = line[i];
        if (c == '"') {
            if (quoted && i + 1U < len && line[i + 1U] == '"') { i++; continue; }
            quoted = !quoted;
        } else if (!quoted && c == delim) {
            count++;
        }
    }
    return quoted ? 0U : count;
}

static bool looks_like_csv_text(const unsigned char *data, size_t len)
{
    static const unsigned char delimiters[] = { ',', '\t', ';' };
    size_t d;

    if (!data || len == 0) return false;
    for (d = 0; d < sizeof(delimiters); d++) {
        size_t pos = 0, expected = 0, useful_lines = 0;
        bool mismatch = false;

        while (pos < len && useful_lines < 5U) {
            size_t start = pos, end, count;
            while (pos < len && data[pos] != '\n' && data[pos] != '\r') pos++;
            end = pos;
            while (pos < len && (data[pos] == '\n' || data[pos] == '\r')) pos++;
            while (start < end && isspace((unsigned char)data[start])) start++;
            while (end > start && isspace((unsigned char)data[end - 1U])) end--;
            if (start == end) continue;
            count = csv_delimiter_count(data + start, end - start, delimiters[d]);
            if (count == 0) { mismatch = true; break; }
            if (useful_lines == 0) expected = count;
            else if (count != expected) { mismatch = true; break; }
            useful_lines++;
        }
        if (!mismatch && useful_lines >= 2U && expected > 0U) return true;
    }
    return false;
}

/* Validate UTF-8 and count Unicode code points. Telegram documents the
 * sendMessage limit in characters, not input bytes. This deliberately does
 * not attempt to interpret Markdown/HTML entities.
 */
static int utf8_count_chars(const unsigned char *data, size_t len, size_t *chars)
{
    size_t i = 0U, count = 0U;

    if (!data || !chars) return -1;
    while (i < len) {
        size_t seq = utf8_sequence_len(data + i, len - i);
        if (seq == 0U) return -1;
        i += seq;
        count++;
    }
    *chars = count;
    return 0;
}

static bool looks_like_shell_script(const unsigned char *data, size_t len)
{
    size_t end, i;
    char line[256];

    if (!data || len < 3U || data[0] != '#' || data[1] != '!') return false;
    end = 2U;
    while (end < len && end < sizeof(line) - 1U &&
           data[end] != '\n' && data[end] != '\r')
        end++;
    if (end <= 2U) return false;
    for (i = 0; i < end && i < sizeof(line) - 1U; i++)
        line[i] = (char)tolower((unsigned char)data[i]);
    line[i] = '\0';

    return strstr(line, "bash") != NULL ||
           strstr(line, "ksh") != NULL ||
           strstr(line, "zsh") != NULL ||
           strstr(line, "/sh") != NULL ||
           strstr(line, "env sh") != NULL;
}


static bool buffer_contains_utf16le_ascii(const unsigned char *data, size_t len,
                                          const char *ascii)
{
    size_t i, j, alen;

    if (!data || !ascii) return false;
    alen = strlen(ascii);
    if (alen == 0U || len < alen * 2U) return false;

    for (i = 0U; i + alen * 2U <= len; i++) {
        for (j = 0U; j < alen; j++) {
            if (data[i + j * 2U] != (unsigned char)ascii[j] ||
                data[i + j * 2U + 1U] != 0U)
                break;
        }
        if (j == alen) return true;
    }
    return false;
}

static bool looks_like_ole_cfb(const unsigned char *data, size_t len)
{
    static const unsigned char magic[8] = {
        0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1
    };
    return data && len >= sizeof(magic) && memcmp(data, magic, sizeof(magic)) == 0;
}

static bool ascii_prefix_nocase(const unsigned char *data, size_t len,
                                const char *prefix)
{
    size_t i, plen;
    if (!data || !prefix) return false;
    plen = strlen(prefix);
    if (len < plen) return false;
    for (i = 0U; i < plen; i++) {
        if (tolower((unsigned char)data[i]) !=
            tolower((unsigned char)prefix[i]))
            return false;
    }
    return true;
}

static bool ascii_contains_nocase(const unsigned char *data, size_t len,
                                  const char *needle)
{
    size_t i, j, nlen;
    if (!data || !needle) return false;
    nlen = strlen(needle);
    if (nlen == 0U || len < nlen) return false;
    for (i = 0U; i + nlen <= len; i++) {
        for (j = 0U; j < nlen; j++) {
            if (tolower((unsigned char)data[i + j]) !=
                tolower((unsigned char)needle[j]))
                break;
        }
        if (j == nlen) return true;
    }
    return false;
}

static void trim_text_bounds(const unsigned char *data, size_t len,
                             size_t *begin, size_t *end)
{
    size_t b = 0U, e = len;
    if (len >= 3U && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf)
        b = 3U;
    while (b < e && isspace((unsigned char)data[b])) b++;
    while (e > b && isspace((unsigned char)data[e - 1U])) e--;
    *begin = b;
    *end = e;
}

static bool looks_like_html_text(const unsigned char *data, size_t len)
{
    size_t begin, end, scan;
    const unsigned char *p;

    if (!data || len == 0U) return false;
    trim_text_bounds(data, len, &begin, &end);
    if (begin >= end) return false;
    p = data + begin;
    scan = end - begin;
    if (scan > 4096U) scan = 4096U;

    if (ascii_prefix_nocase(p, scan, "<!doctype html") ||
        ascii_prefix_nocase(p, scan, "<html") ||
        ascii_prefix_nocase(p, scan, "<head") ||
        ascii_prefix_nocase(p, scan, "<body"))
        return true;

    /* Accept a leading comment/XML declaration only when a real HTML
     * document marker is also present near the beginning. */
    if ((ascii_prefix_nocase(p, scan, "<!--") ||
         ascii_prefix_nocase(p, scan, "<?xml")) &&
        ascii_contains_nocase(p, scan, "<html"))
        return true;

    return false;
}

static bool line_has_log_signature(const unsigned char *line, size_t len)
{
    size_t i = 0U, scan;

    while (i < len && isspace((unsigned char)line[i])) i++;
    if (i >= len) return false;
    line += i;
    len -= i;
    scan = len > 160U ? 160U : len;

    /* ISO-like dates: 2026-09-08 / 2026/09/08. */
    if (scan >= 10U &&
        isdigit(line[0]) && isdigit(line[1]) &&
        isdigit(line[2]) && isdigit(line[3]) &&
        (line[4] == '-' || line[4] == '/') &&
        isdigit(line[5]) && isdigit(line[6]) &&
        (line[7] == '-' || line[7] == '/') &&
        isdigit(line[8]) && isdigit(line[9]))
        return true;

    /* Bracketed ISO timestamp: [2026-09-08 ...]. */
    if (scan >= 11U && line[0] == '[' &&
        isdigit(line[1]) && isdigit(line[2]) &&
        isdigit(line[3]) && isdigit(line[4]) && line[5] == '-' &&
        isdigit(line[6]) && isdigit(line[7]) && line[8] == '-' &&
        isdigit(line[9]) && isdigit(line[10]))
        return true;

    /* Traditional syslog month/day prefix. */
    if (scan >= 4U &&
        ((ascii_prefix_nocase(line, scan, "jan ")) ||
         (ascii_prefix_nocase(line, scan, "feb ")) ||
         (ascii_prefix_nocase(line, scan, "mar ")) ||
         (ascii_prefix_nocase(line, scan, "apr ")) ||
         (ascii_prefix_nocase(line, scan, "may ")) ||
         (ascii_prefix_nocase(line, scan, "jun ")) ||
         (ascii_prefix_nocase(line, scan, "jul ")) ||
         (ascii_prefix_nocase(line, scan, "aug ")) ||
         (ascii_prefix_nocase(line, scan, "sep ")) ||
         (ascii_prefix_nocase(line, scan, "oct ")) ||
         (ascii_prefix_nocase(line, scan, "nov ")) ||
         (ascii_prefix_nocase(line, scan, "dec "))))
        return true;

    if (ascii_contains_nocase(line, scan, " error ") ||
        ascii_contains_nocase(line, scan, " warning ") ||
        ascii_contains_nocase(line, scan, " warn ") ||
        ascii_contains_nocase(line, scan, " info ") ||
        ascii_contains_nocase(line, scan, " debug ") ||
        ascii_contains_nocase(line, scan, " fatal ") ||
        ascii_contains_nocase(line, scan, "event="))
        return true;

    return false;
}

static bool looks_like_log_text(const unsigned char *data, size_t len)
{
    size_t pos = 0U, nonempty = 0U, matched = 0U;

    if (!data || len == 0U) return false;
    while (pos < len && nonempty < 12U) {
        size_t start = pos, end;
        while (pos < len && data[pos] != '\n' && data[pos] != '\r') pos++;
        end = pos;
        while (pos < len && (data[pos] == '\n' || data[pos] == '\r')) pos++;
        while (start < end && isspace((unsigned char)data[start])) start++;
        while (end > start && isspace((unsigned char)data[end - 1U])) end--;
        if (start == end) continue;
        nonempty++;
        if (line_has_log_signature(data + start, end - start)) matched++;
    }
    return nonempty >= 2U && matched >= 2U && matched * 2U >= nonempty;
}

static bool raw_looks_binary(const unsigned char *p, size_t n)
{
    size_t i, control = 0;
    if (!p || n == 0) return false;

    /* Known binary/archive signatures. */
    if (n >= 5 && memcmp(p, "%PDF-", 5) == 0) return true;
    if (n >= 8 && memcmp(p, "\x89PNG\r\n\x1a\n", 8) == 0) return true;
    if (n >= 3 && p[0] == 0xff && p[1] == 0xd8 && p[2] == 0xff) return true;
    if (n >= 4 && memcmp(p, "PK\x03\x04", 4) == 0) return true;
    if (looks_like_ole_cfb(p, n)) return true;
    if (n >= 2 && p[0] == 0x1f && p[1] == 0x8b) return true; /* gzip */
    if (n >= 6 && memcmp(p, "\x37\x7a\xbc\xaf\x27\x1c", 6) == 0) return true; /* 7z */
    if (n >= 7 && memcmp(p, "Rar!\x1a\x07\x00", 7) == 0) return true; /* RAR4 */
    if (n >= 8 && memcmp(p, "Rar!\x1a\x07\x01\x00", 8) == 0) return true; /* RAR5 */
    if (n >= 262U && memcmp(p + 257U, "ustar", 5) == 0) return true; /* tar */

    for (i = 0; i < n; i++) {
        unsigned char c = p[i];
        if (c == 0 || (c < 0x09) || (c > 0x0d && c < 0x20) || c == 0x7f) control++;
    }
    return control > n / 100U || control >= 8U;
}

static void classify_raw_request(struct http_request *req)
{
    const unsigned char *p;
    size_t n;

    if (!req || !req->body || req->content_length == 0) return;
    p = req->body;
    n = req->content_length;

    /* PNG/JPEG are native Telegram photos. */
    if (n >= 8U && memcmp(p, "\x89PNG\r\n\x1a\n", 8) == 0) {
        snprintf(req->path, sizeof(req->path), "/sendPhoto");
        snprintf(req->content_type, sizeof(req->content_type), "image/png");
        snprintf(req->filename, sizeof(req->filename), "upload.png");
        return;
    }
    if (n >= 3U && p[0] == 0xff && p[1] == 0xd8 && p[2] == 0xff) {
        snprintf(req->path, sizeof(req->path), "/sendPhoto");
        snprintf(req->content_type, sizeof(req->content_type), "image/jpeg");
        snprintf(req->filename, sizeof(req->filename), "upload.jpg");
        return;
    }

    /* PDF and common archive/document containers use sendDocument. */
    if (n >= 5U && memcmp(p, "%PDF-", 5) == 0) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        snprintf(req->content_type, sizeof(req->content_type), "application/pdf");
        snprintf(req->filename, sizeof(req->filename), "upload.pdf");
        return;
    }
    if (n >= 2U && p[0] == 0x1f && p[1] == 0x8b) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        snprintf(req->content_type, sizeof(req->content_type), "application/gzip");
        snprintf(req->filename, sizeof(req->filename), "upload.gz");
        return;
    }
    if (n >= 262U && memcmp(p + 257U, "ustar", 5) == 0) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        snprintf(req->content_type, sizeof(req->content_type), "application/x-tar");
        snprintf(req->filename, sizeof(req->filename), "upload.tar");
        return;
    }
    if (n >= 6U && memcmp(p, "\x37\x7a\xbc\xaf\x27\x1c", 6) == 0) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        snprintf(req->content_type, sizeof(req->content_type), "application/x-7z-compressed");
        snprintf(req->filename, sizeof(req->filename), "upload.7z");
        return;
    }
    if ((n >= 7U && memcmp(p, "Rar!\x1a\x07\x00", 7) == 0) ||
        (n >= 8U && memcmp(p, "Rar!\x1a\x07\x01\x00", 8) == 0)) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        snprintf(req->content_type, sizeof(req->content_type), "application/vnd.rar");
        snprintf(req->filename, sizeof(req->filename), "upload.rar");
        return;
    }


    /* Legacy Microsoft Office binary formats share the OLE/CFBF container
     * signature. Distinguish them using well-known compound-file stream
     * names stored as UTF-16LE directory entries. */
    if (looks_like_ole_cfb(p, n)) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        if (buffer_contains_utf16le_ascii(p, n, "WordDocument")) {
            snprintf(req->content_type, sizeof(req->content_type), "application/msword");
            snprintf(req->filename, sizeof(req->filename), "upload.doc");
        } else if (buffer_contains_utf16le_ascii(p, n, "Workbook") ||
                   buffer_contains_utf16le_ascii(p, n, "Book")) {
            snprintf(req->content_type, sizeof(req->content_type), "application/vnd.ms-excel");
            snprintf(req->filename, sizeof(req->filename), "upload.xls");
        } else if (buffer_contains_utf16le_ascii(p, n, "PowerPoint Document")) {
            snprintf(req->content_type, sizeof(req->content_type), "application/vnd.ms-powerpoint");
            snprintf(req->filename, sizeof(req->filename), "upload.ppt");
        } else {
            snprintf(req->content_type, sizeof(req->content_type), "application/x-ole-storage");
            snprintf(req->filename, sizeof(req->filename), "upload.ole");
        }
        return;
    }

    if (n >= 4U && memcmp(p, "PK\x03\x04", 4) == 0) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        if (zip_entry_name_has_prefix(p, n, "word/")) {
            snprintf(req->content_type, sizeof(req->content_type),
                     "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
            snprintf(req->filename, sizeof(req->filename), "upload.docx");
        } else if (zip_entry_name_has_prefix(p, n, "xl/")) {
            snprintf(req->content_type, sizeof(req->content_type),
                     "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
            snprintf(req->filename, sizeof(req->filename), "upload.xlsx");
        } else if (zip_entry_name_has_prefix(p, n, "ppt/")) {
            snprintf(req->content_type, sizeof(req->content_type),
                     "application/vnd.openxmlformats-officedocument.presentationml.presentation");
            snprintf(req->filename, sizeof(req->filename), "upload.pptx");
        } else {
            snprintf(req->content_type, sizeof(req->content_type), "application/zip");
            snprintf(req->filename, sizeof(req->filename), "upload.zip");
        }
        return;
    }

    /* UTF-16 BOM is a strong text-file signature. Keep the original bytes and
     * upload them as a document rather than trying to transcode the payload. */
    if (n >= 2U && p[0] == 0xff && p[1] == 0xfe) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        snprintf(req->content_type, sizeof(req->content_type), "text/plain; charset=utf-16le");
        snprintf(req->filename, sizeof(req->filename), "upload.txt");
        return;
    }
    if (n >= 2U && p[0] == 0xfe && p[1] == 0xff) {
        snprintf(req->path, sizeof(req->path), "/sendDocument");
        snprintf(req->content_type, sizeof(req->content_type), "text/plain; charset=utf-16be");
        snprintf(req->filename, sizeof(req->filename), "upload.txt");
        return;
    }

    /* Structured/plain text that can be distinguished without a filename. */
    if (!raw_looks_binary(p, n)) {
        size_t chars = 0;

        if (looks_like_shell_script(p, n)) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "text/x-shellscript; charset=utf-8");
            snprintf(req->filename, sizeof(req->filename), "upload.sh");
            return;
        }
        if (looks_like_json_text(p, n)) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "application/json");
            snprintf(req->filename, sizeof(req->filename), "upload.json");
            return;
        }
        if (looks_like_html_text(p, n)) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "text/html; charset=utf-8");
            snprintf(req->filename, sizeof(req->filename), "upload.html");
            return;
        }
        if (looks_like_csv_text(p, n)) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "text/csv; charset=utf-8");
            snprintf(req->filename, sizeof(req->filename), "upload.csv");
            return;
        }
        if (looks_like_log_text(p, n)) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "text/plain; charset=utf-8");
            snprintf(req->filename, sizeof(req->filename), "upload.log");
            return;
        }
        /* A UTF-8 BOM is a strong file/document signal even when the text is
         * a single short line, unlike an ordinary raw chat message. */
        if (n >= 3U && p[0] == 0xef && p[1] == 0xbb && p[2] == 0xbf) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "text/plain; charset=utf-8");
            snprintf(req->filename, sizeof(req->filename), "upload.txt");
            return;
        }
        if (utf8_count_chars(p, n, &chars) != 0) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "application/octet-stream");
            snprintf(req->filename, sizeof(req->filename), "upload.bin");
            return;
        }
        /* RAW plain-text compatibility rule:
         * - any valid UTF-8 plain text, including Traditional Chinese and
         *   multiple lines from `cat file.txt | nc`, is sent as sendMessage
         *   while it fits Telegram's 4096-character limit.
         * - structured file types above (HTML/CSV/LOG/JSON/shell) still keep
         *   their explicit sendDocument classification.
         */
        if (chars > TELEGRAM_SENDMESSAGE_MAX_CHARS) {
            snprintf(req->path, sizeof(req->path), "/sendDocument");
            snprintf(req->content_type, sizeof(req->content_type), "text/plain; charset=utf-8");
            snprintf(req->filename, sizeof(req->filename), "upload.txt");
            return;
        }

        snprintf(req->path, sizeof(req->path), "/sendMessage");
        snprintf(req->content_type, sizeof(req->content_type), "text/plain; charset=utf-8");
        req->filename[0] = '\0';
        return;
    }

    /* Unknown binary is preserved as a generic Telegram document. */
    snprintf(req->path, sizeof(req->path), "/sendDocument");
    snprintf(req->content_type, sizeof(req->content_type), "application/octet-stream");
    snprintf(req->filename, sizeof(req->filename), "upload.bin");
}

static int read_raw_message(int fd, struct http_request *req, int64_t deadline_ms)
{
    size_t cap = 4096, used = 0;
    unsigned char *body = malloc(cap);
    if (!body) return -1;
    memset(req, 0, sizeof(*req));
    snprintf(req->method, sizeof(req->method), "RAW");
    snprintf(req->path, sizeof(req->path), "/sendMessage");
    snprintf(req->version, sizeof(req->version), "RAW/1");
    snprintf(req->content_type, sizeof(req->content_type), "text/plain; charset=utf-8");

    for (;;) {
        if (used == cap) {
            size_t nc = cap * 2U;
            unsigned char *tmp;
            if (nc > MAX_REQUEST_BODY) nc = MAX_REQUEST_BODY;
            if (nc <= cap) { free(body); return -4; }
            tmp = realloc(body, nc);
            if (!tmp) { free(body); return -1; }
            body = tmp; cap = nc;
        }
        ssize_t n = recv_deadline(fd, body + used, cap - used, 0, deadline_ms);
        if (n > 0) { used += (size_t)n; continue; }
        if (n == 0) break;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        if (errno == ETIMEDOUT) { free(body); return -7; }
        free(body); return -3;
    }
    if (used == 0) { free(body); return -2; }
    {
        unsigned char *tmp = realloc(body, used + 1U);
        if (!tmp) { free(body); return -1; }
        req->body = tmp;
    }
    req->body[used] = '\0';
    req->content_length = used;
    return 0;
}

static bool contains_percent_encoded_nul(const unsigned char *data, size_t len)
{
    size_t i;
    if (!data) return false;
    for (i = 0U; i + 2U < len; i++) {
        if (data[i] == '%' && data[i + 1U] == '0' && data[i + 2U] == '0')
            return true;
    }
    return false;
}

static int validate_caption_text(const char *caption, const char **why)
{
    size_t chars = 0U;
    if (why) *why = NULL;
    if (!caption || !*caption) return 0;
    if (utf8_count_chars((const unsigned char *)caption, strlen(caption), &chars) != 0) {
        if (why) *why = "caption is not valid UTF-8";
        return -1;
    }
    if (chars > TELEGRAM_CAPTION_MAX_CHARS) {
        if (why) *why = "caption exceeds Telegram 1024 character limit";
        return -1;
    }
    return 0;
}

static bool sendphoto_magic_matches(const struct http_request *req)
{
    if (!req || !req->body) return false;
    if (strncasecmp(req->content_type, "image/png", 9) == 0)
        return req->content_length >= 8U &&
               memcmp(req->body, "\x89PNG\r\n\x1a\n", 8) == 0;
    if (strncasecmp(req->content_type, "image/jpeg", 10) == 0 ||
        strncasecmp(req->content_type, "image/jpg", 9) == 0)
        return req->content_length >= 3U && req->body[0] == 0xffU &&
               req->body[1] == 0xd8U && req->body[2] == 0xffU;
    return false;
}

static int validate_explicit_send_message(const struct http_request *req,
                                          size_t *char_count,
                                          const char **why)
{
    const unsigned char *text_data = NULL;
    size_t text_len = 0, chars = 0;
    char *form_text = NULL;
    bool is_form;
    int rc = -1;

    if (!req || !char_count || !why) return -1;
    *char_count = 0;
    *why = "invalid sendMessage";
    is_form = strncasecmp(req->content_type,
                          "application/x-www-form-urlencoded", 33) == 0;
    if (req->body && memchr(req->body, '\0', req->content_length) != NULL) {
        *why = "sendMessage contains a NUL byte";
        goto out;
    }
    if (is_form && contains_percent_encoded_nul(req->body, req->content_length)) {
        *why = "sendMessage contains percent-encoded NUL (%00)";
        goto out;
    }
    if (is_form) {
        form_text = form_get_value(req->body, req->content_length, "text");
        if (!form_text || !*form_text) {
            *why = "sendMessage form field 'text' is required";
            goto out;
        }
        text_data = (const unsigned char *)form_text;
        text_len = strlen(form_text);
    } else {
        if (!req->body || req->content_length == 0) {
            *why = "message body is empty";
            goto out;
        }
        text_data = req->body;
        text_len = req->content_length;
    }
    if (utf8_count_chars(text_data, text_len, &chars) != 0) {
        *why = "sendMessage text is not valid UTF-8";
        goto out;
    }
    *char_count = chars;
    if (chars > TELEGRAM_SENDMESSAGE_MAX_CHARS) {
        *why = "sendMessage exceeds Telegram 4096 character limit; use /sendDocument";
        rc = 1;
        goto out;
    }
    rc = 0;
out:
    free(form_text);
    return rc;
}

static void *ingest_main(void *arg)
{
    struct ingest_ctx *ctx = arg;
    struct http_request req;
    int rc;
    char job_id[JOB_ID_SIZE] = "";
    int64_t request_start_ms = monotonic_ms();

    (void)set_socket_timeouts(ctx->fd, CLIENT_IO_TIMEOUT_SEC);
    rc = proxy_protocol_maybe_consume(ctx, request_start_ms + HTTP_HEADER_DEADLINE_MS);
    if (rc < 0) {
        send_json_error(ctx->fd, rc == -2 ? 400 : 408,
                        rc == -2 ? "invalid PROXY protocol v1 header" : "PROXY protocol deadline exceeded");
        log_msg(LOG_WARNING,
                "event=PROXY_PROTOCOL_REJECT version=%s proxy_ip=%s proxy_port=%u error=%s",
                PROGRAM_VERSION, ctx->peer_ip, ctx->peer_port,
                rc == -2 ? "malformed" : "timeout-or-read-error");
        close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    rc = raw_message_available(ctx->fd);
    if (rc < 0) {
        send_json_error(ctx->fd, 400, "protocol detection failed");
        close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (rc > 0) {
        rc = read_raw_message(ctx->fd, &req, request_start_ms + REQUEST_TOTAL_DEADLINE_MS);
        if (rc == -2) { close(ctx->fd); free(ctx); ingest_done(); return NULL; }
        if (rc != 0) {
            send_json_error(ctx->fd, rc == -4 ? 413 : rc == -7 ? 408 : 400,
                            rc == -4 ? "raw message too large" :
                            rc == -7 ? "raw request deadline exceeded" : "raw message read failed");
            close(ctx->fd); free(ctx); ingest_done(); return NULL;
        }
        classify_raw_request(&req);
        if (strcmp(req.path, "/sendMessage") == 0 && http_compat_text_query) {
            int drc = 0;
            bool use_html = compat_text_needs_html(req.body, req.content_length);
            if (http_compat_auto_urlencode) {
                drc = decode_raw_percent_compat(&req);
                if (drc < 0) {
                    send_json_error(ctx->fd, 500, "raw compatibility decode failed");
                    free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
                }
                if (drc > 0)
                    use_html = use_html || compat_text_needs_html(req.body, req.content_length);
            }
            if (use_html && !req.parse_mode[0])
                snprintf(req.parse_mode, sizeof(req.parse_mode), "HTML");
            {
                size_t raw_chars = 0U;
                const char *raw_why = NULL;
                int vrc = validate_explicit_send_message(&req, &raw_chars, &raw_why);
                if (vrc != 0) {
                    send_json_error(ctx->fd, vrc > 0 ? 413 : 400,
                                    raw_why ? raw_why : "invalid raw sendMessage");
                    log_msg(LOG_WARNING,
                            "event=RAW_SENDMESSAGE_REJECT version=%s client_ip=%s listen_port=%d chars=%zu reason=\"%s\"",
                            PROGRAM_VERSION, ctx->client_ip, ctx->ch->port, raw_chars,
                            raw_why ? raw_why : "invalid");
                    free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
                }
            }
            log_msg(LOG_INFO,
                    "event=RAW_HTTP_COMPAT version=%s client_ip=%s listen_port=%d auto_urlencode=%s percent_decoded=%s parse_mode=%s bytes=%zu",
                    PROGRAM_VERSION, ctx->client_ip, ctx->ch->port,
                    http_compat_auto_urlencode ? "yes" : "no",
                    drc > 0 ? "yes" : "no", req.parse_mode[0] ? req.parse_mode : "none", req.content_length);
        }
        log_msg(LOG_INFO,
                "event=RAW_DATA_RECEIVED version=%s client_ip=%s client_port=%u listen_port=%d label=%s endpoint=%s content_type=%s filename=%s bytes=%zu",
                PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port, ctx->ch->label,
                req.path, req.content_type, req.filename, req.content_length);
    } else {
        rc = read_http_request(ctx->fd, &req,
                               request_start_ms + HTTP_HEADER_DEADLINE_MS,
                               request_start_ms + REQUEST_TOTAL_DEADLINE_MS);
    }
    if (rc != 0) {
        if (rc == -2) send_json_error(ctx->fd, 413, "request headers too large");
        else if (rc == -4) send_json_error(ctx->fd, 413, "invalid or too-large Content-Length");
        else if (rc == -5) send_json_error(ctx->fd, 411, "chunked transfer encoding is not supported");
        else if (rc == -6) send_json_error(ctx->fd, 411, "Content-Length is required");
        else if (rc == -7) send_json_error(ctx->fd, 408, "request deadline exceeded");
        else if (rc == -8) send_json_error(ctx->fd, 413, "payload exceeds endpoint-specific limit");
        else if (rc == -9) send_json_error(ctx->fd, 417, "unsupported Expect header");
        else if (rc == -10) send_json_error(ctx->fd, 404, "unknown endpoint");
        else send_json_error(ctx->fd, 400, "invalid HTTP request");
        close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }

    if (strcmp(req.path, "/sendMessage") == 0 &&
        maintenance_handle_magic_command(ctx, &req, strcmp(req.method, "RAW") == 0)) {
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }

    if (strcmp(req.method, "RAW") == 0) {
        if (strcmp(req.path, "/sendMessage") == 0) {
            const char *filter_reason = NULL;
            const char *filter_pattern = NULL;
            if (send_message_request_filter_match(&req, &filter_reason, &filter_pattern)) {
                log_message_filter_drop(ctx, &req, "raw", filter_reason, filter_pattern);
                free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
            }
        }
        if (maintenance_get_state(ctx->ch, NULL)) {
            maintenance_log_suppressed(ctx, &req, "raw");
            free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
        }
        int eq = spool_enqueue(ctx->client_ip, ctx->client_port, ctx->ch, &req, job_id);
        if (eq < 0) {
            log_msg(LOG_ERR, "event=RAW_MESSAGE_ENQUEUE_FAIL version=%s client_ip=%s listen_port=%d label=%s error=%s",
                    PROGRAM_VERSION, ctx->client_ip, ctx->ch->port, ctx->ch->label, strerror(errno));
            close(ctx->fd); free_http_request(&req); free(ctx); ingest_done(); return NULL;
        }
        metric_record(METRIC_ENQUEUED);
        log_msg(eq > 0 ? LOG_WARNING : LOG_INFO,
                "event=RAW_DATA_ENQUEUED version=%s job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s bytes=%zu durability=%s",
                PROGRAM_VERSION, job_id, ctx->client_ip, ctx->ch->port, ctx->ch->label, req.path, req.content_length,
                eq > 0 ? "uncertain" : "durable");
        pthread_mutex_lock(&queue_mutex); pthread_cond_broadcast(&queue_cond); pthread_mutex_unlock(&queue_mutex);
        audit_log_request(job_id, ctx->client_ip, ctx->ch, &req);
        /* Raw nc clients expect no HTTP response; closing the connection is the ACK. */
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }

    if (strcasecmp(req.method, "GET") == 0 && strcmp(req.path, "/sendMessage") != 0) {
        if (strcmp(req.path, "/health") == 0) send_health(ctx->fd, ctx->ch);
        else if (strcmp(req.path, "/live") == 0) send_live(ctx->fd);
        else if (strcmp(req.path, "/ready") == 0) send_ready(ctx->fd);
        else if (strcmp(req.path, "/metrics") == 0) send_metrics(ctx->fd);
        else send_json_error(ctx->fd, 404, "unknown endpoint");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (strcasecmp(req.method, "POST") != 0 &&
        !(strcasecmp(req.method, "GET") == 0 && strcmp(req.path, "/sendMessage") == 0)) {
        send_json_error(ctx->fd, 405, "POST required");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (req.method_compat_normalized) {
        log_msg(LOG_NOTICE,
                "event=HTTP_METHOD_COMPAT version=%s client_ip=%s client_port=%u listen_port=%d label=%s original_method=%s normalized_method=POST endpoint=%s bytes=%zu",
                PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port,
                ctx->ch->label, req.original_method[0] ? req.original_method : "unknown",
                req.path, req.content_length);
    }
    if (req.query_sendmessage_compat) {
        log_msg(LOG_INFO,
                "event=HTTP_QUERY_SENDMESSAGE version=%s client_ip=%s client_port=%u listen_port=%d label=%s method=%s original_method=%s bytes=%zu",
                PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port,
                ctx->ch->label, req.method,
                req.original_method[0] ? req.original_method : req.method,
                req.content_length);
    }
    if (strcmp(req.path, "/sendMessage") != 0 && strcmp(req.path, "/sendPhoto") != 0 && strcmp(req.path, "/sendDocument") != 0) {
        send_json_error(ctx->fd, 404, "unknown endpoint");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (strcmp(req.path, "/sendMessage") == 0) {
        const char *filter_reason = NULL;
        const char *filter_pattern = NULL;
        if (send_message_request_filter_match(&req, &filter_reason, &filter_pattern)) {
            log_message_filter_drop(ctx, &req, "http", filter_reason, filter_pattern);
            send_filtered_response(ctx->fd, filter_reason, filter_pattern);
            free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
        }
    }
    if (strcmp(req.path, "/sendMessage") == 0) {
        size_t message_chars = 0;
        const char *why = NULL;
        int vrc = validate_explicit_send_message(&req, &message_chars, &why);
        if (vrc != 0) {
            long status = vrc > 0 ? 413 : 400;
            log_msg(LOG_WARNING,
                    "event=SENDMESSAGE_REJECT version=%s client_ip=%s client_port=%u listen_port=%d label=%s "
                    "chars=%zu limit=%u reason=\"%s\"",
                    PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port, ctx->ch->label,
                    message_chars, TELEGRAM_SENDMESSAGE_MAX_CHARS, why ? why : "invalid");
            send_json_error(ctx->fd, status, why ? why : "invalid sendMessage");
            free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
        }
    }
    if (strcmp(req.path, "/sendPhoto") == 0 &&
        strncasecmp(req.content_type, "image/png", 9) != 0 &&
        strncasecmp(req.content_type, "image/jpeg", 10) != 0 &&
        strncasecmp(req.content_type, "image/jpg", 9) != 0) {
        send_json_error(ctx->fd, 415, "sendPhoto requires image/png or image/jpeg");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (strcmp(req.path, "/sendPhoto") == 0 && req.content_length == 0U) {
        send_json_error(ctx->fd, 400, "photo body is empty");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (strcmp(req.path, "/sendPhoto") == 0 && req.content_length > SENDPHOTO_MAX_BYTES) {
        send_json_error(ctx->fd, 413, "sendPhoto exceeds 10 MiB limit");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (strcmp(req.path, "/sendPhoto") == 0 && !sendphoto_magic_matches(&req)) {
        send_json_error(ctx->fd, 415, "sendPhoto body does not match declared PNG/JPEG Content-Type");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if ((strcmp(req.path, "/sendPhoto") == 0 || strcmp(req.path, "/sendDocument") == 0) && req.caption[0]) {
        const char *caption_why = NULL;
        if (validate_caption_text(req.caption, &caption_why) != 0) {
            send_json_error(ctx->fd, 400, caption_why ? caption_why : "invalid caption");
            free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
        }
    }
    if (strcmp(req.path, "/sendDocument") == 0 && req.content_length == 0) {
        send_json_error(ctx->fd, 400, "document body is empty");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }
    if (strcmp(req.path, "/sendDocument") == 0 && !req.filename[0]) {
        snprintf(req.filename, sizeof(req.filename), "%s", "upload.bin");
    }

    if (maintenance_get_state(ctx->ch, NULL)) {
        maintenance_log_suppressed(ctx, &req, "http");
        maintenance_send_status_response(ctx->fd, ctx->ch, false, "SUPPRESSED");
        free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
    }

    {
        bool duplicate = false;
        int eq = spool_enqueue_idempotent(ctx->client_ip, ctx->client_port,
                                          ctx->ch, &req, job_id, &duplicate);
        if (eq == -2) {
            log_msg(LOG_WARNING,
                    "event=IDEMPOTENCY_CONFLICT version=%s client_ip=%s listen_port=%d label=%s endpoint=%s",
                    PROGRAM_VERSION, ctx->client_ip, ctx->ch->port,
                    ctx->ch->label, req.path);
            send_json_error(ctx->fd, 409,
                            "X-Idempotency-Key was already used with a different request");
            free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
        }
        if (eq < 0) {
            log_msg(LOG_ERR,
                    "event=JOB_ENQUEUE_FAIL version=%s client_ip=%s client_port=%u listen_port=%d label=%s endpoint=%s error=%s",
                    PROGRAM_VERSION, ctx->client_ip, ctx->client_port, ctx->ch->port, ctx->ch->label,
                    req.path, strerror(errno));
            if (errno == ENOSPC)
                send_json_error(ctx->fd, 507, "persistent spool capacity/disk limit reached");
            else if (errno == ENOBUFS || errno == EDQUOT)
                send_json_error(ctx->fd, 503, "persistent queue capacity exceeded");
            else
                send_json_error(ctx->fd, 500, "persistent spool write failed");
        } else if (duplicate) {
            char body[512];
            int n = snprintf(body, sizeof(body),
                             "{\"ok\":true,\"queued\":true,\"duplicate\":true,\"job_id\":\"%s\"}\n",
                             job_id);
            log_msg(LOG_INFO,
                    "event=IDEMPOTENCY_HIT version=%s job_id=%s client_ip=%s listen_port=%d label=%s endpoint=%s",
                    PROGRAM_VERSION, job_id, ctx->client_ip, ctx->ch->port,
                    ctx->ch->label, req.path);
            if (n < 0) n = 0;
            if ((size_t)n >= sizeof(body)) n = (int)sizeof(body) - 1;
            (void)send_http_response(ctx->fd, 200,
                                     "application/json; charset=utf-8",
                                     body, (size_t)n);
        } else {
            char body[768];
            char label_json[512];
            int n;
            json_escape(ctx->ch->label, label_json, sizeof(label_json));
            n = snprintf(body, sizeof(body),
                         "{\"ok\":true,\"queued\":true,\"job_id\":\"%s\",\"port\":%d,\"label\":\"%s\",\"durability\":\"%s\"}\n",
                         job_id, ctx->ch->port, label_json, eq > 0 ? "uncertain" : "durable");
            metric_record(METRIC_ENQUEUED);
            log_msg(eq > 0 ? LOG_WARNING : LOG_INFO,
                    "event=JOB_ENQUEUED version=%s job_id=%s client_ip=%s client_port=%u listen_port=%d label=%s endpoint=%s bytes=%zu durability=%s",
                    PROGRAM_VERSION, job_id, ctx->client_ip, ctx->client_port, ctx->ch->port, ctx->ch->label,
                    req.path, req.content_length, eq > 0 ? "uncertain" : "durable");
            if (eq > 0)
                log_msg(LOG_CRIT, "event=SPOOL_DURABILITY_UNCERTAIN version=%s job_id=%s pending_dir=%s",
                        PROGRAM_VERSION, job_id, spool_pending);
            if (n < 0) n = 0;
            if ((size_t)n >= sizeof(body)) n = (int)sizeof(body) - 1;
            (void)send_http_response(ctx->fd, 202, "application/json; charset=utf-8", body, (size_t)n);
            pthread_mutex_lock(&queue_mutex); pthread_cond_broadcast(&queue_cond); pthread_mutex_unlock(&queue_mutex);
            /* Audit after replying so large image Base64 audit does not hold the client open. */
            audit_log_request(job_id, ctx->client_ip, ctx->ch, &req);
        }
    }

    free_http_request(&req); close(ctx->fd); free(ctx); ingest_done(); return NULL;
}

static void close_all_listeners(void)
{
    size_t i;
    for (i = 0; i < channel_count; i++) if (channels[i].listen_fd >= 0) { close(channels[i].listen_fd); channels[i].listen_fd = -1; }
}

int main(int argc, char **argv)
{
    const char *bind_addr = DEFAULT_BIND_ADDR;
    const char *config_file = DEFAULT_CONFIG_FILE;
    const char *admin_job_id = NULL;
    enum one_shot_mode one_shot = MODE_DAEMON;
    struct sigaction sa;
    struct pollfd pfds[MAX_CHANNELS];
    struct channel *pchannels[MAX_CHANNELS];
    size_t active = 0, i;
    int opt;
    int option_index = 0;
    static const struct option long_options[] = {
        {"queue-status",     no_argument,       NULL, 1000},
        {"failed-list",      no_argument,       NULL, 1001},
        {"failed-show",      required_argument, NULL, 1002},
        {"failed-retry",     required_argument, NULL, 1003},
        {"failed-retry-all", no_argument,       NULL, 1004},
        {"failed-delete",    required_argument, NULL, 1005},
        {"validate-tokens",  no_argument,       NULL, 1006},
        {"audit-full-token", no_argument,       NULL, 1007},
        {"audit-binary-content", no_argument,   NULL, 1008},
        {NULL, 0, NULL, 0}
    };

#define SET_ONESHOT(m) do { \
    if (one_shot != MODE_DAEMON) { fprintf(stderr, "ERROR: only one one-shot/admin operation may be specified\n"); return EXIT_FAILURE; } \
    one_shot = (m); \
} while (0)

    while ((opt = getopt_long(argc, argv, "b:c:f:s:w:p:a:Lth", long_options, &option_index)) != -1) {
        switch (opt) {
            case 'b': bind_addr = optarg; break;
            case 'c': config_file = optarg; break;
            case 'f':
                if (strlen(optarg) >= sizeof(filter_file)) { fprintf(stderr, "ERROR: filter path too long\n"); return EXIT_FAILURE; }
                snprintf(filter_file, sizeof(filter_file), "%s", optarg); break;
            case 's':
                if (strlen(optarg) >= sizeof(spool_root)) { fprintf(stderr, "ERROR: spool path too long\n"); return EXIT_FAILURE; }
                snprintf(spool_root, sizeof(spool_root), "%s", optarg); break;
            case 'w': if (parse_workers(optarg, &worker_count) != 0) { fprintf(stderr, "ERROR: invalid worker count\n"); return EXIT_FAILURE; } break;
            case 'p': {
                int port;
                if (selected_port_count >= MAX_SELECTED_PORTS || parse_port(optarg, &port) != 0) {
                    fprintf(stderr, "ERROR: invalid -p port '%s' (valid 1..65535)\n", optarg); return EXIT_FAILURE;
                }
                selected_ports[selected_port_count++] = port; break;
            }
            case 'a':
                if (allowed_client_count >= MAX_ALLOWED_CLIENTS) { fprintf(stderr, "ERROR: too many -a entries\n"); return EXIT_FAILURE; }
                if (parse_allowed_client_rule(optarg, &allowed_clients[allowed_client_count]) != 0) {
                    fprintf(stderr, "ERROR: invalid -a IP/CIDR '%s'\n", optarg);
                    return EXIT_FAILURE;
                }
                allowed_client_count++;
                break;
            case 'L': sensitive_audit_enabled = true; break;
            case 't': SET_ONESHOT(MODE_CONFIG_TEST); break;
            case 1000: SET_ONESHOT(MODE_QUEUE_STATUS); break;
            case 1001: SET_ONESHOT(MODE_FAILED_LIST); break;
            case 1002: SET_ONESHOT(MODE_FAILED_SHOW); admin_job_id = optarg; break;
            case 1003: SET_ONESHOT(MODE_FAILED_RETRY); admin_job_id = optarg; break;
            case 1004: SET_ONESHOT(MODE_FAILED_RETRY_ALL); break;
            case 1005: SET_ONESHOT(MODE_FAILED_DELETE); admin_job_id = optarg; break;
            case 1006: SET_ONESHOT(MODE_VALIDATE_TOKENS); break;
            case 1007: full_token_audit_enabled = true; break;
            case 1008: audit_binary_content_enabled = true; break;
            case 'h': usage(argv[0]); return EXIT_SUCCESS;
            default: usage(argv[0]); return EXIT_FAILURE;
        }
    }
#undef SET_ONESHOT

    if (full_token_audit_enabled && !sensitive_audit_enabled) {
        fprintf(stderr, "ERROR: --audit-full-token requires -L\n");
        return EXIT_FAILURE;
    }
    if (audit_binary_content_enabled && !sensitive_audit_enabled) {
        fprintf(stderr, "ERROR: --audit-binary-content requires -L\n");
        return EXIT_FAILURE;
    }

    if (build_spool_paths() != 0) { fprintf(stderr, "ERROR: invalid spool path\n"); return EXIT_FAILURE; }

    if (one_shot == MODE_QUEUE_STATUS || one_shot == MODE_FAILED_LIST || one_shot == MODE_FAILED_SHOW ||
        one_shot == MODE_FAILED_RETRY || one_shot == MODE_FAILED_RETRY_ALL || one_shot == MODE_FAILED_DELETE) {
        int arc = -1;
        if (verify_existing_spool_dirs() != 0) {
            fprintf(stderr, "ERROR: spool verification failed for %s: %s\n", spool_root, strerror(errno));
            return EXIT_FAILURE;
        }
        switch (one_shot) {
            case MODE_QUEUE_STATUS: arc = admin_queue_status(); break;
            case MODE_FAILED_LIST: arc = admin_failed_list(); break;
            case MODE_FAILED_SHOW: arc = admin_failed_show(admin_job_id); break;
            case MODE_FAILED_RETRY: arc = admin_failed_retry(admin_job_id); break;
            case MODE_FAILED_RETRY_ALL: arc = admin_failed_retry_all(); break;
            case MODE_FAILED_DELETE: arc = admin_failed_delete(admin_job_id); break;
            default: break;
        }
        if (arc < 0) {
            fprintf(stderr, "ERROR: admin operation failed: %s\n", strerror(errno));
            return EXIT_FAILURE;
        }
        return arc == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    if (load_config(config_file) != 0 || !channel_count) return EXIT_FAILURE;
    for (i = 0; i < selected_port_count; i++) if (!find_channel_by_port(selected_ports[i])) {
        fprintf(stderr, "ERROR: -p %d has no mapping in %s\n", selected_ports[i], config_file); return EXIT_FAILURE;
    }

    if (one_shot == MODE_CONFIG_TEST) {
        size_t selected = 0;
        int frc = reload_filter_file(true);
        if (frc < 0) {
            fprintf(stderr, "ERROR: invalid filter file %s: %s\n", filter_file, strerror(errno));
            return EXIT_FAILURE;
        }
        for (i = 0; i < channel_count; i++) if (channels[i].selected) selected++;
        printf("Configuration OK\nfile=%s\nmappings=%zu\nselected=%zu\nhttp_compat_text_query=%s\nhttp_compat_auto_urlencode=%s\n"
               "proxy_protocol_v1=%s\nmaintenance_control_access=%s\nmaintenance_control_rules=%zu\n"
               "maintenance_magic_status=%s\nmaintenance_magic_on=%s\nmaintenance_magic_on_30m=%s\n"
               "maintenance_magic_on_ttl=%s<TTL>[:REASON]\nmaintenance_magic_extend=%s<TTL>\nmaintenance_magic_off=%s\n"
               "maintenance_magic_mark=%s<TEXT>\ntest_log_only=%s<TEXT>\nmaintenance_max_ttl_sec=%llu\n"
               "filter_file=%s\nfilter_source=%s\nfilters=%zu\naccess=%s\nallow_rules=%zu\n",
               config_file, channel_count, selected,
               http_compat_text_query ? "yes" : "no",
               http_compat_auto_urlencode ? "yes" : "no",
               proxy_protocol_v1_enabled ? "yes" : "no",
               maintenance_control_rule_count ? "allow-list" : "allow-all",
               maintenance_control_rule_count,
               MAINTENANCE_MAGIC_STATUS, MAINTENANCE_MAGIC_ON, MAINTENANCE_MAGIC_ON_30M,
               MAINTENANCE_MAGIC_ON_PREFIX, MAINTENANCE_MAGIC_EXTEND_PREFIX, MAINTENANCE_MAGIC_OFF,
               MAINTENANCE_MAGIC_MARK_PREFIX, TEST_LOG_ONLY_PREFIX,
               (unsigned long long)MAINTENANCE_MAX_TTL_SEC,
               filter_file, frc > 0 ? "builtin-defaults" : "external-file", active_filter_count,
               allowed_client_count ? "allow-list" : "allow-all", allowed_client_count);
        for (i = 0; i < allowed_client_count; i++)
            printf("allow[%zu]=%s\n", i, allowed_clients[i].text);
        for (i = 0; i < maintenance_control_rule_count; i++)
            printf("maintenance_control_allow[%zu]=%s\n", i, maintenance_control_rules[i].text);
        return EXIT_SUCCESS;
    }

    if (one_shot == MODE_VALIDATE_TOKENS) {
        int vrc;
        if (curl_global_init(CURL_GLOBAL_DEFAULT) != 0) {
            fprintf(stderr, "ERROR: curl_global_init failed\n"); return EXIT_FAILURE;
        }
        vrc = validate_config_tokens();
        curl_global_cleanup();
        return vrc == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
    }

    umask(077);
    openlog("tg_https_proxy", LOG_PID | LOG_NDELAY | LOG_CONS, LOG_DAEMON);
    signal(SIGPIPE, SIG_IGN);
    memset(&sa, 0, sizeof(sa)); sa.sa_handler = stop_handler; sigemptyset(&sa.sa_mask);
    if (sigaction(SIGTERM, &sa, NULL) != 0 || sigaction(SIGINT, &sa, NULL) != 0) {
        perror("sigaction"); return EXIT_FAILURE;
    }
    memset(&sa, 0, sizeof(sa)); sa.sa_handler = hup_handler; sigemptyset(&sa.sa_mask);
    if (sigaction(SIGHUP, &sa, NULL) != 0) {
        perror("sigaction SIGHUP"); return EXIT_FAILURE;
    }
    if (init_spool_dirs() != 0) {
        fprintf(stderr, "ERROR: cannot initialize spool %s: %s\n", spool_root, strerror(errno)); return EXIT_FAILURE;
    }
    if (maintenance_load_states() != 0) {
        fprintf(stderr, "ERROR: cannot restore maintenance state from %s: %s\n", spool_maintenance, strerror(errno)); return EXIT_FAILURE;
    }
    if (maintenance_notice_load_states() != 0) {
        fprintf(stderr, "ERROR: cannot restore maintenance notice state from %s: %s\n", spool_maintenance, strerror(errno)); return EXIT_FAILURE;
    }
    if (recover_working_jobs() != 0) {
        fprintf(stderr, "ERROR: cannot recover spool working directory\n"); return EXIT_FAILURE;
    }
    {
        unsigned removed_tmp = 0, removed_idem = 0;
        (void)cleanup_stale_files(spool_tmp, ".tmp-", STALE_TMP_AGE_SEC, &removed_tmp);
        (void)cleanup_stale_files(spool_idempotency, "", IDEMPOTENCY_RETENTION_SEC, &removed_idem);
        if (removed_tmp || removed_idem)
            log_msg(LOG_NOTICE,
                    "event=SPOOL_CLEANUP version=%s stale_tmp_removed=%u expired_idempotency_removed=%u",
                    PROGRAM_VERSION, removed_tmp, removed_idem);
    }
    {
        int frc = reload_filter_file(true);
        if (frc < 0) {
            fprintf(stderr, "ERROR: cannot load filter file %s: %s\n", filter_file, strerror(errno));
            return EXIT_FAILURE;
        }
        log_msg(LOG_NOTICE,
                "event=FILTER_LOAD version=%s source=%s file=%s filters=%zu",
                PROGRAM_VERSION, frc > 0 ? "builtin-defaults" : "external-file",
                filter_file, active_filter_count);
    }
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != 0) {
        fprintf(stderr, "ERROR: curl_global_init failed\n"); return EXIT_FAILURE;
    }
    maintenance_reconcile_notice_states();
    daemon_start_ms = realtime_ms();

    for (i = 0; i < channel_count; i++) {
        struct channel *ch = &channels[i];
        if (!ch->selected) continue;
        ch->listen_fd = create_listener(bind_addr, ch->port);
        if (ch->listen_fd < 0) {
            fprintf(stderr, "ERROR: cannot listen on %s:%d: %s\n", bind_addr, ch->port, strerror(errno));
            close_all_listeners(); curl_global_cleanup(); return EXIT_FAILURE;
        }
        pfds[active].fd = ch->listen_fd; pfds[active].events = POLLIN; pchannels[active] = ch; active++;
        log_msg(LOG_NOTICE, "event=LISTEN version=%s address=%s port=%d label=%s", PROGRAM_VERSION, bind_addr, ch->port, ch->label);
    }
    if (!active) { fprintf(stderr, "ERROR: no selected listeners\n"); curl_global_cleanup(); return EXIT_FAILURE; }

    {
        int requested_workers = worker_count;
        int started_workers = 0;
        bool worker_start_failed = false;
        for (i = 0; i < (size_t)requested_workers; i++) {
            int prc = pthread_create(&workers[i], NULL, worker_main, (void *)(uintptr_t)(i + 1U));
            if (prc != 0) {
                fprintf(stderr, "ERROR: pthread_create worker failed: %s\n", strerror(prc));
                log_msg(LOG_ERR, "event=WORKER_CREATE_FAIL version=%s requested=%d started=%d error=%s",
                        PROGRAM_VERSION, requested_workers, started_workers, strerror(prc));
                worker_start_failed = true;
                break;
            }
            started_workers++;
        }
        worker_count = started_workers;
        if (worker_start_failed || worker_count <= 0) {
            stop_flag = 1;
            close_all_listeners();
            pthread_mutex_lock(&queue_mutex); pthread_cond_broadcast(&queue_cond); pthread_mutex_unlock(&queue_mutex);
            for (i = 0; i < (size_t)worker_count; i++) pthread_join(workers[i], NULL);
            curl_global_cleanup(); closelog(); return EXIT_FAILURE;
        }
    }

    log_msg(LOG_NOTICE,
            "event=START version=%s mode=persistent-queue listeners=%zu workers=%d spool=%s sensitive_audit=%s token_audit=%s binary_payload_audit=%s "
            "http_compat_text_query=%s http_compat_auto_urlencode=%s proxy_protocol_v1=%s maintenance_active_channels=%zu "
            "access=%s allow_rules=%zu maintenance_control_access=%s maintenance_control_rules=%zu channel_max_per_minute=%ld max_pending=%u max_failed=%u max_spool_bytes=%llu "
            "max_job_age_sec=%lld delivery_semantics=at_least_once",
            PROGRAM_VERSION, active, worker_count, spool_root,
            sensitive_audit_enabled ? "enabled" : "disabled",
            full_token_audit_enabled ? "full" : "redacted-fingerprint",
            audit_binary_content_enabled ? "full-base64" : "metadata-sha256",
            http_compat_text_query ? "yes" : "no",
            http_compat_auto_urlencode ? "yes" : "no",
            proxy_protocol_v1_enabled ? "yes" : "no",
            maintenance_active_channels(),
            allowed_client_count ? "allow-list" : "allow-all", allowed_client_count,
            maintenance_control_rule_count ? "allow-list" : "allow-all",
            maintenance_control_rule_count, CHANNEL_MAX_PER_MINUTE,
            MAX_PENDING_JOBS, MAX_FAILED_JOBS, (unsigned long long)MAX_SPOOL_BYTES,
            (long long)MAX_JOB_AGE_SEC);
    for (i = 0; i < allowed_client_count; i++)
        log_msg(LOG_NOTICE, "event=ALLOW_RULE version=%s index=%zu rule=%s",
                PROGRAM_VERSION, i, allowed_clients[i].text);
    for (i = 0; i < maintenance_control_rule_count; i++)
        log_msg(LOG_NOTICE, "event=MAINTENANCE_CONTROL_ALLOW_RULE version=%s index=%zu rule=%s",
                PROGRAM_VERSION, i, maintenance_control_rules[i].text);
    if (proxy_protocol_v1_enabled && allowed_client_count == 0U)
        log_msg(LOG_WARNING,
                "event=PROXY_PROTOCOL_TRUST_WARNING version=%s proxy_protocol_v1=yes access=allow-all warning=configure_-a_for_trusted_Host_B_addresses_in_production",
                PROGRAM_VERSION);
    if (sensitive_audit_enabled) {
        log_msg(LOG_WARNING,
                "event=AUDIT_WARNING version=%s sensitive_audit=enabled token_audit=%s "
                "warning=chat-message-and-image-content-are-logged",
                PROGRAM_VERSION, full_token_audit_enabled ? "full" : "redacted-fingerprint");
        if (full_token_audit_enabled)
            log_msg(LOG_CRIT,
                    "event=AUDIT_FULL_TOKEN_WARNING version=%s warning=full-bot-token-is-being-written-to-syslog",
                    PROGRAM_VERSION);
    }

    while (!stop_flag) {
        maintenance_expire_all();
        if (reload_flag) {
            size_t active_ingest;
            pthread_mutex_lock(&ingest_mutex);
            active_ingest = ingest_threads;
            pthread_mutex_unlock(&ingest_mutex);
            if (active_ingest == 0) {
                int crc, frc;
                reload_flag = 0;
                crc = reload_runtime_config(config_file);
                frc = reload_filter_file(false);
                if (crc == 0)
                    log_msg(LOG_NOTICE,
                            "event=CONFIG_RELOAD_OK version=%s file=%s mappings=%zu http_compat_text_query=%s http_compat_auto_urlencode=%s proxy_protocol_v1=%s maintenance_control_access=%s maintenance_control_rules=%zu",
                            PROGRAM_VERSION, config_file, channel_count,
                            http_compat_text_query ? "yes" : "no",
                            http_compat_auto_urlencode ? "yes" : "no",
                            proxy_protocol_v1_enabled ? "yes" : "no",
                            maintenance_control_rule_count ? "allow-list" : "allow-all",
                            maintenance_control_rule_count);
                else
                    log_msg(LOG_ERR,
                            "event=CONFIG_RELOAD_FAIL version=%s file=%s error=%s retained_old_config=yes",
                            PROGRAM_VERSION, config_file, strerror(errno));
                if (frc == 0)
                    log_msg(LOG_NOTICE,
                            "event=FILTER_RELOAD_OK version=%s file=%s filters=%zu",
                            PROGRAM_VERSION, filter_file, active_filter_count);
                else
                    log_msg(LOG_ERR,
                            "event=FILTER_RELOAD_FAIL version=%s file=%s error=%s retained_old_filters=yes",
                            PROGRAM_VERSION, filter_file, strerror(errno));
            }
        }
        int prc = poll(pfds, active, 1000);
        if (prc < 0) {
            if (errno == EINTR) continue;
            log_msg(LOG_ERR, "event=POLL_FAIL version=%s error=%s", PROGRAM_VERSION, strerror(errno));
            fatal_flag = 1;
            break;
        }
        if (prc == 0) continue;
        for (i = 0; i < active; i++) if (pfds[i].revents & POLLIN) {
            struct sockaddr_storage peer;
            socklen_t peerlen = sizeof(peer);
            char client_ip[NI_MAXHOST];
            unsigned client_port = 0;
            int cfd = accept(pchannels[i]->listen_fd, (struct sockaddr *)&peer, &peerlen);
            struct ingest_ctx *ctx;
            pthread_t tid;
            if (cfd < 0) { if (errno != EINTR) log_msg(LOG_ERR, "event=ACCEPT_FAIL version=%s port=%d error=%s", PROGRAM_VERSION, pchannels[i]->port, strerror(errno)); continue; }
            if (get_peer_info((struct sockaddr *)&peer, peerlen, client_ip, sizeof(client_ip), &client_port) != 0) { close(cfd); continue; }
            if (!client_is_allowed(client_ip)) {
                log_msg(LOG_WARNING, "event=DENY version=%s client_ip=%s client_port=%u listen_port=%d label=%s reason=source-not-allowed",
                        PROGRAM_VERSION, client_ip, client_port, pchannels[i]->port, pchannels[i]->label);
                send_json_error(cfd, 403, "source not allowed"); close(cfd); continue;
            }
            pthread_mutex_lock(&ingest_mutex);
            if (ingest_threads >= MAX_INGEST_THREADS) {
                pthread_mutex_unlock(&ingest_mutex);
                log_msg(LOG_WARNING, "event=INGEST_BUSY version=%s client_ip=%s listen_port=%d", PROGRAM_VERSION, client_ip, pchannels[i]->port);
                send_json_error(cfd, 503, "ingest busy"); close(cfd); continue;
            }
            ingest_threads++;
            pthread_mutex_unlock(&ingest_mutex);
            ctx = calloc(1, sizeof(*ctx));
            if (!ctx) { close(cfd); ingest_done(); continue; }
            ctx->fd = cfd;
            ctx->client_port = client_port;
            ctx->peer_port = client_port;
            ctx->ch = pchannels[i];
            snprintf(ctx->client_ip, sizeof(ctx->client_ip), "%s", client_ip);
            snprintf(ctx->peer_ip, sizeof(ctx->peer_ip), "%s", client_ip);
            if (pthread_create(&tid, NULL, ingest_main, ctx) != 0) {
                close(cfd); free(ctx); ingest_done(); continue;
            }
            pthread_detach(tid);
        }
    }

    maintenance_checkpoint_all();
    close_all_listeners();
    pthread_mutex_lock(&queue_mutex); pthread_cond_broadcast(&queue_cond); pthread_mutex_unlock(&queue_mutex);
    pthread_mutex_lock(&ingest_mutex);
    while (ingest_threads > 0) pthread_cond_wait(&ingest_cond, &ingest_mutex);
    pthread_mutex_unlock(&ingest_mutex);
    for (i = 0; i < (size_t)worker_count; i++) pthread_join(workers[i], NULL);
    maintenance_wait_notice_threads();
    log_msg(LOG_NOTICE, "event=STOP version=%s", PROGRAM_VERSION);
    curl_global_cleanup(); closelog();
    return fatal_flag ? EXIT_FAILURE : EXIT_SUCCESS;
}
