#!/bin/bash
#
# logGP_v4.1.sh
#
# LogAnalyzer / Syslog.SystemEvents review backend
# MariaDB 10.3 compatible port/label classification.
#
# Design:
#   1. Read port + label only from /etc/tg_https_proxy.conf.
#   2. Query human-reviewable final messages from SystemEvents.
#   3. Query nearby tg_https_proxy technical event rows containing listen_port=.
#   4. Correlate in Perl using:
#        - same SysLogTag / proxy PID
#        - technical row ID < final row ID
#        - ID distance <= CORRELATION_ID_WINDOW
#        - time distance <= CORRELATION_SECONDS
#        - prefer event=AUDIT_TEXT
#   5. Return only the requested port/classification.
#
# No BOT_TOKEN or CHAT_ID is ever returned to the browser.
#
# Commands:
#   logGP PORTS
#       -> PORT|<port>|<label>
#          ...
#          EOF
#
#   logGP A [ALL|UNCLASSIFIED|<port>]
#   logGP N [ALL|UNCLASSIFIED|<port>]
#   logGP Y [ALL|UNCLASSIFIED|<port>]
#
#   logGP <ID> <USERID>
#       -> ACK|ID|OprReportedTime|Y|OprNameID
#
# Query output:
#   ID|ReceivedAt|ListenPort|Message|OprReportedTime|OprReported|OprNameID
#
# Debug:
#   LOGGP_DEBUG=1 ./logGP A 9911
#
set -uo pipefail
umask 077
export LC_ALL=C.UTF-8
PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly SCRIPT_NAME="${0##*/}"
readonly MYSQL_BIN="/usr/bin/mysql"
readonly PERL_BIN="/usr/bin/perl"
readonly LOGGER_BIN="/usr/bin/logger"
readonly MYSQL_CNF="/etc/loganalyzer/logGP.cnf"
readonly TG_PROXY_CONF="${TG_PROXY_CONF:-/etc/tg_https_proxy.conf}"
readonly DB_NAME="Syslog"
readonly TABLE_NAME="SystemEvents"
readonly LIMIT_ROWS="${LIMIT_ROWS:-100}"
readonly CANDIDATE_ROWS="${CANDIDATE_ROWS:-2000}"
readonly CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
readonly CORRELATION_ID_WINDOW="${CORRELATION_ID_WINDOW:-100}"
readonly CORRELATION_SECONDS="${CORRELATION_SECONDS:-10}"
readonly LOGGP_DEBUG="${LOGGP_DEBUG:-0}"
readonly PROXY_TAG_LIKE='tg_https_proxy[%]:%'

TMPDIR_WORK=""

cleanup() {
    if [[ -n "${TMPDIR_WORK:-}" && -d "$TMPDIR_WORK" ]]; then
        /bin/rm -rf -- "$TMPDIR_WORK"
    fi
}
trap cleanup EXIT INT TERM HUP

log_error() {
    "$LOGGER_BIN" -p daemon.err -t "$SCRIPT_NAME" -- "$*" 2>/dev/null || true
}

protocol_error() {
    local msg="${1:-unknown error}"
    msg="${msg//$'\r'/ }"
    msg="${msg//$'\n'/ }"
    msg="${msg//|/｜}"
    printf 'ERR|%s\n' "$msg"
}

die() {
    local msg="${1:-unknown error}"
    log_error "$msg"
    protocol_error "$msg"
    exit 1
}

debug() {
    [[ "$LOGGP_DEBUG" == "1" ]] || return 0
    printf '[DEBUG] %s\n' "$*" >&2
}

check_runtime() {
    [[ -x "$MYSQL_BIN" ]] || die "mysql client not found"
    [[ -x "$PERL_BIN" ]] || die "perl not found"
    [[ -r "$MYSQL_CNF" ]] || die "database credential file not readable: $MYSQL_CNF"
    [[ -r "$TG_PROXY_CONF" ]] || die "tg_https_proxy config not readable: $TG_PROXY_CONF"
    [[ "$LIMIT_ROWS" =~ ^[0-9]+$ ]] || die "invalid LIMIT_ROWS"
    [[ "$CANDIDATE_ROWS" =~ ^[0-9]+$ ]] || die "invalid CANDIDATE_ROWS"
    [[ "$CORRELATION_ID_WINDOW" =~ ^[0-9]+$ ]] || die "invalid CORRELATION_ID_WINDOW"
    [[ "$CORRELATION_SECONDS" =~ ^[0-9]+$ ]] || die "invalid CORRELATION_SECONDS"
    TMPDIR_WORK="$(/usr/bin/mktemp -d /tmp/logGP.XXXXXX)" || die "temporary directory creation failed"
}

