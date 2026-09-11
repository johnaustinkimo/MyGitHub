#define _GNU_SOURCE

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define PROGRAM_NAME "tcp_failover_proxy"
#define PROGRAM_VERSION "2.7.0"
#define DEFAULT_CONFIG "/etc/tcp_failover_proxy.conf"
#define IO_BUF_SIZE 16384
#define HOST_LEN 256
#define PORT_LEN 16
#define NAME_LEN 64
#define MAX_SERVICES 128
#define MAX_WORKERS 64
#define MAX_RESOLVED_ADDRS 8
#define WORKER_MAX_EVENTS 1024
#define WORKER_TIMER_MS 250
#define HTTP_COMPAT_MAX_TARGET 8192
#define HEALTH_PATH_LEN 512
#define HEALTH_HTTP_RESPONSE_MAX 4096
#define PROXY_V1_LINE_MAX 108

struct defaults_cfg {
    char listen_host[HOST_LEN];
    int check_interval_ms;
    int connect_timeout_ms;
    int fall;
    int rise;
    int idle_timeout_sec;
    int backlog;
    int service_max_clients;
    int max_clients_total;
    int worker_threads;
    int shutdown_grace_sec;
    int startup_health_wait_ms;
    int health_stagger_ms;
    int tcp_keepalive_idle_sec;
    int tcp_keepalive_interval_sec;
    int tcp_keepalive_count;
    int http_compat_text_query;
    int http_compat_auto_urlencode;
    int proxy_protocol_v1;
    int health_check;
    char health_path[HEALTH_PATH_LEN];
    int health_expect_status;
};

struct service_cfg {
    char name[NAME_LEN];
    char listen_host[HOST_LEN];
    char listen_port[PORT_LEN];
    char active_host[HOST_LEN];
    char active_port[PORT_LEN];
    char standby_host[HOST_LEN];
    char standby_port[PORT_LEN];
    int check_interval_ms;
    int connect_timeout_ms;
    int fall;
    int rise;
    int idle_timeout_sec;
    int backlog;
    int max_clients;
    int tcp_keepalive_idle_sec;
    int tcp_keepalive_interval_sec;
    int tcp_keepalive_count;
    int http_compat_text_query;
    int http_compat_auto_urlencode;
    int proxy_protocol_v1;
    int health_check;
    char health_path[HEALTH_PATH_LEN];
    int health_expect_status;
};

enum section_type { SEC_NONE, SEC_GLOBAL, SEC_SERVICE };

enum health_check_type {
    HEALTH_CHECK_TCP = 0,
    HEALTH_CHECK_HTTP = 1
};

enum backend_state {
    BACKEND_DOWN = 0,
    BACKEND_ACTIVE,
    BACKEND_STANDBY
};

struct health_status {
    bool initialized;
    bool up;
    int consecutive_success;
    int consecutive_failure;
};

struct runtime_state {
    pthread_mutex_t lock;
    struct health_status active;
    struct health_status standby;
    enum backend_state selected;
};

struct endpoint_addr {
    struct sockaddr_storage ss;
    socklen_t len;
    int family;
    int socktype;
    int protocol;
};

struct resolved_endpoint {
    struct endpoint_addr addr[MAX_RESOLVED_ADDRS];
    size_t count;
};

struct app_config;

struct service {
    struct service_cfg cfg;
    struct runtime_state state;
    int listen_fd;
    pthread_t health_tid;
    bool health_started;
    atomic_int clients;
    atomic_ullong accepted_total;
    atomic_ullong rejected_total;
    atomic_ullong failover_total;
    atomic_ullong completed_total;
    atomic_ullong http_compat_rewrite_total;
    atomic_ullong http_compat_urlencode_total;
    atomic_int active_health_http_status;
    atomic_int standby_health_http_status;
    struct resolved_endpoint active_resolved;
    struct resolved_endpoint standby_resolved;
    struct app_config *owner;
};

struct app_config {
    struct defaults_cfg defaults;
    struct service services[MAX_SERVICES];
    size_t service_count;
    atomic_bool health_running;
    struct app_config *next_retired;
};

struct io_buffer {
    unsigned char data[IO_BUF_SIZE];
    size_t off;
    size_t len;
    bool src_eof;
    bool dst_shutdown;
};

enum session_state {
    SESSION_CONNECTING = 0,
    SESSION_RELAY
};

enum worker_event_kind {
    WORKER_EVENT_WAKE = 1,
    WORKER_EVENT_TIMER,
    WORKER_EVENT_CLIENT,
    WORKER_EVENT_BACKEND
};

struct worker;
struct session;

struct worker_event {
    enum worker_event_kind kind;
    struct session *session;
};

struct pending_conn {
    int client_fd;
    struct service *svc;
    char peer[128];
    struct pending_conn *next;
};

struct session {
    int client_fd;
    int backend_fd;
    struct service *svc;
    struct worker *worker;
    enum session_state state;
    enum backend_state attempt_backend;
    enum backend_state fallback_backend;
    enum backend_state connected_backend;
    size_t address_index;
    bool fallback_started;
    bool closing;
    int64_t connect_deadline_ms;
    int64_t last_activity_ms;
    char peer[128];
    struct io_buffer c2b;
    struct io_buffer b2c;
    bool http_compat_decided;
    bool http_compat_rewritten;
    char proxy_line[PROXY_V1_LINE_MAX];
    size_t proxy_line_off;
    size_t proxy_line_len;
    struct worker_event client_event;
    struct worker_event backend_event;
    struct session *prev_active;
    struct session *next_active;
    struct session *next_gc;
};

struct worker {
    int id;
    int epoll_fd;
    int wake_fd;
    int timer_fd;
    pthread_t tid;
    bool started;
    atomic_bool running;
    atomic_llong last_heartbeat_ms;
    pthread_mutex_t queue_lock;
    struct pending_conn *queue_head;
    struct pending_conn *queue_tail;
    struct session *sessions;
    struct session *gc_head;
    struct worker_event wake_event;
    struct worker_event timer_event;
};

static struct app_config *g_active_app = NULL;
static struct app_config *g_retired_apps = NULL;
static volatile sig_atomic_t g_running = 1;
static volatile sig_atomic_t g_reload_requested = 0;
static volatile sig_atomic_t g_shutdown_requested = 0;
static volatile sig_atomic_t g_force_shutdown = 0;
static volatile sig_atomic_t g_stats_requested = 0;
static atomic_int g_clients_total = 0;
static atomic_ullong g_accepted_total = 0;
static atomic_ullong g_rejected_total = 0;
static atomic_ullong g_failover_total = 0;
static atomic_ullong g_completed_total = 0;
static int g_log_to_stderr = 1;
static struct worker g_workers[MAX_WORKERS];
static int g_worker_count = 0;
static atomic_uint g_next_worker = 0;
static atomic_bool g_worker_failed = false;
static int g_reserve_fd = -1;
static int g_exit_code = 0;
static int64_t g_watchdog_interval_ms = 0;
static int64_t g_watchdog_last_notify_ms = 0;


static int resolve_endpoint(const char *host, const char *port,
                            struct resolved_endpoint *out);
static int64_t monotonic_ms(void);
static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [-c config] [-d] [-t] [-h] [-V]\n"
        "  -c FILE  Configuration file (default: %s)\n"
        "  -d       Daemonize (do not use with systemd)\n"
        "  -t       Validate configuration and exit\n"
        "  -h       Show help\n"
        "  -V       Show version\n\n"
        "Health check config (global defaults or per-service override):\n"
        "  health_check=tcp|http        Default: tcp\n"
        "  health_path=/ready           Used when health_check=http\n"
        "  health_expect_status=200     Exact expected HTTP status\n"
        "  HTTP health uses connect_timeout_ms for bounded send/read waits.\n",
        prog, DEFAULT_CONFIG);
}

static void log_msg(int priority, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsyslog(priority, fmt, ap);
    va_end(ap);
}

static char *trim(char *s)
{
    char *end;
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')
        s++;
    if (*s == '\0')
        return s;
    end = s + strlen(s) - 1;
    while (end > s && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n'))
        *end-- = '\0';
    return s;
}

static int copy_string(const char *path, unsigned long lineno,
                       const char *key, char *dst, size_t dstsz, const char *value)
{
    if (value[0] == '\0' || strlen(value) >= dstsz) {
        fprintf(stderr, "%s:%lu: invalid or too long %s\n", path, lineno, key);
        return -1;
    }
    snprintf(dst, dstsz, "%s", value);
    return 0;
}

static int parse_int_at(const char *path, unsigned long lineno,
                        const char *name, const char *value,
                        int minv, int maxv, int *out)
{
    char *end = NULL;
    long v;

    errno = 0;
    v = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || v < minv || v > maxv) {
        fprintf(stderr, "%s:%lu: invalid %s=%s (expected %d..%d)\n",
                path, lineno, name, value, minv, maxv);
        return -1;
    }
    *out = (int)v;
    return 0;
}

static int parse_bool_at(const char *path, unsigned long lineno,
                         const char *name, const char *value, int *out)
{
    if (strcasecmp(value, "yes") == 0 || strcasecmp(value, "true") == 0 ||
        strcasecmp(value, "on") == 0 || strcmp(value, "1") == 0) {
        *out = 1;
        return 0;
    }
    if (strcasecmp(value, "no") == 0 || strcasecmp(value, "false") == 0 ||
        strcasecmp(value, "off") == 0 || strcmp(value, "0") == 0) {
        *out = 0;
        return 0;
    }
    fprintf(stderr, "%s:%lu: invalid %s=%s (expected yes/no, true/false, on/off, or 1/0)\n",
            path, lineno, name, value);
    return -1;
}

static int parse_health_check_at(const char *path, unsigned long lineno,
                                 const char *name, const char *value, int *out)
{
    if (strcasecmp(value, "tcp") == 0) {
        *out = HEALTH_CHECK_TCP;
        return 0;
    }
    if (strcasecmp(value, "http") == 0) {
        *out = HEALTH_CHECK_HTTP;
        return 0;
    }
    fprintf(stderr, "%s:%lu: invalid %s=%s (expected tcp or http)\n",
            path, lineno, name, value);
    return -1;
}

static int copy_health_path(const char *path, unsigned long lineno,
                            const char *key, char *dst, size_t dstsz,
                            const char *value)
{
    const unsigned char *p = (const unsigned char *)value;

    if (!value || value[0] != '/' || strlen(value) >= dstsz) {
        fprintf(stderr, "%s:%lu: invalid %s=%s (must start with '/' and be shorter than %zu bytes)\n",
                path, lineno, key, value ? value : "", dstsz);
        return -1;
    }
    while (*p) {
        if (*p <= 0x20 || *p == 0x7f) {
            fprintf(stderr, "%s:%lu: invalid %s: spaces/control characters are not allowed\n",
                    path, lineno, key);
            return -1;
        }
        p++;
    }
    snprintf(dst, dstsz, "%s", value);
    return 0;
}

static void defaults_init(struct defaults_cfg *d)
{
    memset(d, 0, sizeof(*d));
    snprintf(d->listen_host, sizeof(d->listen_host), "0.0.0.0");
    d->check_interval_ms = 2000;
    d->connect_timeout_ms = 1500;
    d->fall = 3;
    d->rise = 2;
    d->idle_timeout_sec = 0;
    d->backlog = 256;
    d->service_max_clients = 1024;
    d->max_clients_total = 4096;
    d->worker_threads = 4;
    d->shutdown_grace_sec = 60;
    d->startup_health_wait_ms = 4000;
    d->health_stagger_ms = 250;
    d->tcp_keepalive_idle_sec = 60;
    d->tcp_keepalive_interval_sec = 10;
    d->tcp_keepalive_count = 3;
    d->http_compat_text_query = 0;
    d->http_compat_auto_urlencode = 0;
    d->proxy_protocol_v1 = 0;
    d->health_check = HEALTH_CHECK_TCP;
    snprintf(d->health_path, sizeof(d->health_path), "/ready");
    d->health_expect_status = 200;
}

static void service_raw_init(struct service *svc, const char *name)
{
    memset(svc, 0, sizeof(*svc));
    snprintf(svc->cfg.name, sizeof(svc->cfg.name), "%s", name);
    svc->cfg.check_interval_ms = -1;
    svc->cfg.connect_timeout_ms = -1;
    svc->cfg.fall = -1;
    svc->cfg.rise = -1;
    svc->cfg.idle_timeout_sec = -1;
    svc->cfg.backlog = -1;
    svc->cfg.max_clients = -1;
    svc->cfg.tcp_keepalive_idle_sec = -1;
    svc->cfg.tcp_keepalive_interval_sec = -1;
    svc->cfg.tcp_keepalive_count = -1;
    svc->cfg.http_compat_text_query = -1;
    svc->cfg.http_compat_auto_urlencode = -1;
    svc->cfg.proxy_protocol_v1 = -1;
    svc->cfg.health_check = -1;
    svc->cfg.health_expect_status = -1;
    svc->listen_fd = -1;
    atomic_init(&svc->clients, 0);
    atomic_init(&svc->accepted_total, 0);
    atomic_init(&svc->rejected_total, 0);
    atomic_init(&svc->failover_total, 0);
    atomic_init(&svc->completed_total, 0);
    atomic_init(&svc->http_compat_rewrite_total, 0);
    atomic_init(&svc->http_compat_urlencode_total, 0);
    atomic_init(&svc->active_health_http_status, 0);
    atomic_init(&svc->standby_health_http_status, 0);
}

static int parse_section(const char *path, unsigned long lineno, char *p,
                         enum section_type *section,
                         struct service **current,
                         struct app_config *app)
{
    size_t len = strlen(p);
    char *inside;

    if (len < 3 || p[0] != '[' || p[len - 1] != ']')
        return 0;

    p[len - 1] = '\0';
    inside = trim(p + 1);

    if (strcmp(inside, "global") == 0) {
        *section = SEC_GLOBAL;
        *current = NULL;
        return 1;
    }

    if (strncmp(inside, "service:", 8) == 0) {
        const char *name = inside + 8;
        size_t i;

        if (*name == '\0' || strlen(name) >= NAME_LEN) {
            fprintf(stderr, "%s:%lu: invalid service section name\n", path, lineno);
            return -1;
        }
        if (app->service_count >= MAX_SERVICES) {
            fprintf(stderr, "%s:%lu: too many services (max %d)\n",
                    path, lineno, MAX_SERVICES);
            return -1;
        }
        for (i = 0; i < app->service_count; i++) {
            if (strcmp(app->services[i].cfg.name, name) == 0) {
                fprintf(stderr, "%s:%lu: duplicate service name '%s'\n",
                        path, lineno, name);
                return -1;
            }
        }

        *current = &app->services[app->service_count++];
        service_raw_init(*current, name);
        *section = SEC_SERVICE;
        return 1;
    }

    fprintf(stderr, "%s:%lu: unknown section [%s]\n", path, lineno, inside);
    return -1;
}

static int parse_global_key(const char *path, unsigned long lineno,
                            const char *key, const char *value,
                            struct app_config *app)
{
    struct defaults_cfg *d = &app->defaults;

    if (strcmp(key, "listen_host") == 0)
        return copy_string(path, lineno, key, d->listen_host, sizeof(d->listen_host), value);
    if (strcmp(key, "check_interval_ms") == 0)
        return parse_int_at(path, lineno, key, value, 100, 600000, &d->check_interval_ms);
    if (strcmp(key, "connect_timeout_ms") == 0)
        return parse_int_at(path, lineno, key, value, 100, 60000, &d->connect_timeout_ms);
    if (strcmp(key, "fall") == 0)
        return parse_int_at(path, lineno, key, value, 1, 100, &d->fall);
    if (strcmp(key, "rise") == 0)
        return parse_int_at(path, lineno, key, value, 1, 100, &d->rise);
    if (strcmp(key, "idle_timeout_sec") == 0)
        return parse_int_at(path, lineno, key, value, 0, 86400, &d->idle_timeout_sec);
    if (strcmp(key, "backlog") == 0)
        return parse_int_at(path, lineno, key, value, 16, 65535, &d->backlog);
    if (strcmp(key, "service_max_clients") == 0)
        return parse_int_at(path, lineno, key, value, 1, 1000000, &d->service_max_clients);
    if (strcmp(key, "max_clients_total") == 0)
        return parse_int_at(path, lineno, key, value, 1, 1000000, &d->max_clients_total);
    if (strcmp(key, "worker_threads") == 0)
        return parse_int_at(path, lineno, key, value, 1, MAX_WORKERS, &d->worker_threads);
    if (strcmp(key, "shutdown_grace_sec") == 0)
        return parse_int_at(path, lineno, key, value, 0, 3600, &d->shutdown_grace_sec);
    if (strcmp(key, "startup_health_wait_ms") == 0)
        return parse_int_at(path, lineno, key, value, 0, 60000, &d->startup_health_wait_ms);
    if (strcmp(key, "health_stagger_ms") == 0)
        return parse_int_at(path, lineno, key, value, 0, 10000, &d->health_stagger_ms);
    if (strcmp(key, "tcp_keepalive_idle_sec") == 0)
        return parse_int_at(path, lineno, key, value, 1, 86400, &d->tcp_keepalive_idle_sec);
    if (strcmp(key, "tcp_keepalive_interval_sec") == 0)
        return parse_int_at(path, lineno, key, value, 1, 3600, &d->tcp_keepalive_interval_sec);
    if (strcmp(key, "tcp_keepalive_count") == 0)
        return parse_int_at(path, lineno, key, value, 1, 100, &d->tcp_keepalive_count);
    if (strcmp(key, "http_compat_text_query") == 0)
        return parse_bool_at(path, lineno, key, value, &d->http_compat_text_query);
    if (strcmp(key, "http_compat_auto_urlencode") == 0)
        return parse_bool_at(path, lineno, key, value, &d->http_compat_auto_urlencode);
    if (strcmp(key, "proxy_protocol_v1") == 0)
        return parse_bool_at(path, lineno, key, value, &d->proxy_protocol_v1);
    if (strcmp(key, "health_check") == 0)
        return parse_health_check_at(path, lineno, key, value, &d->health_check);
    if (strcmp(key, "health_path") == 0)
        return copy_health_path(path, lineno, key, d->health_path, sizeof(d->health_path), value);
    if (strcmp(key, "health_expect_status") == 0)
        return parse_int_at(path, lineno, key, value, 100, 599, &d->health_expect_status);

    fprintf(stderr, "%s:%lu: unknown global key '%s'\n", path, lineno, key);
    return -1;
}

static int parse_service_key(const char *path, unsigned long lineno,
                             struct service *svc,
                             const char *key, const char *value)
{
    struct service_cfg *c = &svc->cfg;

    if (strcmp(key, "listen_host") == 0)
        return copy_string(path, lineno, key, c->listen_host, sizeof(c->listen_host), value);
    if (strcmp(key, "listen_port") == 0)
        return copy_string(path, lineno, key, c->listen_port, sizeof(c->listen_port), value);
    if (strcmp(key, "active_host") == 0)
        return copy_string(path, lineno, key, c->active_host, sizeof(c->active_host), value);
    if (strcmp(key, "active_port") == 0)
        return copy_string(path, lineno, key, c->active_port, sizeof(c->active_port), value);
    if (strcmp(key, "standby_host") == 0)
        return copy_string(path, lineno, key, c->standby_host, sizeof(c->standby_host), value);
    if (strcmp(key, "standby_port") == 0)
        return copy_string(path, lineno, key, c->standby_port, sizeof(c->standby_port), value);
    if (strcmp(key, "check_interval_ms") == 0)
        return parse_int_at(path, lineno, key, value, 100, 600000, &c->check_interval_ms);
    if (strcmp(key, "connect_timeout_ms") == 0)
        return parse_int_at(path, lineno, key, value, 100, 60000, &c->connect_timeout_ms);
    if (strcmp(key, "fall") == 0)
        return parse_int_at(path, lineno, key, value, 1, 100, &c->fall);
    if (strcmp(key, "rise") == 0)
        return parse_int_at(path, lineno, key, value, 1, 100, &c->rise);
    if (strcmp(key, "idle_timeout_sec") == 0)
        return parse_int_at(path, lineno, key, value, 0, 86400, &c->idle_timeout_sec);
    if (strcmp(key, "backlog") == 0)
        return parse_int_at(path, lineno, key, value, 16, 65535, &c->backlog);
    if (strcmp(key, "max_clients") == 0)
        return parse_int_at(path, lineno, key, value, 1, 1000000, &c->max_clients);
    if (strcmp(key, "tcp_keepalive_idle_sec") == 0)
        return parse_int_at(path, lineno, key, value, 1, 86400, &c->tcp_keepalive_idle_sec);
    if (strcmp(key, "tcp_keepalive_interval_sec") == 0)
        return parse_int_at(path, lineno, key, value, 1, 3600, &c->tcp_keepalive_interval_sec);
    if (strcmp(key, "tcp_keepalive_count") == 0)
        return parse_int_at(path, lineno, key, value, 1, 100, &c->tcp_keepalive_count);
    if (strcmp(key, "http_compat_text_query") == 0)
        return parse_bool_at(path, lineno, key, value, &c->http_compat_text_query);
    if (strcmp(key, "http_compat_auto_urlencode") == 0)
        return parse_bool_at(path, lineno, key, value, &c->http_compat_auto_urlencode);
    if (strcmp(key, "proxy_protocol_v1") == 0)
        return parse_bool_at(path, lineno, key, value, &c->proxy_protocol_v1);
    if (strcmp(key, "health_check") == 0)
        return parse_health_check_at(path, lineno, key, value, &c->health_check);
    if (strcmp(key, "health_path") == 0)
        return copy_health_path(path, lineno, key, c->health_path, sizeof(c->health_path), value);
    if (strcmp(key, "health_expect_status") == 0)
        return parse_int_at(path, lineno, key, value, 100, 599, &c->health_expect_status);

    fprintf(stderr, "%s:%lu: unknown key '%s' in service '%s'\n",
            path, lineno, key, c->name);
    return -1;
}

static void apply_service_defaults(struct service *svc, const struct app_config *app)
{
    struct service_cfg *c = &svc->cfg;
    const struct defaults_cfg *d = &app->defaults;

    if (c->listen_host[0] == '\0')
        snprintf(c->listen_host, sizeof(c->listen_host), "%s", d->listen_host);
    if (c->check_interval_ms < 0) c->check_interval_ms = d->check_interval_ms;
    if (c->connect_timeout_ms < 0) c->connect_timeout_ms = d->connect_timeout_ms;
    if (c->fall < 0) c->fall = d->fall;
    if (c->rise < 0) c->rise = d->rise;
    if (c->idle_timeout_sec < 0) c->idle_timeout_sec = d->idle_timeout_sec;
    if (c->backlog < 0) c->backlog = d->backlog;
    if (c->max_clients < 0) c->max_clients = d->service_max_clients;
    if (c->tcp_keepalive_idle_sec < 0) c->tcp_keepalive_idle_sec = d->tcp_keepalive_idle_sec;
    if (c->tcp_keepalive_interval_sec < 0) c->tcp_keepalive_interval_sec = d->tcp_keepalive_interval_sec;
    if (c->tcp_keepalive_count < 0) c->tcp_keepalive_count = d->tcp_keepalive_count;
    if (c->http_compat_text_query < 0) c->http_compat_text_query = d->http_compat_text_query;
    if (c->http_compat_auto_urlencode < 0) c->http_compat_auto_urlencode = d->http_compat_auto_urlencode;
    if (c->proxy_protocol_v1 < 0) c->proxy_protocol_v1 = d->proxy_protocol_v1;
    if (c->health_check < 0) c->health_check = d->health_check;
    if (c->health_path[0] == '\0')
        snprintf(c->health_path, sizeof(c->health_path), "%s", d->health_path);
    if (c->health_expect_status < 0) c->health_expect_status = d->health_expect_status;
}

static int validate_service(const char *path, struct service *svc, size_t index,
                            const struct app_config *app)
{
    struct service_cfg *c = &svc->cfg;
    size_t i;

    if (c->listen_port[0] == '\0' || c->active_host[0] == '\0' ||
        c->active_port[0] == '\0' || c->standby_host[0] == '\0' ||
        c->standby_port[0] == '\0') {
        fprintf(stderr,
                "%s: service '%s' requires listen_port, active_host, active_port, standby_host, standby_port\n",
                path, c->name);
        return -1;
    }

    if (c->http_compat_auto_urlencode && !c->http_compat_text_query) {
        fprintf(stderr,
                "%s: service '%s' http_compat_auto_urlencode=yes requires http_compat_text_query=yes\n",
                path, c->name);
        return -1;
    }
    if (c->health_check != HEALTH_CHECK_TCP && c->health_check != HEALTH_CHECK_HTTP) {
        fprintf(stderr, "%s: service '%s' has invalid health_check value\n", path, c->name);
        return -1;
    }
    if (c->health_check == HEALTH_CHECK_HTTP) {
        const unsigned char *hp = (const unsigned char *)c->health_path;
        if (c->health_path[0] != '/' || c->health_expect_status < 100 ||
            c->health_expect_status > 599) {
            fprintf(stderr, "%s: service '%s' invalid HTTP health configuration\n",
                    path, c->name);
            return -1;
        }
        while (*hp) {
            if (*hp <= 0x20 || *hp == 0x7f) {
                fprintf(stderr, "%s: service '%s' health_path contains spaces/control characters\n",
                        path, c->name);
                return -1;
            }
            hp++;
        }
    }

    for (i = 0; i < index; i++) {
        const struct service_cfg *o = &app->services[i].cfg;
        if (strcmp(c->listen_host, o->listen_host) == 0 &&
            strcmp(c->listen_port, o->listen_port) == 0) {
            fprintf(stderr, "%s: duplicate listener %s:%s in services '%s' and '%s'\n",
                    path, c->listen_host, c->listen_port, o->name, c->name);
            return -1;
        }
    }

    if (strcmp(c->active_host, c->standby_host) == 0 &&
        strcmp(c->active_port, c->standby_port) == 0) {
        fprintf(stderr, "%s: service '%s' active and standby endpoints are identical (%s:%s)\n",
                path, c->name, c->active_host, c->active_port);
        return -1;
    }

    if (strcmp(c->listen_port, c->active_port) == 0 &&
        (strcmp(c->active_host, c->listen_host) == 0 ||
         strcmp(c->active_host, "127.0.0.1") == 0 ||
         strcmp(c->active_host, "::1") == 0 ||
         strcmp(c->active_host, "localhost") == 0) &&
        (strcmp(c->listen_host, "0.0.0.0") == 0 || strcmp(c->listen_host, "::") == 0 ||
         strcmp(c->listen_host, "*") == 0 || strcmp(c->active_host, c->listen_host) == 0)) {
        fprintf(stderr, "%s: service '%s' active endpoint appears to loop back to its own listener\n",
                path, c->name);
        return -1;
    }
    if (strcmp(c->listen_port, c->standby_port) == 0 &&
        (strcmp(c->standby_host, c->listen_host) == 0 ||
         strcmp(c->standby_host, "127.0.0.1") == 0 ||
         strcmp(c->standby_host, "::1") == 0 ||
         strcmp(c->standby_host, "localhost") == 0) &&
        (strcmp(c->listen_host, "0.0.0.0") == 0 || strcmp(c->listen_host, "::") == 0 ||
         strcmp(c->listen_host, "*") == 0 || strcmp(c->standby_host, c->listen_host) == 0)) {
        fprintf(stderr, "%s: service '%s' standby endpoint appears to loop back to its own listener\n",
                path, c->name);
        return -1;
    }

    return 0;
}

static void destroy_config_unstarted(struct app_config *app, size_t mutexes_initialized)
{
    size_t i;
    if (!app) return;
    for (i = 0; i < mutexes_initialized; i++)
        pthread_mutex_destroy(&app->services[i].state.lock);
    free(app);
}

static struct app_config *load_config(const char *path)
{
    FILE *fp;
    char line[2048];
    unsigned long lineno = 0;
    enum section_type section = SEC_NONE;
    struct service *current = NULL;
    struct app_config *app = calloc(1, sizeof(*app));
    size_t i, mutexes_initialized = 0;

    if (!app) {
        fprintf(stderr, "%s: out of memory\n", path);
        return NULL;
    }
    defaults_init(&app->defaults);
    atomic_init(&app->health_running, true);

    fp = fopen(path, "r");
    if (!fp) {
        perror(path);
        free(app);
        return NULL;
    }

    while (fgets(line, sizeof(line), fp)) {
        char *p, *eq, *key, *value;
        int sr;
        lineno++;
        p = trim(line);
        if (*p == '\0' || *p == '#' || *p == ';')
            continue;

        if (*p == '[') {
            sr = parse_section(path, lineno, p, &section, &current, app);
            if (sr < 0) goto bad;
            if (sr > 0) continue;
        }

        eq = strchr(p, '=');
        if (!eq) {
            fprintf(stderr, "%s:%lu: expected key=value\n", path, lineno);
            goto bad;
        }
        *eq = '\0';
        key = trim(p);
        value = trim(eq + 1);

        if (section == SEC_NONE) {
            if (app->service_count != 0) {
                fprintf(stderr, "%s:%lu: unexpected sectionless key '%s'\n",
                        path, lineno, key);
                goto bad;
            }
            current = &app->services[app->service_count++];
            service_raw_init(current, "legacy");
            section = SEC_SERVICE;
            if (parse_service_key(path, lineno, current, key, value) < 0) goto bad;
        } else if (section == SEC_GLOBAL) {
            if (parse_global_key(path, lineno, key, value, app) < 0) goto bad;
        } else if (section == SEC_SERVICE && current) {
            if (parse_service_key(path, lineno, current, key, value) < 0) goto bad;
        } else {
            fprintf(stderr, "%s:%lu: key '%s' must be inside [global] or [service:NAME]\n",
                    path, lineno, key);
            goto bad;
        }
    }

    fclose(fp);
    fp = NULL;

    if (app->service_count == 0) {
        fprintf(stderr, "%s: no [service:NAME] sections configured\n", path);
        goto bad_no_fp;
    }