mysql_exec() {
    "$MYSQL_BIN" \
        --defaults-extra-file="$MYSQL_CNF" \
        --connect-timeout="$CONNECT_TIMEOUT" \
        --default-character-set=utf8mb4 \
        --batch --skip-column-names --raw \
        "$DB_NAME" "$@"
}

mysql_query_file() {
    local sql="$1" outfile="$2" errfile="$3"
    : >"$outfile"
    : >"$errfile"
    if mysql_exec -e "$sql" >"$outfile" 2>"$errfile"; then
        return 0
    fi
    local db_error
    db_error="$(tail -1 "$errfile" 2>/dev/null || true)"
    log_error "MariaDB query failed: ${db_error:-unknown mysql error}"
    if [[ "$LOGGP_DEBUG" == "1" ]]; then
        protocol_error "database query failed: ${db_error:-unknown mysql error}"
    else
        protocol_error "database query failed"
    fi
    return 1
}

list_ports() {
    local port token chat_id label extra
    while IFS='|' read -r port token chat_id label extra; do
        [[ -z "${port//[[:space:]]/}" ]] && continue
        [[ "$port" =~ ^[[:space:]]*# ]] && continue
        port="${port//[[:space:]]/}"
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
        (( 10#$port >= 1 && 10#$port <= 65535 )) || continue
        label="${label//$'\r'/}"
        label="${label//$'\n'/ }"
        label="${label//|/｜}"
        [[ -n "$label" ]] || label="port_${port}"
        printf 'PORT|%s|%s\n' "$port" "$label"
    done < "$TG_PROXY_CONF"
    printf 'EOF\n'
}

port_exists() {
    local wanted="$1" port token chat_id label extra
    while IFS='|' read -r port token chat_id label extra; do
        [[ -z "${port//[[:space:]]/}" ]] && continue
        [[ "$port" =~ ^[[:space:]]*# ]] && continue
        port="${port//[[:space:]]/}"
        [[ "$port" == "$wanted" ]] && return 0
    done < "$TG_PROXY_CONF"
    return 1
}

query_candidates() {
    local filter="$1" outfile="$2" errfile="$3" reported_clause=""
    case "$filter" in
        A|"") reported_clause="" ;;
        N) reported_clause="AND COALESCE(NULLIF(OprReported,''),'N') = 'N'" ;;
        Y) reported_clause="AND OprReported = 'Y'" ;;
        *) protocol_error "invalid query filter"; return 1 ;;
    esac

    local sql="
SELECT
    ID,
    UNIX_TIMESTAMP(ReceivedAt),
    DATE_FORMAT(ReceivedAt, '%Y-%m-%d %H:%i:%s'),
    HEX(COALESCE(SysLogTag,'')),
    HEX(Message),
    COALESCE(DATE_FORMAT(OprReportedTime, '%Y-%m-%d %H:%i:%s'), ''),
    COALESCE(NULLIF(OprReported,''),'N'),
    HEX(COALESCE(OprNameID,''))
FROM ${TABLE_NAME}
WHERE
    Message IS NOT NULL
    AND CHAR_LENGTH(TRIM(Message)) > 0
    AND SysLogTag LIKE '${PROXY_TAG_LIKE}'
    AND LTRIM(Message) NOT LIKE 'event=%'
    ${reported_clause}
ORDER BY ID DESC
LIMIT ${CANDIDATE_ROWS};"

    debug "candidate SQL filter=$filter"
    mysql_query_file "$sql" "$outfile" "$errfile"
}

query_technical_events() {
    local min_id="$1" max_id="$2" outfile="$3" errfile="$4"
    local start_id=0
    if (( min_id > CORRELATION_ID_WINDOW )); then
        start_id=$((min_id - CORRELATION_ID_WINDOW))
    fi

    local sql="
SELECT
    ID,
    UNIX_TIMESTAMP(ReceivedAt),
    HEX(COALESCE(SysLogTag,'')),
    HEX(Message)
FROM ${TABLE_NAME}
WHERE
    ID >= ${start_id}
    AND ID < ${max_id}
    AND SysLogTag LIKE '${PROXY_TAG_LIKE}'
    AND LTRIM(Message) LIKE 'event=%'
    AND Message LIKE '%listen_port=%'
ORDER BY ID DESC;"

    debug "technical SQL id_range=${start_id}..$((max_id - 1))"
    mysql_query_file "$sql" "$outfile" "$errfile"
}

correlate_and_output() {
    local candidate_file="$1" tech_file="$2" port_filter="$3"

    "$PERL_BIN" - "$candidate_file" "$tech_file" "$port_filter" \
        "$LIMIT_ROWS" "$CORRELATION_ID_WINDOW" "$CORRELATION_SECONDS" <<'PERL'
use strict;
use warnings;
use bytes;

my ($candidate_file, $tech_file, $wanted_port, $limit_rows,
    $id_window, $seconds_window) = @ARGV;

sub hex_decode {
    my ($v) = @_;
    return '' if !defined($v) || $v eq '';
    return pack('H*', $v) if $v =~ /\A[0-9A-Fa-f]*\z/;
    return '';
}

sub clean_field {
    my ($v) = @_;
    $v = '' if !defined $v;
    $v =~ s/\r\n/ /g;
    $v =~ s/[\r\n\t]+/ /g;
    $v =~ s/\\[nr]/ /g;
    $v =~ s/\|/｜/g;
    $v =~ s/[ ]{2,}/ /g;
    return $v;
}

my %events;
open my $tfh, '<', $tech_file or die "cannot read technical event file: $!";
while (my $line = <$tfh>) {
    chomp $line;
    my @f = split(/\t/, $line, -1);
    next unless @f >= 4;
    my ($id, $epoch, $tag_hex, $msg_hex) = @f[0..3];
    next unless defined($id) && $id =~ /^\d+$/;
    next unless defined($epoch) && $epoch =~ /^\d+$/;

    my $tag = hex_decode($tag_hex);
    my $msg = hex_decode($msg_hex);
    next if $tag eq '' || $msg eq '';

    my ($port) = $msg =~ /(?:^|\s)listen_port=(\d{1,5})(?=\s|$)/;
    next unless defined $port;
    next unless $port >= 1 && $port <= 65535;

    push @{ $events{$tag} }, {
        id         => 0 + $id,
        epoch      => 0 + $epoch,
        port       => "$port",
        audit_text => ($msg =~ /^event=AUDIT_TEXT(?:\s|$)/) ? 1 : 0,
    };
}
close $tfh;

for my $tag (keys %events) {
    @{ $events{$tag} } = sort { $b->{id} <=> $a->{id} } @{ $events{$tag} };
}

open my $cfh, '<', $candidate_file or die "cannot read candidate file: $!";
my $printed = 0;

CANDIDATE:
while (my $line = <$cfh>) {
    chomp $line;
    my @f = split(/\t/, $line, -1);
    next unless @f >= 8;

    my ($id, $epoch, $received, $tag_hex, $message_hex,
        $reported_time, $reported, $user_hex) = @f[0..7];

    next unless defined($id) && $id =~ /^\d+$/;
    next unless defined($epoch) && $epoch =~ /^\d+$/;

    my $tag     = hex_decode($tag_hex);
    my $message = hex_decode($message_hex);
    my $user    = hex_decode($user_hex);

    my ($best_audit, $best_any);
    if (exists $events{$tag}) {
        EVENT:
        for my $ev (@{ $events{$tag} }) {
            next EVENT if $ev->{id} >= $id;
            my $id_diff = $id - $ev->{id};
            last EVENT if $id_diff > $id_window;

            my $time_diff = $epoch - $ev->{epoch};
            next EVENT if $time_diff < 0;
            next EVENT if $time_diff > $seconds_window;

            $best_any ||= $ev;
            if ($ev->{audit_text}) {
                $best_audit = $ev;
                last EVENT;
            }
        }
    }

    my $best = $best_audit || $best_any;
    my $port = $best ? $best->{port} : '';

    if ($wanted_port eq 'UNCLASSIFIED') {
        next CANDIDATE if $port ne '';
    }
    elsif ($wanted_port ne 'ALL') {
        next CANDIDATE if $port ne $wanted_port;
    }

    $received      = clean_field($received);
    $message       = clean_field($message);
    $reported_time = clean_field($reported_time);
    $reported      = clean_field($reported);
    $user          = clean_field($user);
    $port          = clean_field($port);

    print join('|',
        clean_field($id),
        $received,
        $port,
        $message,
        $reported_time,
        ($reported eq '' ? 'N' : $reported),
        $user
    ), "\n";

    $printed++;
    last if $printed >= $limit_rows;
}
close $cfh;
PERL

    local rc=$?
    if (( rc != 0 )); then
        log_error "Perl correlation failed rc=$rc"
        protocol_error "classification processing failed"
        return 1
    fi
    printf 'EOF\n'
}

query_rows() {
    local filter="${1:-A}" port_filter="${2:-ALL}"

    case "$port_filter" in
        ""|ALL) port_filter="ALL" ;;
        UNCLASSIFIED) ;;
        *)
            if [[ ! "$port_filter" =~ ^[0-9]{1,5}$ ]]; then
                protocol_error "invalid listen port"; return 1
            fi
            if (( 10#$port_filter < 1 || 10#$port_filter > 65535 )); then
                protocol_error "invalid listen port"; return 1
            fi
            if ! port_exists "$port_filter"; then
                protocol_error "undefined listen port"; return 1
            fi
            ;;
    esac

    local candidates="$TMPDIR_WORK/candidates.tsv"
    local candidate_err="$TMPDIR_WORK/candidates.err"
    local technical="$TMPDIR_WORK/technical.tsv"
    local technical_err="$TMPDIR_WORK/technical.err"

    query_candidates "$filter" "$candidates" "$candidate_err" || return 1

    if [[ ! -s "$candidates" ]]; then
        printf 'EOF\n'
        return 0
    fi

    local min_id="" max_id=""
    read -r min_id max_id < <(
        /usr/bin/awk -F '\t' '
            NR == 1 { min=$1; max=$1 }
            { if ($1 < min) min=$1; if ($1 > max) max=$1 }
            END { print min, max }
        ' "$candidates"
    )

    [[ "$min_id" =~ ^[0-9]+$ && "$max_id" =~ ^[0-9]+$ ]] || {
        protocol_error "invalid candidate ID range"; return 1;
    }

    query_technical_events "$min_id" "$max_id" "$technical" "$technical_err" || return 1

    debug "candidate_rows=$(/usr/bin/wc -l < "$candidates")"
    debug "technical_rows=$(/usr/bin/wc -l < "$technical")"
    debug "filter=$filter port=$port_filter"

    correlate_and_output "$candidates" "$technical" "$port_filter"
}

confirm_row() {
    local id="${1:-}" userid="${2:-}"

    [[ "$id" =~ ^[0-9]+$ ]] || { protocol_error "invalid record id"; return 1; }
    [[ "$userid" =~ ^[A-Za-z0-9._@-]{2,60}$ ]] || { protocol_error "invalid user id"; return 1; }

    local update_sql="
UPDATE ${TABLE_NAME}
SET
    OprReportedTime = NOW(),
    OprReported     = 'Y',
    OprNameID       = '${userid}'
WHERE
    ID = ${id}
    AND Message IS NOT NULL
    AND CHAR_LENGTH(TRIM(Message)) > 0
    AND SysLogTag LIKE '${PROXY_TAG_LIKE}'
    AND LTRIM(Message) NOT LIKE 'event=%'
    AND COALESCE(NULLIF(OprReported,''),'N') <> 'Y';"

    local update_out="$TMPDIR_WORK/update.out" update_err="$TMPDIR_WORK/update.err"
    mysql_query_file "$update_sql" "$update_out" "$update_err" || return 1

    local select_sql="
SELECT
    ID,
    COALESCE(DATE_FORMAT(OprReportedTime, '%Y-%m-%d %H:%i:%s'),''),
    COALESCE(NULLIF(OprReported,''),'N'),
    HEX(COALESCE(OprNameID,''))
FROM ${TABLE_NAME}
WHERE
    ID = ${id}
    AND Message IS NOT NULL
    AND CHAR_LENGTH(TRIM(Message)) > 0
    AND SysLogTag LIKE '${PROXY_TAG_LIKE}'
    AND LTRIM(Message) NOT LIKE 'event=%'
LIMIT 1;"

    local select_out="$TMPDIR_WORK/select.out" select_err="$TMPDIR_WORK/select.err"
    mysql_query_file "$select_sql" "$select_out" "$select_err" || return 1

    [[ -s "$select_out" ]] || { protocol_error "record not found or not reviewable"; return 1; }

    "$PERL_BIN" -ne '
        chomp;
        my @f = split(/\t/, $_, -1);
        next unless @f >= 4;
        my $user = "";
        $user = pack("H*", $f[3]) if defined($f[3]) && $f[3] =~ /\A[0-9A-Fa-f]*\z/;
        for ($f[0],$f[1],$f[2],$user) {
            $_ = "" if !defined $_;
            s/[\r\n\t]+/ /g;
            s/\|/｜/g;
        }
        print join("|","ACK",$f[0],$f[1],$f[2],$user),"\n";
    ' "$select_out"
}

main() {
    check_runtime
    local arg1="${1:-}" arg2="${2:-}"
    case "$arg1" in
        PORTS) list_ports ;;
        ""|A) query_rows "A" "${arg2:-ALL}" ;;
        N) query_rows "N" "${arg2:-ALL}" ;;
        Y) query_rows "Y" "${arg2:-ALL}" ;;
        *) confirm_row "$arg1" "$arg2" ;;
    esac
}

main "$@"
exit $?