    for (i = 0; i < app->service_count; i++) {
        apply_service_defaults(&app->services[i], app);
        if (validate_service(path, &app->services[i], i, app) < 0)
            goto bad_no_fp;
        if (resolve_endpoint(app->services[i].cfg.active_host,
                             app->services[i].cfg.active_port,
                             &app->services[i].active_resolved) < 0) {
            fprintf(stderr, "%s: service '%s' cannot resolve active endpoint %s:%s\n",
                    path, app->services[i].cfg.name,
                    app->services[i].cfg.active_host, app->services[i].cfg.active_port);
            goto bad_no_fp;
        }
        if (resolve_endpoint(app->services[i].cfg.standby_host,
                             app->services[i].cfg.standby_port,
                             &app->services[i].standby_resolved) < 0) {
            fprintf(stderr, "%s: service '%s' cannot resolve standby endpoint %s:%s\n",
                    path, app->services[i].cfg.name,
                    app->services[i].cfg.standby_host, app->services[i].cfg.standby_port);
            goto bad_no_fp;
        }
        if (pthread_mutex_init(&app->services[i].state.lock, NULL) != 0) {
            fprintf(stderr, "%s: cannot initialize service '%s' mutex\n",
                    path, app->services[i].cfg.name);
            goto bad_no_fp;
        }
        mutexes_initialized++;
        app->services[i].state.selected = BACKEND_DOWN;
        app->services[i].owner = app;
    }

    return app;

bad:
    fclose(fp);
bad_no_fp:
    destroy_config_unstarted(app, mutexes_initialized);
    return NULL;
}

static int set_nonblocking(int fd, bool enabled)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0)
        return -1;
    if (enabled) flags |= O_NONBLOCK;
    else flags &= ~O_NONBLOCK;
    return fcntl(fd, F_SETFL, flags);
}

static void tune_tcp_socket(int fd, const struct service_cfg *cfg)
{
    int one = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    (void)setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
#ifdef TCP_KEEPIDLE
    if (cfg)
        (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE,
                         &cfg->tcp_keepalive_idle_sec, sizeof(cfg->tcp_keepalive_idle_sec));
#endif
#ifdef TCP_KEEPINTVL
    if (cfg)
        (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL,
                         &cfg->tcp_keepalive_interval_sec, sizeof(cfg->tcp_keepalive_interval_sec));
#endif
#ifdef TCP_KEEPCNT
    if (cfg)
        (void)setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT,
                         &cfg->tcp_keepalive_count, sizeof(cfg->tcp_keepalive_count));
#endif
}

static bool health_generation_running(const struct app_config *app)
{
    return g_running && app && atomic_load(&app->health_running);
}

static int resolve_endpoint(const char *host, const char *port,
                            struct resolved_endpoint *out)
{
    struct addrinfo hints, *res = NULL, *ai;
    int gai;

    memset(out, 0, sizeof(*out));
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    gai = getaddrinfo(host, port, &hints, &res);
    if (gai != 0)
        return -1;

    for (ai = res; ai && out->count < MAX_RESOLVED_ADDRS; ai = ai->ai_next) {
        struct endpoint_addr *dst;
        if (ai->ai_addrlen > sizeof(struct sockaddr_storage))
            continue;
        dst = &out->addr[out->count++];
        memset(dst, 0, sizeof(*dst));
        memcpy(&dst->ss, ai->ai_addr, ai->ai_addrlen);
        dst->len = (socklen_t)ai->ai_addrlen;
        dst->family = ai->ai_family;
        dst->socktype = ai->ai_socktype;
        dst->protocol = ai->ai_protocol;
    }
    freeaddrinfo(res);
    return out->count > 0 ? 0 : -1;
}

static int connect_one_resolved(const struct endpoint_addr *ea, int timeout_ms,
                                const atomic_bool *run_flag)
{
    int fd, rc, soerr = 0;
    int remaining = timeout_ms;
    socklen_t slen = sizeof(soerr);
    struct pollfd pfd;

    fd = socket(ea->family, ea->socktype | SOCK_CLOEXEC, ea->protocol);
    if (fd < 0)
        return -1;

    if (set_nonblocking(fd, true) < 0) {
        close(fd);
        return -1;
    }

    rc = connect(fd, (const struct sockaddr *)&ea->ss, ea->len);
    if (rc == 0) {
        tune_tcp_socket(fd, NULL);
        return fd;
    }
    if (errno != EINPROGRESS) {
        close(fd);
        return -1;
    }

    pfd.fd = fd;
    pfd.events = POLLOUT;
    pfd.revents = 0;

    rc = 0;
    while (remaining > 0 && g_running) {
        int slice = remaining > 100 ? 100 : remaining;
        if (run_flag && !atomic_load(run_flag))
            break;
        pfd.revents = 0;
        rc = poll(&pfd, 1, slice);
        if (rc > 0)
            break;
        if (rc < 0 && errno != EINTR)
            break;
        if (rc == 0)
            remaining -= slice;
    }

    if (rc <= 0 || !g_running || (run_flag && !atomic_load(run_flag))) {
        close(fd);
        errno = ETIMEDOUT;
        return -1;
    }
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) < 0 || soerr != 0) {
        close(fd);
        errno = soerr ? soerr : errno;
        return -1;
    }

    tune_tcp_socket(fd, NULL);
    return fd;
}

static int connect_resolved_endpoint_ex(const struct resolved_endpoint *ep,
                                        int timeout_ms,
                                        const atomic_bool *run_flag)
{
    size_t i;
    for (i = 0; i < ep->count; i++) {
        int fd;
        if (run_flag && !atomic_load(run_flag))
            break;
        fd = connect_one_resolved(&ep->addr[i], timeout_ms, run_flag);
        if (fd >= 0)
            return fd;
    }
    return -1;
}

static const char *health_check_name(int type)
{
    return type == HEALTH_CHECK_HTTP ? "http" : "tcp";
}

static int wait_fd_ready(int fd, short events, int64_t deadline_ms,
                         const atomic_bool *run_flag)
{
    struct pollfd pfd;

    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = fd;
    pfd.events = events;

    for (;;) {
        int64_t now = monotonic_ms();
        int64_t remain = deadline_ms - now;
        int timeout, rc;

        if (!g_running || (run_flag && !atomic_load(run_flag))) {
            errno = ECANCELED;
            return -1;
        }
        if (remain <= 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        timeout = remain > 100 ? 100 : (int)remain;
        pfd.revents = 0;
        rc = poll(&pfd, 1, timeout);
        if (rc > 0) {
            /* A peer may send the complete HTTP status line and FIN in the
             * same scheduling window, producing POLLIN|POLLHUP. Consume the
             * readable data first; HUP alone is a failure. */
            if (pfd.revents & events)
                return 0;
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                errno = ECONNRESET;
                return -1;
            }
            continue;
        }
        if (rc == 0)
            continue;
        if (errno == EINTR)
            continue;
        return -1;
    }
}

static int health_send_all(int fd, const char *buf, size_t len,
                           int64_t deadline_ms, const atomic_bool *run_flag)
{
    size_t off = 0;

    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, MSG_NOSIGNAL);
        if (n > 0) {
            off += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_fd_ready(fd, POLLOUT, deadline_ms, run_flag) < 0)
                return -1;
            continue;
        }
        return -1;
    }
    return 0;
}

static int health_read_status(int fd, int64_t deadline_ms,
                              const atomic_bool *run_flag)
{
    char buf[HEALTH_HTTP_RESPONSE_MAX + 1];
    size_t used = 0;

    while (used < HEALTH_HTTP_RESPONSE_MAX) {
        ssize_t n;
        char *eol;
        int status = 0;
        char version[16];

        if (wait_fd_ready(fd, POLLIN, deadline_ms, run_flag) < 0)
            return -1;
        n = recv(fd, buf + used, HEALTH_HTTP_RESPONSE_MAX - used, 0);
        if (n > 0) {
            used += (size_t)n;
            buf[used] = '\0';
            eol = strstr(buf, "\r\n");
            if (!eol)
                eol = strchr(buf, '\n');
            if (!eol)
                continue;
            *eol = '\0';
            if (sscanf(buf, "%15s %d", version, &status) != 2 ||
                strncmp(version, "HTTP/1.", 7) != 0 ||
                status < 100 || status > 599) {
                errno = EPROTO;
                return -1;
            }
            return status;
        }
        if (n == 0) {
            errno = ECONNRESET;
            return -1;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            continue;
        return -1;
    }
    errno = EMSGSIZE;
    return -1;
}

static bool check_endpoint(struct service *svc, enum backend_state which)
{
    const struct resolved_endpoint *ep =
        (which == BACKEND_ACTIVE) ? &svc->active_resolved : &svc->standby_resolved;
    const char *host = (which == BACKEND_ACTIVE) ? svc->cfg.active_host : svc->cfg.standby_host;
    const char *port = (which == BACKEND_ACTIVE) ? svc->cfg.active_port : svc->cfg.standby_port;
    atomic_int *last_status = (which == BACKEND_ACTIVE) ?
        &svc->active_health_http_status : &svc->standby_health_http_status;
    int fd = connect_resolved_endpoint_ex(ep, svc->cfg.connect_timeout_ms,
                                          &svc->owner->health_running);

    if (fd < 0) {
        atomic_store(last_status, 0);
        return false;
    }

    if (svc->cfg.health_check == HEALTH_CHECK_TCP) {
        atomic_store(last_status, 0);
        close(fd);
        return true;
    }

    {
        char request[2048];
        char host_header[HOST_LEN + PORT_LEN + 8];
        int n, status;
        int64_t deadline = monotonic_ms() + svc->cfg.connect_timeout_ms;

        if (strchr(host, ':') && host[0] != '[')
            n = snprintf(host_header, sizeof(host_header), "[%s]:%s", host, port);
        else
            n = snprintf(host_header, sizeof(host_header), "%s:%s", host, port);
        if (n < 0 || (size_t)n >= sizeof(host_header)) {
            close(fd);
            atomic_store(last_status, 0);
            return false;
        }

        n = snprintf(request, sizeof(request),
                     "GET %s HTTP/1.1\r\n"
                     "Host: %s\r\n"
                     "User-Agent: %s/%s health-check\r\n"
                     "Accept: application/json, */*\r\n"
                     "Connection: close\r\n\r\n",
                     svc->cfg.health_path, host_header,
                     PROGRAM_NAME, PROGRAM_VERSION);
        if (n < 0 || (size_t)n >= sizeof(request) ||
            health_send_all(fd, request, (size_t)n, deadline,
                            &svc->owner->health_running) < 0) {
            close(fd);
            atomic_store(last_status, 0);
            return false;
        }

        status = health_read_status(fd, deadline, &svc->owner->health_running);
        close(fd);
        atomic_store(last_status, status > 0 ? status : 0);
        return status == svc->cfg.health_expect_status;
    }
}

static void health_apply(struct service *svc, struct health_status *hs, bool ok)
{
    if (!hs->initialized) {
        hs->initialized = true;
        hs->up = ok;
        hs->consecutive_success = ok ? 1 : 0;
        hs->consecutive_failure = ok ? 0 : 1;
        return;
    }

    if (ok) {
        hs->consecutive_failure = 0;
        if (hs->consecutive_success < 1000000)
            hs->consecutive_success++;
        if (!hs->up && hs->consecutive_success >= svc->cfg.rise)
            hs->up = true;
    } else {
        hs->consecutive_success = 0;
        if (hs->consecutive_failure < 1000000)
            hs->consecutive_failure++;
        if (hs->up && hs->consecutive_failure >= svc->cfg.fall)
            hs->up = false;
    }
}

static const char *state_name(enum backend_state s)
{
    switch (s) {
    case BACKEND_ACTIVE: return "ACTIVE";
    case BACKEND_STANDBY: return "STANDBY";
    default: return "DOWN";
    }
}

static enum backend_state choose_locked(struct service *svc)
{
    if (svc->state.active.up) return BACKEND_ACTIVE;
    if (svc->state.standby.up) return BACKEND_STANDBY;
    return BACKEND_DOWN;
}

static void log_state_changes_locked(struct service *svc,
                                     bool old_active_up, bool old_standby_up,
                                     enum backend_state old_selected)
{
    enum backend_state next = choose_locked(svc);

    svc->state.selected = next;

    if (old_active_up != svc->state.active.up) {
        log_msg(svc->state.active.up ? LOG_NOTICE : LOG_WARNING,
                "service=%s listen=%s:%s backend=active address=%s:%s state=%s health_check=%s health_http_status=%d",
                svc->cfg.name, svc->cfg.listen_host, svc->cfg.listen_port,
                svc->cfg.active_host, svc->cfg.active_port,
                svc->state.active.up ? "UP" : "DOWN",
                health_check_name(svc->cfg.health_check),
                atomic_load(&svc->active_health_http_status));
    }
    if (old_standby_up != svc->state.standby.up) {
        log_msg(svc->state.standby.up ? LOG_NOTICE : LOG_WARNING,
                "service=%s listen=%s:%s backend=standby address=%s:%s state=%s health_check=%s health_http_status=%d",
                svc->cfg.name, svc->cfg.listen_host, svc->cfg.listen_port,
                svc->cfg.standby_host, svc->cfg.standby_port,
                svc->state.standby.up ? "UP" : "DOWN",
                health_check_name(svc->cfg.health_check),
                atomic_load(&svc->standby_health_http_status));
    }
    if (old_selected != next) {
        log_msg(next == BACKEND_DOWN ? LOG_ERR : LOG_NOTICE,
                "service=%s listen=%s:%s selected_backend=%s",
                svc->cfg.name, svc->cfg.listen_host, svc->cfg.listen_port,
                state_name(next));
    }
}

static void update_health(struct service *svc, bool active_ok, bool standby_ok)
{
    bool old_active_up, old_standby_up;
    enum backend_state old_selected;

    pthread_mutex_lock(&svc->state.lock);
    old_active_up = svc->state.active.up;
    old_standby_up = svc->state.standby.up;
    old_selected = svc->state.selected;

    health_apply(svc, &svc->state.active, active_ok);
    health_apply(svc, &svc->state.standby, standby_ok);
    log_state_changes_locked(svc, old_active_up, old_standby_up, old_selected);
    pthread_mutex_unlock(&svc->state.lock);
}

static void update_runtime_result(struct service *svc,
                                  enum backend_state which, bool ok)
{
    bool old_active_up, old_standby_up;
    enum backend_state old_selected;
    struct health_status *hs;

    if (which != BACKEND_ACTIVE && which != BACKEND_STANDBY)
        return;

    /* In HTTP health mode, only the application-level health probe may
     * transition a backend back to UP. A successful client TCP connect does
     * not prove /ready is healthy. TCP failures still count as failures. */
    if (ok && svc->cfg.health_check == HEALTH_CHECK_HTTP)
        return;

    pthread_mutex_lock(&svc->state.lock);
    old_active_up = svc->state.active.up;
    old_standby_up = svc->state.standby.up;
    old_selected = svc->state.selected;
    hs = (which == BACKEND_ACTIVE) ? &svc->state.active : &svc->state.standby;
    health_apply(svc, hs, ok);
    log_state_changes_locked(svc, old_active_up, old_standby_up, old_selected);
    pthread_mutex_unlock(&svc->state.lock);
}

static void sleep_interruptible_ms(struct app_config *app, int ms)
{
    const int slice = 100;
    int remaining = ms;
    while (health_generation_running(app) && remaining > 0) {
        struct timespec ts;
        int this_ms = remaining < slice ? remaining : slice;
        ts.tv_sec = this_ms / 1000;
        ts.tv_nsec = (long)(this_ms % 1000) * 1000000L;
        while (nanosleep(&ts, &ts) < 0 && errno == EINTR &&
               health_generation_running(app))
            ;
        remaining -= this_ms;
    }
}

static void *health_thread(void *arg)
{
    struct service *svc = arg;
    struct app_config *app = svc->owner;

    if (app->defaults.health_stagger_ms > 0) {
        unsigned long hash = 5381;
        const unsigned char *p = (const unsigned char *)svc->cfg.name;
        int delay;
        while (*p)
            hash = ((hash << 5) + hash) ^ *p++;
        delay = (int)(hash % (unsigned long)(app->defaults.health_stagger_ms + 1));
        if (delay > 0)
            sleep_interruptible_ms(app, delay);
    }

    while (health_generation_running(app)) {
        bool active_ok = check_endpoint(svc, BACKEND_ACTIVE);
        bool standby_ok;
        if (!health_generation_running(app))
            break;
        standby_ok = check_endpoint(svc, BACKEND_STANDBY);
        if (!health_generation_running(app))
            break;
        update_health(svc, active_ok, standby_ok);
        sleep_interruptible_ms(app, svc->cfg.check_interval_ms);
    }
    return NULL;
}

static int create_listener(const char *host, const char *port, int backlog)
{
    struct addrinfo hints, *res = NULL, *ai;
    int fd = -1, gai, one = 1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = AI_PASSIVE;

    gai = getaddrinfo((host && strcmp(host, "*") != 0) ? host : NULL,
                      port, &hints, &res);
    if (gai != 0) {
        fprintf(stderr, "getaddrinfo listen %s:%s: %s\n", host, port, gai_strerror(gai));
        return -1;
    }

    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
        if (fd < 0)
            continue;
        (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (ai->ai_family == AF_INET6)
            (void)setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, backlog) == 0)
            break;
        close(fd);
        fd = -1;
    }

    freeaddrinfo(res);
    if (fd >= 0 && set_nonblocking(fd, true) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static enum backend_state get_selected_backend(struct service *svc)
{
    enum backend_state s;
    pthread_mutex_lock(&svc->state.lock);
    s = svc->state.selected;
    pthread_mutex_unlock(&svc->state.lock);
    return s;
}

static bool backend_health_up(struct service *svc, enum backend_state which)
{
    bool up = false;

    pthread_mutex_lock(&svc->state.lock);
    if (which == BACKEND_ACTIVE)
        up = svc->state.active.initialized && svc->state.active.up;
    else if (which == BACKEND_STANDBY)
        up = svc->state.standby.initialized && svc->state.standby.up;
    pthread_mutex_unlock(&svc->state.lock);
    return up;
}

static const struct resolved_endpoint *backend_endpoint(const struct service *svc,
                                                        enum backend_state which)
{
    return (which == BACKEND_ACTIVE) ? &svc->active_resolved : &svc->standby_resolved;
}

static int64_t monotonic_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
        return 0;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int sd_notify_send(const char *message)
{
    const char *path = getenv("NOTIFY_SOCKET");
    struct sockaddr_un sa;
    socklen_t salen;
    int fd, rc;
    size_t plen;

    if (!path || !*path || !message)
        return 0;
    plen = strlen(path);
    if (plen >= sizeof(sa.sun_path))
        return -1;

    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    if (path[0] == '@') {
        sa.sun_path[0] = '\0';
        memcpy(sa.sun_path + 1, path + 1, plen - 1);
        salen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + plen);
    } else {
        memcpy(sa.sun_path, path, plen + 1);
        salen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + plen + 1);
    }

    fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return -1;
    rc = sendto(fd, message, strlen(message), MSG_NOSIGNAL,
                (struct sockaddr *)&sa, salen) < 0 ? -1 : 1;
    close(fd);
    return rc;
}

static void watchdog_init_from_env(void)
{
    const char *usec_s = getenv("WATCHDOG_USEC");
    const char *pid_s = getenv("WATCHDOG_PID");
    unsigned long long usec;
    char *end = NULL;

    if (pid_s && *pid_s) {
        long p = strtol(pid_s, &end, 10);
        if (!end || *end != '\0' || p != (long)getpid())
            return;
    }
    if (!usec_s || !*usec_s)
        return;
    errno = 0;
    usec = strtoull(usec_s, &end, 10);
    if (errno || end == usec_s || *end != '\0' || usec < 1000000ULL)
        return;
    g_watchdog_interval_ms = (int64_t)(usec / 1000ULL / 2ULL);
    if (g_watchdog_interval_ms < 250)
        g_watchdog_interval_ms = 250;
    g_watchdog_last_notify_ms = 0;
}

static bool workers_healthy(int64_t now)
{
    int i;
    if (atomic_load(&g_worker_failed))
        return false;
    for (i = 0; i < g_worker_count; i++) {
        int64_t hb = atomic_load(&g_workers[i].last_heartbeat_ms);
        if (hb > 0 && now - hb > 3000)
            return false;
    }
    return true;
}

static void watchdog_tick(void)
{
    int64_t now;
    if (g_watchdog_interval_ms <= 0)
        return;
    now = monotonic_ms();
    if (g_watchdog_last_notify_ms != 0 &&
        now - g_watchdog_last_notify_ms < g_watchdog_interval_ms)
        return;
    if (!workers_healthy(now)) {
        log_msg(LOG_CRIT, "watchdog_worker_health_failed action=terminate_for_restart");
        g_exit_code = 1;
        g_running = 0;
        return;
    }
    if (sd_notify_send("WATCHDOG=1") > 0)
        g_watchdog_last_notify_ms = now;
}

static void reset_client_connection(int fd)
{
    struct linger ling = { .l_onoff = 1, .l_linger = 0 };
    (void)setsockopt(fd, SOL_SOCKET, SO_LINGER, &ling, sizeof(ling));
}

static void buffer_compact(struct io_buffer *b)
{
    if (b->len == 0) {
        b->off = 0;
        return;
    }
    if (b->off > 0 && b->off + b->len == IO_BUF_SIZE) {
        memmove(b->data, b->data + b->off, b->len);
        b->off = 0;
    }
}

static int buffer_recv_drain(int fd, struct io_buffer *b, bool *activity)
{
    for (;;) {
        ssize_t n;
        size_t pos, room;

        buffer_compact(b);
        pos = b->off + b->len;
        room = IO_BUF_SIZE - pos;
        if (room == 0)
            return 0;

        n = recv(fd, b->data + pos, room, 0);
        if (n > 0) {
            b->len += (size_t)n;
            *activity = true;
            continue;
        }
        if (n == 0) {
            b->src_eof = true;
            return 0;
        }
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        return -1;
    }
}

static int buffer_send_drain(int fd, struct io_buffer *b, bool *activity)
{
    while (b->len > 0) {
        ssize_t n = send(fd, b->data + b->off, b->len, MSG_NOSIGNAL);
        if (n > 0) {
            b->off += (size_t)n;
            b->len -= (size_t)n;
            *activity = true;
            if (b->len == 0)
                b->off = 0;
            continue;
        }
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return 0;
        return -1;
    }
    return 0;
}

static void maybe_half_close(int dst_fd, struct io_buffer *b)
{
    if (dst_fd >= 0 && b->src_eof && b->len == 0 && !b->dst_shutdown) {
        (void)shutdown(dst_fd, SHUT_WR);
        b->dst_shutdown = true;
    }
}

static int worker_epoll_add(struct worker *w, int fd, struct worker_event *wev,
                            uint32_t events)
{
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = events;
    ev.data.ptr = wev;
    return epoll_ctl(w->epoll_fd, EPOLL_CTL_ADD, fd, &ev);
}

static int worker_epoll_mod(struct worker *w, int fd, struct worker_event *wev,
                            uint32_t events)
{
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = events;
    ev.data.ptr = wev;
    return epoll_ctl(w->epoll_fd, EPOLL_CTL_MOD, fd, &ev);
}

static void session_link(struct worker *w, struct session *s)
{
    s->prev_active = NULL;
    s->next_active = w->sessions;
    if (w->sessions)
        w->sessions->prev_active = s;
    w->sessions = s;
}

static void session_unlink(struct worker *w, struct session *s)
{
    if (s->prev_active)
        s->prev_active->next_active = s->next_active;
    else if (w->sessions == s)
        w->sessions = s->next_active;
    if (s->next_active)
        s->next_active->prev_active = s->prev_active;
    s->prev_active = NULL;
    s->next_active = NULL;
}

static void session_close_deferred(struct session *s, const char *reason)
{
    struct worker *w;

    if (!s || s->closing)
        return;
    s->closing = true;
    w = s->worker;

    if (s->client_fd >= 0) {
        (void)epoll_ctl(w->epoll_fd, EPOLL_CTL_DEL, s->client_fd, NULL);
        close(s->client_fd);
        s->client_fd = -1;
    }
    if (s->backend_fd >= 0) {
        (void)epoll_ctl(w->epoll_fd, EPOLL_CTL_DEL, s->backend_fd, NULL);
        close(s->backend_fd);
        s->backend_fd = -1;
    }

    session_unlink(w, s);
    atomic_fetch_sub(&s->svc->clients, 1);
    atomic_fetch_sub(&g_clients_total, 1);
    atomic_fetch_add(&s->svc->completed_total, 1);
    atomic_fetch_add(&g_completed_total, 1);

    if (reason) {
        log_msg(LOG_DEBUG,
                "service=%s client=%s connection_close reason=%s service_clients=%d total_clients=%d",
                s->svc->cfg.name, s->peer, reason,
                atomic_load(&s->svc->clients), atomic_load(&g_clients_total));
    }

    s->next_gc = w->gc_head;
    w->gc_head = s;
}

static void worker_reap_gc(struct worker *w)
{
    struct session *s = w->gc_head;
    w->gc_head = NULL;
    while (s) {
        struct session *next = s->next_gc;
        free(s);
        s = next;
    }
}

static bool query_has_text_parameter(const char *q)
{
    const char *p = q;
    while (p && *p) {
        const char *end = strchr(p, '&');
        size_t n = end ? (size_t)(end - p) : strlen(p);
        if (n >= 5 && strncmp(p, "text=", 5) == 0)
            return true;
        if (!end)
            break;
        p = end + 1;
    }
    return false;
}

/*
 * Parse an HTTP/1.x request line while optionally tolerating raw spaces in
 * the request-target.  Strict HTTP requires exactly one SP separator around
 * the target and forbids raw spaces inside it, but some monitoring tools can
 * emit a line such as:
 *
 *   POST /?text=<b>WARNING</b> Disk usage > 90% HTTP/1.1
 *
 * When compatibility mode is explicitly enabled we recover the target by
 * taking everything between the first separator after METHOD and the final
 * separator before HTTP/1.x.  The caller can then percent-encode the target
 * before forwarding it to the backend.
 */
static int parse_request_line_compat(const char *line,
                                     char *method, size_t method_cap,
                                     char *target, size_t target_cap,
                                     char *version, size_t version_cap,
                                     bool *had_raw_space)
{
    const char *first_sp, *last_sp, *target_start, *target_end;
    size_t mlen, tlen, vlen;
    const char *p;

    if (!line || !method || !target || !version || !had_raw_space)
        return -1;

    first_sp = strchr(line, ' ');
    last_sp = strrchr(line, ' ');
    if (!first_sp || !last_sp || first_sp == last_sp)
        return -1;

    mlen = (size_t)(first_sp - line);
    if (mlen == 0 || mlen >= method_cap)
        return -1;

    target_start = first_sp + 1;
    while (*target_start == ' ')
        target_start++;

    target_end = last_sp;
    while (target_end > target_start && target_end[-1] == ' ')
        target_end--;

    if (target_end <= target_start)
        return -1;

    tlen = (size_t)(target_end - target_start);
    vlen = strlen(last_sp + 1);
    if (tlen >= target_cap || vlen == 0 || vlen >= version_cap)
        return -1;

    memcpy(method, line, mlen);
    method[mlen] = '\0';
    memcpy(target, target_start, tlen);
    target[tlen] = '\0';
    memcpy(version, last_sp + 1, vlen + 1);

    *had_raw_space = false;
    for (p = target; *p; p++) {
        if (*p == ' ' || *p == '\t') {
            *had_raw_space = true;
            break;
        }
    }

    return 0;
}

static bool is_hex_pair(const char *p)
{
    return p && p[0] == '%' && isxdigit((unsigned char)p[1]) &&
           isxdigit((unsigned char)p[2]);
}

/*
 * Conservative application/x-www-form-urlencoded query sanitizer.
 *
 * Preserve:
 *   - RFC3986 unreserved bytes [A-Za-z0-9-._~]
 *   - '&' and '=' as query/form separators
 *   - '+' for already form-encoded spaces
 *   - existing valid %HH triplets (prevents double-encoding)
 *
 * Percent-encode everything else, including raw SP, '<', '>', '/', '%'
 * (when '%' is not followed by two hex digits), and non-ASCII UTF-8 bytes.
 */
static bool compat_query_known_separator(const char *p)
{
    if (!p || *p != '&')
        return false;
    p++;
    return strncasecmp(p, "text=", 5) == 0 ||
           strncasecmp(p, "parse_mode=", 11) == 0;
}

static int percent_encode_query_compat(const char *src,
                                       char *dst, size_t dst_cap,
                                       bool *changed)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t si = 0, di = 0;

    if (!src || !dst || dst_cap == 0 || !changed)
        return -1;

    *changed = false;

    while (src[si] != '\0') {
        unsigned char c = (unsigned char)src[si];

        if (c == '%' && src[si + 1] != '\0' && src[si + 2] != '\0' &&
            is_hex_pair(src + si)) {
            if (di + 3 >= dst_cap)
                return -1;
            dst[di++] = src[si++];
            dst[di++] = src[si++];
            dst[di++] = src[si++];
            continue;
        }

        /* Preserve only the compatibility fields we explicitly support.
         * Raw '&' inside text is data and must be %26. A '+' in a URI query
         * is a literal plus, so convert it to %2B before the query becomes an
         * application/x-www-form-urlencoded request body. */
        if (c == '&' && compat_query_known_separator(src + si)) {
            if (di + 1 >= dst_cap)
                return -1;
            dst[di++] = '&';
            si++;
            continue;
        }

        if (((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
             (c >= '0' && c <= '9')) || c == '-' || c == '.' || c == '_' ||
            c == '~' || c == '=') {
            if (di + 1 >= dst_cap)
                return -1;
            dst[di++] = (char)c;
            si++;
            continue;
        }

        if (di + 3 >= dst_cap)
            return -1;
        dst[di++] = '%';
        dst[di++] = hex[(c >> 4) & 0x0f];
        dst[di++] = hex[c & 0x0f];
        si++;
        *changed = true;
    }

    dst[di] = '\0';
    return 0;
}

static bool session_c2b_forward_ready(const struct session *s);

static int build_proxy_v1_line(int client_fd, char *out, size_t out_cap)
{
    struct sockaddr_storage src, dst;
    socklen_t src_len = sizeof(src), dst_len = sizeof(dst);
    char src_host[64], dst_host[64], src_port[16], dst_port[16];
    const char *proto;
    int n;

    if (!out || out_cap == 0U) return -1;
    if (getpeername(client_fd, (struct sockaddr *)&src, &src_len) < 0 ||
        getsockname(client_fd, (struct sockaddr *)&dst, &dst_len) < 0)
        return -1;

    if (src.ss_family == AF_INET && dst.ss_family == AF_INET)
        proto = "TCP4";
    else if (src.ss_family == AF_INET6 && dst.ss_family == AF_INET6)
        proto = "TCP6";
    else {
        n = snprintf(out, out_cap, "PROXY UNKNOWN\r\n");
        return (n > 0 && (size_t)n < out_cap) ? n : -1;
    }

    if (getnameinfo((const struct sockaddr *)&src, src_len,
                    src_host, sizeof(src_host), src_port, sizeof(src_port),
                    NI_NUMERICHOST | NI_NUMERICSERV) != 0 ||
        getnameinfo((const struct sockaddr *)&dst, dst_len,
                    dst_host, sizeof(dst_host), dst_port, sizeof(dst_port),
                    NI_NUMERICHOST | NI_NUMERICSERV) != 0)
        return -1;

    n = snprintf(out, out_cap, "PROXY %s %s %s %s %s\r\n",
                 proto, src_host, dst_host, src_port, dst_port);
    if (n <= 0 || (size_t)n >= out_cap || n > 107)
        return -1;
    return n;
}

static bool session_backend_write_needed(const struct session *s)
{
    if (!s) return false;
    if (s->proxy_line_off < s->proxy_line_len) return true;
    return s->c2b.len > 0 && session_c2b_forward_ready(s);
}

static int session_send_backend_pending(struct session *s, bool *activity)
{
    while (s->proxy_line_off < s->proxy_line_len) {
        ssize_t n = send(s->backend_fd,
                         s->proxy_line + s->proxy_line_off,
                         s->proxy_line_len - s->proxy_line_off,
                         MSG_NOSIGNAL);
        if (n > 0) {
            s->proxy_line_off += (size_t)n;
            *activity = true;
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        return -1;
    }
    if (s->c2b.len > 0 && session_c2b_forward_ready(s))
        return buffer_send_drain(s->backend_fd, &s->c2b, activity);
    return 0;
}

static bool session_c2b_forward_ready(const struct session *s)
{
    return !s->svc->cfg.http_compat_text_query || s->http_compat_decided;
}

/*
 * Optional compatibility shim for legacy/monitoring clients.
 * It only touches the first request on services where
 * http_compat_text_query=yes. Matching forms:
 *
 *   GET  /?text=... HTTP/1.x
 *   POST /?text=... HTTP/1.x  (missing Content-Length or Content-Length: 0)
 *
 * They are normalized to:
 *
 *   POST /sendMessage HTTP/1.1
 *   Content-Type: application/x-www-form-urlencoded
 *   X-TG-Compat-Text-Query: 1
 *   X-TG-Compat-Original-Method: GET|POST
 *   Content-Length: <query length>
 *   Connection: close
 *
 *   text=...
 *
 * Non-matching traffic is released unchanged. This keeps the normal mode
 * a transparent L4 proxy and makes compatibility explicitly opt-in.
 */
static int session_http_compat_maybe_normalize(struct session *s)
{
    struct io_buffer *b = &s->c2b;
    const unsigned char *base;
    const unsigned char *marker;
    size_t header_len, extra_len;
    char header[IO_BUF_SIZE + 1];
    char output[IO_BUF_SIZE];
    char encoded_query[IO_BUF_SIZE];
    char method[16], target[HTTP_COMPAT_MAX_TARGET], version[16];
    char host_value[512] = "";
    char idempotency_value[129] = "";
    char parse_mode_value[64] = "";
    char *save = NULL, *line;
    const char *query, *query_to_send;
    bool have_cl = false, have_te = false;
    bool raw_target_space = false, query_encoded = false;
    unsigned long long content_length = 0;
    size_t outlen = 0, qlen;
    int n;

    if (!s->svc->cfg.http_compat_text_query || s->http_compat_decided)
        return 1;

    if (b->off != 0) {
        memmove(b->data, b->data + b->off, b->len);
        b->off = 0;
    }
    base = b->data;

    /* Quickly release obvious non-HTTP traffic. */
    if (b->len >= 5 && memcmp(base, "GET ", 4) != 0 && memcmp(base, "POST ", 5) != 0) {
        s->http_compat_decided = true;
        return 1;
    }

    marker = memmem(base, b->len, "\r\n\r\n", 4);
    if (!marker) {
        if (b->src_eof || b->len == IO_BUF_SIZE) {
            s->http_compat_decided = true;
            return 1;
        }
        return 0;
    }

    header_len = (size_t)(marker - base) + 4;
    extra_len = b->len - header_len;
    if (header_len > IO_BUF_SIZE) {
        s->http_compat_decided = true;
        return 1;
    }

    memcpy(header, base, header_len);
    header[header_len] = '\0';

    line = strtok_r(header, "\r\n", &save);
    if (!line || parse_request_line_compat(line,
                                           method, sizeof(method),
                                           target, sizeof(target),
                                           version, sizeof(version),
                                           &raw_target_space) < 0) {
        s->http_compat_decided = true;
        return 1;
    }

    if (strcasecmp(method, "GET") != 0 && strcasecmp(method, "POST") != 0) {
        s->http_compat_decided = true;
        return 1;
    }
    if (strncmp(version, "HTTP/1.", 7) != 0) {
        s->http_compat_decided = true;
        return 1;
    }

    /* Raw SP/TAB in request-target is invalid HTTP. Only tolerate it when
     * auto-urlencoding is explicitly enabled on this service. */
    if (raw_target_space && !s->svc->cfg.http_compat_auto_urlencode) {
        s->http_compat_decided = true;
        return 1;
    }

    if (strncmp(target, "/?", 2) == 0)
        query = target + 2;
    else if (strncmp(target, "/sendMessage?", 13) == 0)
        query = target + 13;
    else {
        s->http_compat_decided = true;
        return 1;
    }

    if (*query == '\0' || !query_has_text_parameter(query)) {
        s->http_compat_decided = true;
        return 1;
    }

    query_to_send = query;
    if (s->svc->cfg.http_compat_auto_urlencode) {
        if (percent_encode_query_compat(query,
                                        encoded_query, sizeof(encoded_query),
                                        &query_encoded) < 0) {
            log_msg(LOG_WARNING,
                    "service=%s listen=%s:%s client=%s http_compat_urlencode_failed reason=encoded_query_too_large",
                    s->svc->cfg.name, s->svc->cfg.listen_host,
                    s->svc->cfg.listen_port, s->peer);
            s->http_compat_decided = true;
            return 1;
        }
        query_to_send = encoded_query;
    }

    while ((line = strtok_r(NULL, "\r\n", &save)) != NULL) {
        char *colon = strchr(line, ':');
        char *name, *value, *end = NULL;
        unsigned long long v;

        if (!colon)
            continue;
        *colon = '\0';
        name = trim(line);
        value = trim(colon + 1);
        if (strcasecmp(name, "Transfer-Encoding") == 0) {
            have_te = true;
        } else if (strcasecmp(name, "Host") == 0) {
            if (strlen(value) < sizeof(host_value))
                snprintf(host_value, sizeof(host_value), "%s", value);
        } else if (strcasecmp(name, "X-Idempotency-Key") == 0) {
            size_t j, vlen = strlen(value);
            bool safe = vlen > 0U && vlen < sizeof(idempotency_value);
            for (j = 0U; safe && j < vlen; j++) {
                unsigned char c = (unsigned char)value[j];
                if (c < 0x21U || c > 0x7eU) safe = false;
            }
            if (safe)
                snprintf(idempotency_value, sizeof(idempotency_value), "%s", value);
        } else if (strcasecmp(name, "X-Parse-Mode") == 0) {
            if (strlen(value) > 0U && strlen(value) < sizeof(parse_mode_value))
                snprintf(parse_mode_value, sizeof(parse_mode_value), "%s", value);
        } else if (strcasecmp(name, "Content-Length") == 0) {
            errno = 0;
            v = strtoull(value, &end, 10);
            if (errno != 0 || end == value) {
                s->http_compat_decided = true;
                return 1;
            }
            while (*end == ' ' || *end == '\t') end++;
            if (*end != '\0') {
                s->http_compat_decided = true;
                return 1;
            }
            have_cl = true;
            content_length = v;
        }
    }

    if (have_te || extra_len != 0) {
        s->http_compat_decided = true;
        return 1;
    }
    if (strcasecmp(method, "POST") == 0 && have_cl && content_length != 0) {
        s->http_compat_decided = true;
        return 1;
    }

    qlen = strlen(query_to_send);
    n = snprintf(output, sizeof(output),
                 "POST /sendMessage HTTP/1.1\r\n"
                 "%s%s%s"
                 "Content-Type: application/x-www-form-urlencoded\r\n"
                 "X-TG-Compat-Text-Query: 1\r\n"
                 "X-TG-Compat-Original-Method: %s\r\n"
                 "%s%s%s"
                 "%s%s%s"
                 "Content-Length: %zu\r\n"
                 "Connection: close\r\n"
                 "\r\n",
                 host_value[0] ? "Host: " : "",
                 host_value[0] ? host_value : "",
                 host_value[0] ? "\r\n" : "",
                 method,
                 idempotency_value[0] ? "X-Idempotency-Key: " : "",
                 idempotency_value[0] ? idempotency_value : "",
                 idempotency_value[0] ? "\r\n" : "",
                 parse_mode_value[0] ? "X-Parse-Mode: " : "",
                 parse_mode_value[0] ? parse_mode_value : "",
                 parse_mode_value[0] ? "\r\n" : "",
                 qlen);
    if (n < 0 || (size_t)n >= sizeof(output) || (size_t)n + qlen > sizeof(output)) {
        s->http_compat_decided = true;
        return 1;
    }
    outlen = (size_t)n;
    memcpy(output + outlen, query_to_send, qlen);
    outlen += qlen;

    memcpy(b->data, output, outlen);
    b->off = 0;
    b->len = outlen;
    s->http_compat_decided = true;
    s->http_compat_rewritten = true;
    atomic_fetch_add(&s->svc->http_compat_rewrite_total, 1);

    if (query_encoded) {
        atomic_fetch_add(&s->svc->http_compat_urlencode_total, 1);
        log_msg(LOG_INFO,
                "service=%s listen=%s:%s client=%s http_compat_auto_urlencode raw_query_bytes=%zu encoded_query_bytes=%zu",
                s->svc->cfg.name, s->svc->cfg.listen_host,
                s->svc->cfg.listen_port, s->peer,
                strlen(query), qlen);
    }

    log_msg(LOG_INFO,
            "service=%s listen=%s:%s client=%s http_compat_rewrite original_method=%s normalized_endpoint=/sendMessage query_bytes=%zu",
            s->svc->cfg.name, s->svc->cfg.listen_host, s->svc->cfg.listen_port,
            s->peer, method, qlen);
    return 1;
}

static int session_refresh_events(struct session *s)
{
    uint32_t cevents = EPOLLRDHUP | EPOLLERR;
    uint32_t bevents;

    if (s->closing)
        return -1;

    if (!s->c2b.src_eof && s->c2b.len < IO_BUF_SIZE)
        cevents |= EPOLLIN;
    if (s->b2c.len > 0)
        cevents |= EPOLLOUT;

    if (worker_epoll_mod(s->worker, s->client_fd, &s->client_event, cevents) < 0)
        return -1;

    if (s->backend_fd < 0)
        return 0;

    if (s->state == SESSION_CONNECTING) {
        bevents = EPOLLOUT | EPOLLRDHUP | EPOLLERR;
    } else {
        bevents = EPOLLRDHUP | EPOLLERR;
        if (!s->b2c.src_eof && s->b2c.len < IO_BUF_SIZE)
            bevents |= EPOLLIN;
        if (session_backend_write_needed(s))
            bevents |= EPOLLOUT;
    }

    if (worker_epoll_mod(s->worker, s->backend_fd, &s->backend_event, bevents) < 0)
        return -1;
    return 0;
}

static void session_log_open(struct session *s)
{
    log_msg(LOG_INFO,
            "service=%s listen=%s:%s client=%s connection_open backend=%s worker=%d service_clients=%d total_clients=%d",
            s->svc->cfg.name, s->svc->cfg.listen_host, s->svc->cfg.listen_port,
            s->peer, state_name(s->connected_backend), s->worker->id,
            atomic_load(&s->svc->clients), atomic_load(&g_clients_total));
}

static int session_start_connect_current(struct session *s);

static void session_backend_failed(struct session *s, const char *why)
{
    const struct resolved_endpoint *ep;

    if (s->backend_fd >= 0) {
        (void)epoll_ctl(s->worker->epoll_fd, EPOLL_CTL_DEL, s->backend_fd, NULL);
        close(s->backend_fd);
        s->backend_fd = -1;
    }

    ep = backend_endpoint(s->svc, s->attempt_backend);
    s->address_index++;
    if (s->address_index < ep->count) {
        if (session_start_connect_current(s) == 0)
            return;
    }
    update_runtime_result(s->svc, s->attempt_backend, false);

    if (!s->fallback_started) {
        enum backend_state old = s->attempt_backend;
        s->fallback_started = true;
        atomic_fetch_add(&s->svc->failover_total, 1);
        atomic_fetch_add(&g_failover_total, 1);
        s->attempt_backend = s->fallback_backend;
        s->address_index = 0;
        if (s->svc->cfg.health_check == HEALTH_CHECK_HTTP &&
            !backend_health_up(s->svc, s->attempt_backend)) {
            log_msg(LOG_WARNING,
                    "service=%s listen=%s:%s client=%s runtime_connect_failed backend=%s fallback=%s skipped=application_not_ready reason=%s",
                    s->svc->cfg.name, s->svc->cfg.listen_host, s->svc->cfg.listen_port,
                    s->peer, state_name(old), state_name(s->attempt_backend), why);
        } else {
            log_msg(LOG_WARNING,
                    "service=%s listen=%s:%s client=%s runtime_connect_failed backend=%s trying=%s reason=%s",
                    s->svc->cfg.name, s->svc->cfg.listen_host, s->svc->cfg.listen_port,
                    s->peer, state_name(old), state_name(s->attempt_backend), why);
            if (session_start_connect_current(s) == 0)
                return;
            update_runtime_result(s->svc, s->attempt_backend, false);
        }
    }

    log_msg(LOG_WARNING,
            "service=%s listen=%s:%s client=%s rejected=no_reachable_backend",
            s->svc->cfg.name, s->svc->cfg.listen_host, s->svc->cfg.listen_port,
            s->peer);
    atomic_fetch_add(&s->svc->rejected_total, 1);
    atomic_fetch_add(&g_rejected_total, 1);
    reset_client_connection(s->client_fd);
    session_close_deferred(s, "no_reachable_backend");
}

static int session_start_connect_current(struct session *s)
{
    const struct resolved_endpoint *ep = backend_endpoint(s->svc, s->attempt_backend);

    /* A new backend connection must receive a fresh PROXY header. */
    s->proxy_line_off = 0;

    while (s->address_index < ep->count) {
        const struct endpoint_addr *ea = &ep->addr[s->address_index];
        int fd = socket(ea->family,
                        ea->socktype | SOCK_NONBLOCK | SOCK_CLOEXEC,
                        ea->protocol);
        int rc;

        if (fd < 0) {
            s->address_index++;
            continue;
        }
        tune_tcp_socket(fd, &s->svc->cfg);
        rc = connect(fd, (const struct sockaddr *)&ea->ss, ea->len);
        if (rc == 0) {
            s->backend_fd = fd;
            s->state = SESSION_RELAY;
            s->connected_backend = s->attempt_backend;
            s->last_activity_ms = monotonic_ms();
            update_runtime_result(s->svc, s->attempt_backend, true);
            s->backend_event.kind = WORKER_EVENT_BACKEND;
            s->backend_event.session = s;
            if (worker_epoll_add(s->worker, fd, &s->backend_event,
                                 EPOLLRDHUP | EPOLLERR |
                                 (session_backend_write_needed(s) ? EPOLLOUT : 0) | EPOLLIN) < 0) {
                close(fd);
                s->backend_fd = -1;
                return -1;
            }
            session_log_open(s);
            if (session_refresh_events(s) < 0)
                return -1;
            return 0;
        }
        if (errno == EINPROGRESS) {
            s->backend_fd = fd;
            s->state = SESSION_CONNECTING;
            s->connect_deadline_ms = monotonic_ms() + s->svc->cfg.connect_timeout_ms;
            s->backend_event.kind = WORKER_EVENT_BACKEND;
            s->backend_event.session = s;
            if (worker_epoll_add(s->worker, fd, &s->backend_event,
                                 EPOLLOUT | EPOLLRDHUP | EPOLLERR) < 0) {
                close(fd);
                s->backend_fd = -1;
                return -1;
            }
            return 0;
        }

        close(fd);
        s->address_index++;
    }
    return -1;
}

static void session_connect_completed(struct session *s)
{
    int err = 0;
    socklen_t len = sizeof(err);

    if (s->closing || s->state != SESSION_CONNECTING || s->backend_fd < 0)
        return;

    if (getsockopt(s->backend_fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0)
        err = errno;

    if (err != 0) {
        session_backend_failed(s, strerror(err));
        return;
    }

    s->state = SESSION_RELAY;
    s->connected_backend = s->attempt_backend;
    s->last_activity_ms = monotonic_ms();
    update_runtime_result(s->svc, s->attempt_backend, true);
    session_log_open(s);
    if (session_refresh_events(s) < 0)
        session_close_deferred(s, "epoll_mod_failed");
}

static void session_maybe_finish(struct session *s)
{
    if (s->closing || s->state != SESSION_RELAY)
        return;

    if (s->proxy_line_off >= s->proxy_line_len)
        maybe_half_close(s->backend_fd, &s->c2b);
    maybe_half_close(s->client_fd, &s->b2c);

    if (s->proxy_line_off >= s->proxy_line_len &&
        s->c2b.src_eof && s->b2c.src_eof &&
        s->c2b.len == 0 && s->b2c.len == 0) {
        session_close_deferred(s, "eof");
        return;
    }

    if (session_refresh_events(s) < 0)
        session_close_deferred(s, "epoll_mod_failed");
}

static void log_epoll_socket_error(struct session *s, const char *side,
                                   int fd, uint32_t events)
{
    int err = 0;
    socklen_t len = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) < 0)
        err = errno;
    log_msg(LOG_WARNING,
            "service=%s client=%s side=%s socket_error errno=%d error=%s epoll_events=0x%x backend=%s",
            s->svc->cfg.name, s->peer, side, err,
            err ? strerror(err) : "unknown", events,
            state_name(s->connected_backend));
}

static void session_handle_client_event(struct session *s, uint32_t events)
{
    bool activity = false;

    if (!s || s->closing)
        return;

    if (events & EPOLLERR) {
        log_epoll_socket_error(s, "client", s->client_fd, events);
        session_close_deferred(s, "client_error");
        return;
    }

    if ((events & EPOLLIN) ||
        ((events & (EPOLLRDHUP | EPOLLHUP)) && !s->c2b.src_eof &&
         s->c2b.len < IO_BUF_SIZE)) {
        if (buffer_recv_drain(s->client_fd, &s->c2b, &activity) < 0) {
            session_close_deferred(s, "client_read_error");
            return;
        }
        (void)session_http_compat_maybe_normalize(s);
    }
    if ((events & EPOLLOUT) && s->state == SESSION_RELAY) {
        if (buffer_send_drain(s->client_fd, &s->b2c, &activity) < 0) {
            session_close_deferred(s, "client_write_error");
            return;
        }
    }
    /* EPOLLRDHUP/EPOLLHUP can arrive while unread bytes are still queued.
     * EOF is authoritative only when recv() returns 0 in buffer_recv_drain(). */

    if (activity)
        s->last_activity_ms = monotonic_ms();

    if (s->state == SESSION_RELAY) {
        if (session_backend_write_needed(s)) {
            if (session_send_backend_pending(s, &activity) < 0) {
                session_close_deferred(s, "backend_write_error");
                return;
            }
        }
        if (activity)
            s->last_activity_ms = monotonic_ms();
        session_maybe_finish(s);
    } else if (session_refresh_events(s) < 0) {
        session_close_deferred(s, "epoll_mod_failed");
    }
}

static void session_handle_backend_event(struct session *s, uint32_t events)
{
    bool activity = false;

    if (!s || s->closing)
        return;

    if (s->state == SESSION_CONNECTING) {
        if (events & (EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLRDHUP))
            session_connect_completed(s);
        return;
    }

    if (events & EPOLLERR) {
        log_epoll_socket_error(s, "backend", s->backend_fd, events);
        session_close_deferred(s, "backend_error");
        return;
    }

    if ((events & EPOLLIN) ||
        ((events & (EPOLLRDHUP | EPOLLHUP)) && !s->b2c.src_eof &&
         s->b2c.len < IO_BUF_SIZE)) {
        if (buffer_recv_drain(s->backend_fd, &s->b2c, &activity) < 0) {
            session_close_deferred(s, "backend_read_error");
            return;
        }
    }
    if ((events & EPOLLOUT) && session_backend_write_needed(s)) {
        if (session_send_backend_pending(s, &activity) < 0) {
            session_close_deferred(s, "backend_write_error");
            return;
        }
    }
    /* As above, do not infer EOF solely from RDHUP/HUP. Drain recv() to 0. */

    if (s->b2c.len > 0) {
        if (buffer_send_drain(s->client_fd, &s->b2c, &activity) < 0) {
            session_close_deferred(s, "client_write_error");
            return;
        }
    }
    if (activity)
        s->last_activity_ms = monotonic_ms();
    session_maybe_finish(s);
}

static int session_create(struct worker *w, struct pending_conn *p)
{
    struct session *s = calloc(1, sizeof(*s));
    enum backend_state preferred;

    if (!s)
        return -1;
    s->client_fd = p->client_fd;
    s->backend_fd = -1;
    s->svc = p->svc;
    s->worker = w;
    s->connected_backend = BACKEND_DOWN;
    s->http_compat_decided = !s->svc->cfg.http_compat_text_query;
    s->http_compat_rewritten = false;
    s->last_activity_ms = monotonic_ms();
    snprintf(s->peer, sizeof(s->peer), "%s", p->peer);
    if (s->svc->cfg.proxy_protocol_v1) {
        int pn = build_proxy_v1_line(s->client_fd, s->proxy_line, sizeof(s->proxy_line));
        if (pn < 0) {
            log_msg(LOG_WARNING,
                    "service=%s client=%s proxy_protocol_v1_build_failed error=%s",
                    s->svc->cfg.name, s->peer, strerror(errno));
            free(s);
            return -1;
        }
        s->proxy_line_len = (size_t)pn;
        s->proxy_line_off = 0;
    }
    s->client_event.kind = WORKER_EVENT_CLIENT;
    s->client_event.session = s;
    s->backend_event.kind = WORKER_EVENT_BACKEND;
    s->backend_event.session = s;

    preferred = get_selected_backend(s->svc);
    if (s->svc->cfg.health_check == HEALTH_CHECK_HTTP &&
        preferred == BACKEND_DOWN) {
        log_msg(LOG_WARNING,
                "service=%s listen=%s:%s client=%s rejected=no_application_ready_backend",
                s->svc->cfg.name, s->svc->cfg.listen_host,
                s->svc->cfg.listen_port, s->peer);
        atomic_fetch_add(&s->svc->rejected_total, 1);
        atomic_fetch_add(&g_rejected_total, 1);
        reset_client_connection(s->client_fd);
        close(s->client_fd);
        s->client_fd = -1;
        atomic_fetch_sub(&s->svc->clients, 1);
        atomic_fetch_sub(&g_clients_total, 1);
        atomic_fetch_add(&s->svc->completed_total, 1);
        atomic_fetch_add(&g_completed_total, 1);
        free(s);
        return 0;
    }
    if (preferred == BACKEND_STANDBY) {
        s->attempt_backend = BACKEND_STANDBY;
        s->fallback_backend = BACKEND_ACTIVE;
    } else {
        s->attempt_backend = BACKEND_ACTIVE;
        s->fallback_backend = BACKEND_STANDBY;
    }

    session_link(w, s);
    if (worker_epoll_add(w, s->client_fd, &s->client_event,
                         EPOLLIN | EPOLLRDHUP | EPOLLERR) < 0) {
        session_close_deferred(s, "client_epoll_add_failed");
        return 0;
    }

    if (session_start_connect_current(s) < 0)
        session_backend_failed(s, "connect_start_failed");
    return 0;
}

static void worker_drain_pending(struct worker *w)
{
    struct pending_conn *head;

    pthread_mutex_lock(&w->queue_lock);
    head = w->queue_head;
    w->queue_head = NULL;
    w->queue_tail = NULL;
    pthread_mutex_unlock(&w->queue_lock);

    while (head) {
        struct pending_conn *next = head->next;
        if (!atomic_load(&w->running) || !g_running) {
            reset_client_connection(head->client_fd);
            close(head->client_fd);
            atomic_fetch_sub(&head->svc->clients, 1);
            atomic_fetch_sub(&g_clients_total, 1);
        } else if (session_create(w, head) < 0) {
            reset_client_connection(head->client_fd);
            close(head->client_fd);
            atomic_fetch_sub(&head->svc->clients, 1);
            atomic_fetch_sub(&g_clients_total, 1);
        }
        free(head);
        head = next;
    }
}

static void worker_handle_timer(struct worker *w)
{
    struct session *s = w->sessions;
    int64_t now = monotonic_ms();

    while (s) {
        struct session *next = s->next_active;
        if (!s->closing && s->state == SESSION_CONNECTING &&
            now >= s->connect_deadline_ms) {
            session_backend_failed(s, "connect_timeout");
        } else if (!s->closing && s->state == SESSION_RELAY &&
                   s->svc->cfg.idle_timeout_sec > 0 &&
                   now - s->last_activity_ms >=
                       (int64_t)s->svc->cfg.idle_timeout_sec * 1000) {
            session_close_deferred(s, "idle_timeout");
        }
        s = next;
    }
}

static void worker_close_all(struct worker *w)
{
    struct session *s = w->sessions;
    while (s) {
        struct session *next = s->next_active;
        session_close_deferred(s, "shutdown");
        s = next;
    }
    worker_reap_gc(w);

    pthread_mutex_lock(&w->queue_lock);
    while (w->queue_head) {
        struct pending_conn *p = w->queue_head;
        w->queue_head = p->next;
        reset_client_connection(p->client_fd);
        close(p->client_fd);
        atomic_fetch_sub(&p->svc->clients, 1);
        atomic_fetch_sub(&g_clients_total, 1);
        free(p);
    }
    w->queue_tail = NULL;
    pthread_mutex_unlock(&w->queue_lock);
}

static void *worker_thread(void *arg)
{
    struct worker *w = arg;
    struct epoll_event events[WORKER_MAX_EVENTS];

    while (g_running && atomic_load(&w->running)) {
        atomic_store(&w->last_heartbeat_ms, monotonic_ms());
        int n = epoll_wait(w->epoll_fd, events, WORKER_MAX_EVENTS, -1);
        int i;
        if (n < 0) {
            if (errno == EINTR)
                continue;
            log_msg(LOG_ERR, "worker=%d epoll_wait_failed error=%s", w->id, strerror(errno));
            atomic_store(&g_worker_failed, true);
            break;
        }

        for (i = 0; i < n; i++) {
            struct worker_event *wev = events[i].data.ptr;
            if (!wev)
                continue;
            switch (wev->kind) {
            case WORKER_EVENT_WAKE: {
                uint64_t value;
                while (read(w->wake_fd, &value, sizeof(value)) < 0 && errno == EINTR)
                    ;
                worker_drain_pending(w);
                break;
            }
            case WORKER_EVENT_TIMER: {
                uint64_t expirations;
                while (read(w->timer_fd, &expirations, sizeof(expirations)) < 0 && errno == EINTR)
                    ;
                worker_handle_timer(w);
                break;
            }
            case WORKER_EVENT_CLIENT:
                session_handle_client_event(wev->session, events[i].events);
                break;
            case WORKER_EVENT_BACKEND:
                session_handle_backend_event(wev->session, events[i].events);
                break;
            default:
                break;
            }
        }
        worker_reap_gc(w);
        atomic_store(&w->last_heartbeat_ms, monotonic_ms());
    }

    worker_close_all(w);
    return NULL;
}

static int worker_init(struct worker *w, int id)
{
    struct itimerspec its;

    memset(w, 0, sizeof(*w));
    w->id = id;
    w->epoll_fd = -1;
    w->wake_fd = -1;
    w->timer_fd = -1;
    atomic_init(&w->running, true);
    atomic_init(&w->last_heartbeat_ms, monotonic_ms());

    if (pthread_mutex_init(&w->queue_lock, NULL) != 0)
        return -1;

    w->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (w->epoll_fd < 0)
        goto fail;
    w->wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (w->wake_fd < 0)
        goto fail;
    w->timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (w->timer_fd < 0)
        goto fail;

    memset(&its, 0, sizeof(its));
    its.it_interval.tv_sec = WORKER_TIMER_MS / 1000;
    its.it_interval.tv_nsec = (long)(WORKER_TIMER_MS % 1000) * 1000000L;
    its.it_value = its.it_interval;
    if (timerfd_settime(w->timer_fd, 0, &its, NULL) < 0)
        goto fail;

    w->wake_event.kind = WORKER_EVENT_WAKE;
    w->wake_event.session = NULL;
    w->timer_event.kind = WORKER_EVENT_TIMER;
    w->timer_event.session = NULL;

    if (worker_epoll_add(w, w->wake_fd, &w->wake_event, EPOLLIN) < 0)
        goto fail;
    if (worker_epoll_add(w, w->timer_fd, &w->timer_event, EPOLLIN) < 0)
        goto fail;

    if (pthread_create(&w->tid, NULL, worker_thread, w) != 0)
        goto fail;
    w->started = true;
    return 0;

fail:
    if (w->timer_fd >= 0) close(w->timer_fd);
    if (w->wake_fd >= 0) close(w->wake_fd);
    if (w->epoll_fd >= 0) close(w->epoll_fd);
    w->timer_fd = w->wake_fd = w->epoll_fd = -1;
    pthread_mutex_destroy(&w->queue_lock);
    return -1;
}

static int start_workers(int count)
{
    int i;
    g_worker_count = 0;
    atomic_store(&g_next_worker, 0);
    for (i = 0; i < count; i++) {
        if (worker_init(&g_workers[i], i) < 0) {
            int j;
            log_msg(LOG_ERR, "worker=%d initialization_failed error=%s", i, strerror(errno));
            for (j = 0; j < i; j++) {
                uint64_t one = 1;
                atomic_store(&g_workers[j].running, false);
                (void)write(g_workers[j].wake_fd, &one, sizeof(one));
            }
            for (j = 0; j < i; j++) {
                if (g_workers[j].started)
                    pthread_join(g_workers[j].tid, NULL);
                if (g_workers[j].timer_fd >= 0) close(g_workers[j].timer_fd);
                if (g_workers[j].wake_fd >= 0) close(g_workers[j].wake_fd);
                if (g_workers[j].epoll_fd >= 0) close(g_workers[j].epoll_fd);
                pthread_mutex_destroy(&g_workers[j].queue_lock);
            }
            return -1;
        }
        g_worker_count++;
    }
    return 0;
}

static void stop_workers(void)
{
    int i;
    for (i = 0; i < g_worker_count; i++) {
        uint64_t one = 1;
        atomic_store(&g_workers[i].running, false);
        (void)write(g_workers[i].wake_fd, &one, sizeof(one));
    }
    for (i = 0; i < g_worker_count; i++) {
        if (g_workers[i].started)
            pthread_join(g_workers[i].tid, NULL);
        if (g_workers[i].timer_fd >= 0) close(g_workers[i].timer_fd);
        if (g_workers[i].wake_fd >= 0) close(g_workers[i].wake_fd);
        if (g_workers[i].epoll_fd >= 0) close(g_workers[i].epoll_fd);
        pthread_mutex_destroy(&g_workers[i].queue_lock);
        g_workers[i].started = false;
    }
    g_worker_count = 0;
}

static int worker_enqueue(struct worker *w, struct pending_conn *p)
{
    uint64_t one = 1;

    pthread_mutex_lock(&w->queue_lock);
    p->next = NULL;
    if (w->queue_tail)
        w->queue_tail->next = p;
    else
        w->queue_head = p;
    w->queue_tail = p;
    pthread_mutex_unlock(&w->queue_lock);

    if (write(w->wake_fd, &one, sizeof(one)) < 0 && errno != EAGAIN)
        return -1;
    return 0;
}

static void peer_to_string(const struct sockaddr_storage *ss, socklen_t slen,
                           char *out, size_t outsz)
{
    char host[64], serv[16];
    int rc = getnameinfo((const struct sockaddr *)ss, slen,
                         host, sizeof(host), serv, sizeof(serv),
                         NI_NUMERICHOST | NI_NUMERICSERV);
    if (rc == 0)
        snprintf(out, outsz, "%s:%s", host, serv);
    else
        snprintf(out, outsz, "unknown");
}

static void accept_ready(struct service *svc, const struct app_config *app)
{
    while (g_running) {
        struct sockaddr_storage ss;
        socklen_t slen = sizeof(ss);
        struct pending_conn *p;
        struct worker *w;
        unsigned int idx;
        int cfd = accept4(svc->listen_fd, (struct sockaddr *)&ss, &slen,
                          SOCK_CLOEXEC | SOCK_NONBLOCK);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return;
            if (errno == EINTR)
                continue;
            if (errno == EMFILE || errno == ENFILE) {
                struct sockaddr_storage drop_ss;
                socklen_t drop_len = sizeof(drop_ss);
                int drop_fd = -1;
                log_msg(LOG_ERR, "service=%s accept_failed=fd_limit reserve_fd_recovery=yes", svc->cfg.name);
                if (g_reserve_fd >= 0) {
                    close(g_reserve_fd);
                    g_reserve_fd = -1;
                    drop_fd = accept4(svc->listen_fd, (struct sockaddr *)&drop_ss, &drop_len,
                                      SOCK_CLOEXEC | SOCK_NONBLOCK);
                    if (drop_fd >= 0) {
                        reset_client_connection(drop_fd);
                        close(drop_fd);
                    }
                    g_reserve_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
                }
                return;
            }
            log_msg(LOG_WARNING, "service=%s accept_failed=%s",
                    svc->cfg.name, strerror(errno));
            return;
        }

        tune_tcp_socket(cfd, &svc->cfg);

        if (atomic_load(&g_clients_total) >= app->defaults.max_clients_total) {
            log_msg(LOG_WARNING,
                    "service=%s client_rejected=max_clients_total limit=%d",
                    svc->cfg.name, app->defaults.max_clients_total);
            atomic_fetch_add(&svc->rejected_total, 1);
            atomic_fetch_add(&g_rejected_total, 1);
            reset_client_connection(cfd);
            close(cfd);
            continue;
        }
        if (atomic_load(&svc->clients) >= svc->cfg.max_clients) {
            log_msg(LOG_WARNING,
                    "service=%s client_rejected=max_clients limit=%d",
                    svc->cfg.name, svc->cfg.max_clients);
            atomic_fetch_add(&svc->rejected_total, 1);
            atomic_fetch_add(&g_rejected_total, 1);
            reset_client_connection(cfd);
            close(cfd);
            continue;
        }

        p = calloc(1, sizeof(*p));
        if (!p) {
            atomic_fetch_add(&svc->rejected_total, 1);
            atomic_fetch_add(&g_rejected_total, 1);
            reset_client_connection(cfd);
            close(cfd);
            continue;
        }
        p->client_fd = cfd;
        p->svc = svc;
        peer_to_string(&ss, slen, p->peer, sizeof(p->peer));

        atomic_fetch_add(&svc->clients, 1);
        atomic_fetch_add(&svc->accepted_total, 1);
        atomic_fetch_add(&g_accepted_total, 1);
        atomic_fetch_add(&g_clients_total, 1);

        idx = atomic_fetch_add(&g_next_worker, 1);
        w = &g_workers[idx % (unsigned int)g_worker_count];
        if (worker_enqueue(w, p) < 0) {
            log_msg(LOG_ERR, "service=%s worker_enqueue_failed worker=%d error=%s",
                    svc->cfg.name, w->id, strerror(errno));
            /* The item is still queued if eventfd was saturated; only a hard
             * write error is expected during shutdown. Let the worker own it. */
        }
    }
}

static void handle_signal(int sig)
{
    if (sig == SIGHUP) {
        if (!g_shutdown_requested)
            g_reload_requested = 1;
        return;
    }
    if (sig == SIGUSR1) {
        g_stats_requested = 1;
        return;
    }
    if (g_shutdown_requested) {
        g_force_shutdown = 1;
        g_running = 0;
        return;
    }
    g_shutdown_requested = 1;
}

static int install_signals(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGTERM, &sa, NULL) < 0) return -1;
    if (sigaction(SIGINT, &sa, NULL) < 0) return -1;
    if (sigaction(SIGHUP, &sa, NULL) < 0) return -1;
    if (sigaction(SIGUSR1, &sa, NULL) < 0) return -1;
    signal(SIGPIPE, SIG_IGN);
    return 0;
}

static bool same_listener(const struct service_cfg *a, const struct service_cfg *b)
{
    return strcmp(a->listen_host, b->listen_host) == 0 &&
           strcmp(a->listen_port, b->listen_port) == 0;
}

static bool same_backends(const struct service_cfg *a, const struct service_cfg *b)
{
    return strcmp(a->active_host, b->active_host) == 0 &&
           strcmp(a->active_port, b->active_port) == 0 &&
           strcmp(a->standby_host, b->standby_host) == 0 &&
           strcmp(a->standby_port, b->standby_port) == 0;
}

static bool same_health_policy(const struct service_cfg *a,
                               const struct service_cfg *b)
{
    return a->health_check == b->health_check &&
           strcmp(a->health_path, b->health_path) == 0 &&
           a->health_expect_status == b->health_expect_status;
}

static struct service *find_listener(struct app_config *app,
                                     const struct service_cfg *cfg)
{
    size_t i;
    if (!app) return NULL;
    for (i = 0; i < app->service_count; i++) {
        if (same_listener(&app->services[i].cfg, cfg))
            return &app->services[i];
    }
    return NULL;
}

static void inherit_health_state(struct app_config *newapp,
                                 struct app_config *oldapp)
{
    size_t i;
    if (!oldapp) return;

    for (i = 0; i < newapp->service_count; i++) {
        struct service *newsvc = &newapp->services[i];
        struct service *oldsvc = find_listener(oldapp, &newsvc->cfg);
        if (!oldsvc || !same_backends(&newsvc->cfg, &oldsvc->cfg) ||
            !same_health_policy(&newsvc->cfg, &oldsvc->cfg))
            continue;

        pthread_mutex_lock(&oldsvc->state.lock);
        pthread_mutex_lock(&newsvc->state.lock);
        newsvc->state.active = oldsvc->state.active;
        newsvc->state.standby = oldsvc->state.standby;
        newsvc->state.selected = oldsvc->state.selected;
        atomic_store(&newsvc->active_health_http_status,
                     atomic_load(&oldsvc->active_health_http_status));
        atomic_store(&newsvc->standby_health_http_status,
                     atomic_load(&oldsvc->standby_health_http_status));
        pthread_mutex_unlock(&newsvc->state.lock);
        pthread_mutex_unlock(&oldsvc->state.lock);
    }
}

static void close_generation_listeners(struct app_config *app)
{
    size_t i;
    if (!app) return;
    for (i = 0; i < app->service_count; i++) {
        if (app->services[i].listen_fd >= 0) {
            close(app->services[i].listen_fd);
            app->services[i].listen_fd = -1;
        }
    }
}

static int prepare_generation_listeners(struct app_config *app,
                                        struct app_config *oldapp)
{
    size_t i;

    for (i = 0; i < app->service_count; i++) {
        struct service *svc = &app->services[i];
        struct service *oldsvc = find_listener(oldapp, &svc->cfg);
        int fd = -1;

        if (oldsvc && oldsvc->listen_fd >= 0) {
            fd = fcntl(oldsvc->listen_fd, F_DUPFD_CLOEXEC, 3);
            if (fd >= 0) {
                svc->listen_fd = fd;
                log_msg(LOG_INFO,
                        "reload_prepare service=%s listener=%s:%s action=reuse_socket",
                        svc->cfg.name, svc->cfg.listen_host, svc->cfg.listen_port);
                continue;
            }
        }

        fd = create_listener(svc->cfg.listen_host,
                             svc->cfg.listen_port,
                             svc->cfg.backlog);
        if (fd < 0) {
            log_msg(LOG_ERR,
                    "reload_prepare service=%s cannot_listen address=%s:%s error=%s",
                    svc->cfg.name, svc->cfg.listen_host, svc->cfg.listen_port,
                    strerror(errno));
            close_generation_listeners(app);
            return -1;
        }
        svc->listen_fd = fd;
    }
    return 0;
}

static void apply_generation_backlogs(struct app_config *app)
{
    size_t i;
    for (i = 0; i < app->service_count; i++) {
        struct service *svc = &app->services[i];
        if (svc->listen_fd >= 0 && listen(svc->listen_fd, svc->cfg.backlog) < 0) {
            log_msg(LOG_WARNING,
                    "service=%s listener_backlog_update_failed address=%s:%s error=%s",
                    svc->cfg.name, svc->cfg.listen_host, svc->cfg.listen_port,
                    strerror(errno));
        }
    }
}

static struct pollfd *build_pollfds(const struct app_config *app)
{
    struct pollfd *pfds;
    size_t i;

    pfds = calloc(app->service_count, sizeof(*pfds));
    if (!pfds)
        return NULL;
    for (i = 0; i < app->service_count; i++) {
        pfds[i].fd = app->services[i].listen_fd;
        pfds[i].events = POLLIN;
    }
    return pfds;
}

static int start_generation_health(struct app_config *app)
{
    size_t i;
    atomic_store(&app->health_running, true);

    for (i = 0; i < app->service_count; i++) {
        struct service *svc = &app->services[i];
        int rc = pthread_create(&svc->health_tid, NULL, health_thread, svc);
        if (rc != 0) {
            size_t j;
            log_msg(LOG_ERR, "service=%s health_thread_create_failed=%s",
                    svc->cfg.name, strerror(rc));
            atomic_store(&app->health_running, false);
            for (j = 0; j < i; j++) {
                if (app->services[j].health_started) {
                    pthread_join(app->services[j].health_tid, NULL);
                    app->services[j].health_started = false;
                }
            }
            return -1;
        }
        svc->health_started = true;
    }
    return 0;
}

static void stop_generation_health(struct app_config *app)
{
    size_t i;
    if (!app) return;
    atomic_store(&app->health_running, false);
    for (i = 0; i < app->service_count; i++) {
        struct service *svc = &app->services[i];
        if (svc->health_started) {
            pthread_join(svc->health_tid, NULL);
            svc->health_started = false;
        }
    }
}

static int generation_clients(const struct app_config *app)
{
    size_t i;
    int total = 0;
    if (!app) return 0;
    for (i = 0; i < app->service_count; i++)
        total += atomic_load(&app->services[i].clients);
    return total;
}

static void destroy_generation(struct app_config *app)
{
    size_t i;
    if (!app) return;
    for (i = 0; i < app->service_count; i++)
        pthread_mutex_destroy(&app->services[i].state.lock);
    free(app);
}

static void retire_generation(struct app_config *app)
{
    if (!app) return;
    close_generation_listeners(app);
    stop_generation_health(app);
    app->next_retired = g_retired_apps;
    g_retired_apps = app;
}

static void reap_retired_generations(void)
{
    struct app_config **pp = &g_retired_apps;
    while (*pp) {
        struct app_config *app = *pp;
        if (generation_clients(app) == 0) {
            *pp = app->next_retired;
            log_msg(LOG_INFO, "reload_retired_generation_reaped services=%zu",
                    app->service_count);
            destroy_generation(app);
        } else {
            pp = &app->next_retired;
        }
    }
}

static void log_generation_services(const struct app_config *app, const char *event)
{
    size_t i;
    for (i = 0; i < app->service_count; i++) {
        const struct service *svc = &app->services[i];
        log_msg(LOG_NOTICE,
                "%s service=%s listen=%s:%s active=%s:%s standby=%s:%s check_interval_ms=%d fall=%d rise=%d max_clients=%d keepalive=%d/%d/%d proxy_protocol_v1=%s health_check=%s health_path=%s health_expect_status=%d",
                event,
                svc->cfg.name,
                svc->cfg.listen_host, svc->cfg.listen_port,
                svc->cfg.active_host, svc->cfg.active_port,
                svc->cfg.standby_host, svc->cfg.standby_port,
                svc->cfg.check_interval_ms, svc->cfg.fall, svc->cfg.rise,
                svc->cfg.max_clients, svc->cfg.tcp_keepalive_idle_sec,
                svc->cfg.tcp_keepalive_interval_sec, svc->cfg.tcp_keepalive_count,
                svc->cfg.proxy_protocol_v1 ? "yes" : "no",
                health_check_name(svc->cfg.health_check), svc->cfg.health_path,
                svc->cfg.health_expect_status);
    }
}

static bool all_health_initialized(struct app_config *app)
{
    size_t i;
    if (!app) return true;
    for (i = 0; i < app->service_count; i++) {
        bool a, b;
        pthread_mutex_lock(&app->services[i].state.lock);
        a = app->services[i].state.active.initialized;
        b = app->services[i].state.standby.initialized;
        pthread_mutex_unlock(&app->services[i].state.lock);
        if (!a || !b)
            return false;
    }
    return true;
}

static void wait_initial_health(struct app_config *app)
{
    int timeout_ms;
    int64_t deadline;
    if (!app) return;
    timeout_ms = app->defaults.startup_health_wait_ms;
    if (timeout_ms <= 0 || all_health_initialized(app))
        return;
    deadline = monotonic_ms() + timeout_ms;
    while (g_running && monotonic_ms() < deadline) {
        struct timespec ts = { .tv_sec = 0, .tv_nsec = 50 * 1000 * 1000L };
        if (all_health_initialized(app))
            return;
        nanosleep(&ts, NULL);
    }
    if (!all_health_initialized(app))
        log_msg(LOG_WARNING,
                "startup_health_wait_timeout timeout_ms=%d action=continue runtime_fallback_enabled=yes",
                timeout_ms);
}

static void log_status_snapshot(const struct app_config *app, const char *reason)
{
    size_t i;
    int64_t now = monotonic_ms();
    log_msg(LOG_NOTICE,
            "status reason=%s services=%zu clients=%d accepted=%llu rejected=%llu failovers=%llu completed=%llu workers=%d",
            reason ? reason : "manual",
            app ? app->service_count : 0,
            atomic_load(&g_clients_total),
            (unsigned long long)atomic_load(&g_accepted_total),
            (unsigned long long)atomic_load(&g_rejected_total),
            (unsigned long long)atomic_load(&g_failover_total),
            (unsigned long long)atomic_load(&g_completed_total),
            g_worker_count);
    if (app) {
        for (i = 0; i < app->service_count; i++) {
            const struct service *svc = &app->services[i];
            bool au, su;
            enum backend_state selected;
            pthread_mutex_lock((pthread_mutex_t *)&svc->state.lock);
            au = svc->state.active.up;
            su = svc->state.standby.up;
            selected = svc->state.selected;
            pthread_mutex_unlock((pthread_mutex_t *)&svc->state.lock);
            log_msg(LOG_NOTICE,
                    "status_service name=%s listen=%s:%s active=%s standby=%s selected=%s clients=%d accepted=%llu rejected=%llu failovers=%llu completed=%llu http_compat=%s http_compat_auto_urlencode=%s http_compat_rewrites=%llu http_compat_urlencodes=%llu proxy_protocol_v1=%s health_check=%s health_path=%s health_expect_status=%d active_health_http_status=%d standby_health_http_status=%d",
                    svc->cfg.name, svc->cfg.listen_host, svc->cfg.listen_port,
                    au ? "UP" : "DOWN", su ? "UP" : "DOWN", state_name(selected),
                    atomic_load(&svc->clients),
                    (unsigned long long)atomic_load(&svc->accepted_total),
                    (unsigned long long)atomic_load(&svc->rejected_total),
                    (unsigned long long)atomic_load(&svc->failover_total),
                    (unsigned long long)atomic_load(&svc->completed_total),
                    svc->cfg.http_compat_text_query ? "on" : "off",
                    svc->cfg.http_compat_auto_urlencode ? "on" : "off",
                    (unsigned long long)atomic_load(&svc->http_compat_rewrite_total),
                    (unsigned long long)atomic_load(&svc->http_compat_urlencode_total),
                    svc->cfg.proxy_protocol_v1 ? "yes" : "no",
                    health_check_name(svc->cfg.health_check), svc->cfg.health_path,
                    svc->cfg.health_expect_status,
                    atomic_load(&svc->active_health_http_status),
                    atomic_load(&svc->standby_health_http_status));
        }
    }
    for (i = 0; i < (size_t)g_worker_count; i++) {
        int64_t hb = atomic_load(&g_workers[i].last_heartbeat_ms);
        log_msg(LOG_DEBUG, "status_worker id=%zu heartbeat_age_ms=%lld",
                i, (long long)(hb > 0 ? now - hb : -1));
    }
}

static int reload_generation(const char *config_path, struct pollfd **pfds_ptr)
{
    struct app_config *newapp;
    struct app_config *oldapp = g_active_app;
    struct pollfd *newpfds;
    struct pollfd *oldpfds = *pfds_ptr;

    log_msg(LOG_NOTICE, "reload_requested config=%s", config_path);

    newapp = load_config(config_path);
    if (!newapp) {
        log_msg(LOG_ERR,
                "reload_failed stage=parse_validate config=%s current_configuration_preserved=yes",
                config_path);
        return -1;
    }

    if (oldapp && newapp->defaults.worker_threads != oldapp->defaults.worker_threads) {
        log_msg(LOG_ERR,
                "reload_failed stage=immutable_setting setting=worker_threads old=%d new=%d restart_required=yes current_configuration_preserved=yes",
                oldapp->defaults.worker_threads, newapp->defaults.worker_threads);
        destroy_generation(newapp);
        return -1;
    }

    inherit_health_state(newapp, oldapp);

    if (prepare_generation_listeners(newapp, oldapp) < 0) {
        log_msg(LOG_ERR,
                "reload_failed stage=listener_prepare config=%s current_configuration_preserved=yes",
                config_path);
        destroy_generation(newapp);
        return -1;
    }

    newpfds = build_pollfds(newapp);
    if (!newpfds) {
        log_msg(LOG_ERR,
                "reload_failed stage=poll_alloc config=%s current_configuration_preserved=yes",
                config_path);
        close_generation_listeners(newapp);
        destroy_generation(newapp);
        return -1;
    }

    if (start_generation_health(newapp) < 0) {
        log_msg(LOG_ERR,
                "reload_failed stage=health_threads config=%s current_configuration_preserved=yes",
                config_path);
        close_generation_listeners(newapp);
        free(newpfds);
        destroy_generation(newapp);
        return -1;
    }

    wait_initial_health(newapp);

    /* Commit point. From here on, only the new generation receives new accepts.
     * Existing epoll sessions retain pointers to their immutable old service
     * objects and are allowed to finish naturally. */
    g_active_app = newapp;
    *pfds_ptr = newpfds;
    free(oldpfds);
    apply_generation_backlogs(newapp);

    log_generation_services(newapp, "reloaded");
    log_msg(LOG_NOTICE,
            "reload_success services_old=%zu services_new=%zu max_clients_total=%d worker_threads=%d active_connections_preserved=yes",
            oldapp ? oldapp->service_count : 0,
            newapp->service_count,
            newapp->defaults.max_clients_total,
            newapp->defaults.worker_threads);

    retire_generation(oldapp);
    reap_retired_generations();
    return 0;
}

int main(int argc, char **argv)
{
    const char *config_path = DEFAULT_CONFIG;
    int daemonize_flag = 0;
    int test_config_flag = 0;
    int opt;
    struct pollfd *pfds = NULL;

    while ((opt = getopt(argc, argv, "c:dhtV")) != -1) {
        switch (opt) {
        case 'c': config_path = optarg; break;
        case 'd': daemonize_flag = 1; break;
        case 't': test_config_flag = 1; break;
        case 'h': usage(argv[0]); return 0;
        case 'V': printf("%s %s\n", PROGRAM_NAME, PROGRAM_VERSION); return 0;
        default: usage(argv[0]); return 2;
        }
    }

    g_active_app = load_config(config_path);
    if (!g_active_app)
        return 1;

    if (test_config_flag) {
        size_t ti;
        printf("%s: configuration valid: %s services=%zu worker_threads=%d\n",
               PROGRAM_NAME, config_path, g_active_app->service_count,
               g_active_app->defaults.worker_threads);
        for (ti = 0; ti < g_active_app->service_count; ti++) {
            const struct service_cfg *c = &g_active_app->services[ti].cfg;
            printf("service=%s listen=%s:%s proxy_protocol_v1=%s health_check=%s health_path=%s health_expect_status=%d\n",
                   c->name, c->listen_host, c->listen_port,
                   c->proxy_protocol_v1 ? "yes" : "no",
                   health_check_name(c->health_check), c->health_path,
                   c->health_expect_status);
        }
        destroy_generation(g_active_app);
        g_active_app = NULL;
        return 0;
    }

    if (daemonize_flag) {
        if (daemon(0, 0) < 0) {
            perror("daemon");
            destroy_generation(g_active_app);
            return 1;
        }
        g_log_to_stderr = 0;
    }

    /* Under systemd Type=notify, syslog already reaches the journal. Avoid
     * LOG_PERROR there or every message is captured twice (syslog + stderr).
     * Keep stderr mirroring only for an interactive foreground invocation. */
    if (!daemonize_flag)
        g_log_to_stderr = (getenv("NOTIFY_SOCKET") == NULL && isatty(STDERR_FILENO));
    openlog(PROGRAM_NAME,
            LOG_PID | LOG_NDELAY | (g_log_to_stderr ? LOG_PERROR : 0),
            LOG_DAEMON);

    g_reserve_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (g_reserve_fd < 0)
        log_msg(LOG_WARNING, "reserve_fd_open_failed error=%s", strerror(errno));

    if (install_signals() < 0) {
        log_msg(LOG_ERR, "failed_to_install_signal_handlers error=%s", strerror(errno));
        destroy_generation(g_active_app);
        return 1;
    }

    if (prepare_generation_listeners(g_active_app, NULL) < 0) {
        destroy_generation(g_active_app);
        return 1;
    }

    pfds = build_pollfds(g_active_app);
    if (!pfds) {
        log_msg(LOG_ERR, "calloc pollfds failed");
        close_generation_listeners(g_active_app);
        destroy_generation(g_active_app);
        return 1;
    }

    if (start_generation_health(g_active_app) < 0) {
        close_generation_listeners(g_active_app);
        free(pfds);
        destroy_generation(g_active_app);
        return 1;
    }

    wait_initial_health(g_active_app);

    if (start_workers(g_active_app->defaults.worker_threads) < 0) {
        stop_generation_health(g_active_app);
        close_generation_listeners(g_active_app);
        free(pfds);
        destroy_generation(g_active_app);
        return 1;
    }

    log_generation_services(g_active_app, "started");
    log_msg(LOG_NOTICE,
            "started services=%zu max_clients_total=%d worker_threads=%d data_plane=epoll hot_reload=SIGHUP graceful_shutdown=%ds",
            g_active_app->service_count, g_active_app->defaults.max_clients_total,
            g_active_app->defaults.worker_threads, g_active_app->defaults.shutdown_grace_sec);

    watchdog_init_from_env();
    (void)sd_notify_send("READY=1\nSTATUS=tcp_failover_proxy ready");
    log_status_snapshot(g_active_app, "startup");

    while (g_running && !g_shutdown_requested) {
        struct app_config *app;
        int rc;
        size_t i;

        if (g_reload_requested) {
            g_reload_requested = 0;
            (void)reload_generation(config_path, &pfds);
        }
        if (g_stats_requested) {
            g_stats_requested = 0;
            log_status_snapshot(g_active_app, "SIGUSR1");
        }
        if (atomic_load(&g_worker_failed)) {
            log_msg(LOG_CRIT, "worker_failure_detected action=terminate_for_restart");
            g_exit_code = 1;
            break;
        }
        watchdog_tick();

        reap_retired_generations();
        app = g_active_app;
        if (!app)
            break;

        rc = poll(pfds, (nfds_t)app->service_count, 1000);
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            log_msg(LOG_ERR, "listener_poll_failed error=%s", strerror(errno));
            g_exit_code = 1;
            break;
        }
        if (rc == 0)
            continue;

        for (i = 0; i < app->service_count; i++) {
            if (pfds[i].revents & POLLIN)
                accept_ready(&app->services[i], app);
            if (pfds[i].revents & (POLLERR | POLLNVAL)) {
                log_msg(LOG_ERR, "service=%s listener_error revents=0x%x",
                        app->services[i].cfg.name, pfds[i].revents);
                if (pfds[i].revents & POLLNVAL) {
                    g_exit_code = 1;
                    g_running = 0;
                    break;
                }
            }
        }
    }

    if (g_shutdown_requested && g_running) {
        int grace_sec = g_active_app ? g_active_app->defaults.shutdown_grace_sec : 0;
        int64_t deadline = monotonic_ms() + (int64_t)grace_sec * 1000;
        int initial_clients = atomic_load(&g_clients_total);
        log_msg(LOG_NOTICE,
                "shutdown_begin mode=graceful grace_sec=%d active_clients=%d listeners_closed=yes",
                grace_sec, initial_clients);
        (void)sd_notify_send("STOPPING=1\nSTATUS=draining active TCP sessions");
        if (g_active_app) {
            close_generation_listeners(g_active_app);
            stop_generation_health(g_active_app);
        }
        {
            struct app_config *r;
            for (r = g_retired_apps; r; r = r->next_retired) {
                close_generation_listeners(r);
                stop_generation_health(r);
            }
        }
        while (g_running && !g_force_shutdown && atomic_load(&g_clients_total) > 0 &&
               monotonic_ms() < deadline) {
            struct timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000L };
            if (g_stats_requested) {
                g_stats_requested = 0;
                log_status_snapshot(g_active_app, "shutdown_drain");
            }
            watchdog_tick();
            nanosleep(&ts, NULL);
        }
        if (atomic_load(&g_clients_total) > 0) {
            log_msg(g_force_shutdown ? LOG_WARNING : LOG_ERR,
                    "shutdown_drain_incomplete force=%s remaining_clients=%d",
                    g_force_shutdown ? "yes" : "no", atomic_load(&g_clients_total));
        } else {
            log_msg(LOG_NOTICE, "shutdown_drain_complete active_clients=0");
        }
    }

    g_running = 0;
    if (g_active_app) {
        close_generation_listeners(g_active_app);
        stop_generation_health(g_active_app);
    }
    {
        struct app_config *r;
        for (r = g_retired_apps; r; r = r->next_retired) {
            stop_generation_health(r);
            close_generation_listeners(r);
        }
    }

    stop_workers();

    log_msg(LOG_NOTICE,
            "stopped active_clients_total=%d accepted=%llu rejected=%llu failovers=%llu completed=%llu exit_code=%d",
            atomic_load(&g_clients_total),
            (unsigned long long)atomic_load(&g_accepted_total),
            (unsigned long long)atomic_load(&g_rejected_total),
            (unsigned long long)atomic_load(&g_failover_total),
            (unsigned long long)atomic_load(&g_completed_total), g_exit_code);

    if (atomic_load(&g_clients_total) == 0) {
        struct app_config *r = g_retired_apps;
        while (r) {
            struct app_config *next = r->next_retired;
            destroy_generation(r);
            r = next;
        }
        g_retired_apps = NULL;
        destroy_generation(g_active_app);
        g_active_app = NULL;
    }

    if (g_reserve_fd >= 0) {
        close(g_reserve_fd);
        g_reserve_fd = -1;
    }
    free(pfds);
    closelog();
    return g_exit_code;
}
