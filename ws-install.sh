#!/bin/bash
# ==============================================================
#   SSH over WebSocket (ports 80 / 443) - installer + user manager
#   Script by Coldplay
#   Supports: Debian / Ubuntu
# ==============================================================

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run as root:  sudo bash ws-install.sh${NC}"
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${RED}This installer supports Debian/Ubuntu only.${NC}"
    exit 1
fi

clear
echo -e "${CYAN}==============================================${NC}"
echo -e "${WHITE}      SSH over WebSocket  -  Installer${NC}"
echo -e "${RED}             Script by Coldplay${NC}"
echo -e "${CYAN}==============================================${NC}"
echo

# ---------- packages ----------
echo -e "${YELLOW}[1/10] Installing packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y openssh-server stunnel4 openssl curl python3 iproute2 iptables procps >/dev/null 2>&1 || {
    echo -e "${RED}Package installation failed.${NC}"
    exit 1
}
mkdir -p /etc/sshws

# ---------- ports ----------
echo -e "${YELLOW}[2/10] Choosing ports...${NC}"
# stop our own services first so a re-run doesn't see its own ports as busy
systemctl stop ws-proxy ws-tls 2>/dev/null

RESERVED=""
port_listening() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
port_busy() { [[ $1 == "$RESERVED" ]] || port_listening "$1"; }

ask_port() {   # ask_port <label> <default> <fallback>
    local label=$1 p=$2 fallback=$3 np
    while true; do
        if [[ ! $p =~ ^[0-9]+$ || $p -lt 1 || $p -gt 65535 ]]; then
            echo -e "${RED}'$p' is not a valid port.${NC}" >&2
        elif ! port_busy "$p"; then
            break
        else
            echo -e "${YELLOW}Port $p is already used by another service (nginx? the SSH-over-TLS script?).${NC}" >&2
        fi
        read -r -p "Enter another port for $label [$fallback]: " np </dev/tty
        p=${np:-$fallback}
    done
    echo "$p"
}

WS_PORT=$(ask_port "WebSocket (HTTP)" "${WS_PORT:-80}" 8880)
RESERVED=$WS_PORT
WSS_PORT=$(ask_port "WebSocket (TLS)" "${WSS_PORT:-443}" 8443)
echo "$WS_PORT" > /etc/sshws/ws_port
echo "$WSS_PORT" > /etc/sshws/wss_port
echo -e "  WebSocket : ${WHITE}${WS_PORT}${NC}    WebSocket TLS : ${WHITE}${WSS_PORT}${NC}"

# ---------- domain ----------
OLD_DOMAIN=$(cat /etc/sshws/domain 2>/dev/null)
DOMAIN=${WS_DOMAIN:-}
if [[ -z $DOMAIN ]]; then
    echo
    read -r -p "Enter your domain (e.g. vpn.example.com) [${OLD_DOMAIN:-none}]: " DOMAIN </dev/tty
    DOMAIN=${DOMAIN:-$OLD_DOMAIN}
fi
DOMAIN=$(echo "$DOMAIN" | tr 'A-Z' 'a-z' | tr -d ' ')
[[ $DOMAIN == "none" ]] && DOMAIN=""
if [[ -n $DOMAIN && ! $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
    echo -e "${RED}'$DOMAIN' is not a valid domain. Continuing without a domain.${NC}"
    DOMAIN=""
fi
if [[ -n $DOMAIN ]]; then
    echo "$DOMAIN" > /etc/sshws/domain
    SERVER_IP=$(curl -s -m 5 ifconfig.me 2>/dev/null)
    DOMAIN_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -z $DOMAIN_IP ]]; then
        echo -e "${YELLOW}Warning: ${DOMAIN} has no DNS record yet. Point it to this server's IP.${NC}"
    elif [[ -n $SERVER_IP && $DOMAIN_IP != "$SERVER_IP" ]]; then
        echo -e "${YELLOW}Warning: ${DOMAIN} points to ${DOMAIN_IP}, but this server is ${SERVER_IP}.${NC}"
    fi
else
    rm -f /etc/sshws/domain
fi

# ---------- certificate (used by the TLS port) ----------
echo -e "${YELLOW}[3/10] Preparing TLS certificate...${NC}"
PEM=/etc/sshws/ssh-ws.pem
CERT_TYPE="self-signed"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [[ -n $DOMAIN ]]; then
    # no Let's Encrypt certificate yet: try to get one (needs port 80 free)
    if [[ ! -f $LE_DIR/fullchain.pem ]]; then
        if port_listening 80; then
            echo -e "${YELLOW}Port 80 is busy, so a Let's Encrypt certificate can't be requested automatically.${NC}"
            echo -e "${YELLOW}Using a self-signed certificate. If you already have a certificate for ${DOMAIN}, re-run this installer and it will use it.${NC}"
        else
            echo -e "Requesting a Let's Encrypt certificate for ${WHITE}${DOMAIN}${NC}..."
            apt-get install -y certbot >/dev/null 2>&1
            # the hooks free port 80 during renewals, because the proxy may use it
            certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
                --register-unsafely-without-email \
                --pre-hook "systemctl stop ws-proxy || true" \
                --post-hook "systemctl start ws-proxy || true" >/tmp/certbot.log 2>&1 \
                || echo -e "${YELLOW}Let's Encrypt failed (see /tmp/certbot.log). Using a self-signed certificate.${NC}"
        fi
    fi

    # use the Let's Encrypt certificate if it exists now
    if [[ -f $LE_DIR/fullchain.pem ]]; then
        cat "$LE_DIR/privkey.pem" "$LE_DIR/fullchain.pem" > "$PEM"
        chmod 600 "$PEM"
        # rebuild the certificate automatically on every renewal
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/sshws.sh << HOOK
#!/bin/bash
[[ "\$RENEWED_LINEAGE" == */live/${DOMAIN} ]] || exit 0
cat "\$RENEWED_LINEAGE/privkey.pem" "\$RENEWED_LINEAGE/fullchain.pem" > ${PEM}
chmod 600 ${PEM}
systemctl restart ws-tls
systemctl restart ws-panel 2>/dev/null || true
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/sshws.sh
        CERT_TYPE="Let's Encrypt"
    fi
fi

# fallback: self-signed certificate (named after the domain when one was given)
if [[ $CERT_TYPE == "self-signed" ]]; then
    if [[ -n $DOMAIN || ! -f $PEM ]]; then
        CN=${DOMAIN:-$(hostname)}
        ADDEXT=()
        [[ -n $DOMAIN ]] && ADDEXT=(-addext "subjectAltName=DNS:${DOMAIN}")
        openssl req -new -x509 -days 3650 -nodes \
            -subj "/CN=${CN}" "${ADDEXT[@]}" \
            -keyout /tmp/sshws.key -out /tmp/sshws.crt >/dev/null 2>&1
        cat /tmp/sshws.key /tmp/sshws.crt > "$PEM"
        rm -f /tmp/sshws.key /tmp/sshws.crt
        chmod 600 "$PEM"
    fi
fi

# ---------- sshd ----------
echo -e "${YELLOW}[4/10] Configuring SSH...${NC}"
# make sure password login is on (also in drop-in files)
sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null
grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || sed -i '1i PasswordAuthentication yes' /etc/ssh/sshd_config
# per-user connection limits need pam_limits
grep -q 'pam_limits.so' /etc/pam.d/sshd || echo 'session required pam_limits.so' >> /etc/pam.d/sshd
grep -q '^UsePAM' /etc/ssh/sshd_config || sed -i '1i UsePAM yes' /etc/ssh/sshd_config

touch /etc/sshws/users.db /etc/security/limits.d/sshws.conf

# ---------- speed tuning ----------
echo -e "${YELLOW}[5/10] Applying speed tuning (BBR, TCP buffers, SSH)...${NC}"
modprobe tcp_bbr 2>/dev/null
echo tcp_bbr > /etc/modules-load.d/bbr.conf
cat > /etc/sysctl.d/99-sshws.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle = 0
EOF
sysctl --system >/dev/null 2>&1
# SSH: no compression, no DNS lookups
sed -i '/^\s*Compression\s/d; /^\s*UseDNS\s/d' /etc/ssh/sshd_config
sed -i '1i Compression no\nUseDNS no' /etc/ssh/sshd_config
# drop dead connections within ~45 s so they stop counting against a user's limit
sed -i '/^\s*ClientAliveInterval\s/d; /^\s*ClientAliveCountMax\s/d' /etc/ssh/sshd_config
sed -i '1i ClientAliveInterval 15\nClientAliveCountMax 3' /etc/ssh/sshd_config
BBR_STATE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

# reload sshd with the new settings and find its port
if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
fi
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
SSH_PORT=${SSH_PORT:-22}

# ---------- udpgw ----------
UDPGW_PORT=${UDPGW_PORT:-7300}
echo -e "${YELLOW}[6/10] Installing udpgw on port ${UDPGW_PORT}...${NC}"
UDPGW_BIN=$(command -v badvpn-udpgw)

build_udpgw() {
    local d
    d=$(mktemp -d) || return 1
    apt-get install -y build-essential cmake wget >/dev/null 2>&1
    (
        cd "$d" || exit 1
        wget -q -O badvpn.tar.gz "https://github.com/ambrop72/badvpn/archive/1.999.130.tar.gz" || exit 1
        tar xzf badvpn.tar.gz || exit 1
        cd badvpn-1.999.130 || exit 1
        mkdir build && cd build || exit 1
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
            -DCMAKE_POLICY_VERSION_MINIMUM=3.5 >/dev/null 2>&1 || exit 1
        make -j"$(nproc)" >/dev/null 2>&1 || exit 1
        install -m 755 udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
    )
    local rc=$?
    rm -rf "$d"
    return $rc
}

if [[ -z $UDPGW_BIN ]]; then
    apt-get install -y badvpn >/dev/null 2>&1
    UDPGW_BIN=$(command -v badvpn-udpgw)
fi
if [[ -z $UDPGW_BIN ]]; then
    echo -e "Building udpgw from source..."
    build_udpgw && UDPGW_BIN=/usr/local/bin/badvpn-udpgw
fi

if [[ -n $UDPGW_BIN && -x $UDPGW_BIN ]]; then
    # listens on localhost only: clients reach it through their SSH tunnel
    cat > /etc/systemd/system/udpgw.service << EOF
[Unit]
Description=BadVPN UDP gateway (udpgw)
After=network.target

[Service]
Type=simple
User=nobody
NoNewPrivileges=true
ExecStart=${UDPGW_BIN} --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients 1000 --max-connections-for-client 20 --loglevel warning
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable udpgw >/dev/null 2>&1
    systemctl restart udpgw
    echo "$UDPGW_PORT" > /etc/sshws/udpgw_port
else
    echo -e "${RED}Could not install udpgw. Everything else is installed.${NC}"
    rm -f /etc/sshws/udpgw_port
fi

# ---------- websocket proxy ----------
echo -e "${YELLOW}[7/10] Installing WebSocket proxy on ports ${WS_PORT} and ${WSS_PORT}...${NC}"
cat > /usr/local/bin/ws-proxy.py << 'PY_EOF'
#!/usr/bin/env python3
# SSH WebSocket proxy - Script by Coldplay
#
# Accepts a WebSocket-style HTTP upgrade request, answers "101 Switching
# Protocols", then relays the raw stream to the local SSH server.
#
# Anything the client sends between the HTTP request(s) and its SSH
# identification line (extra requests, padding, big payloads) is discarded,
# so sshd never sees it. A plain SSH client (no HTTP request) also works.

import asyncio
import os
import re

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("WS_PORT", "80"))
SSH_HOST = "127.0.0.1"
SSH_PORT = int(os.environ.get("SSH_PORT", "22"))

RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n\r\n"
)
HDR_END = re.compile(rb"\r?\n\r?\n")
BUFSIZE = 65536
HEADER_TIMEOUT = 10
MAX_HEADER = 262144      # 256 KB for the first request
MAX_JUNK = 4194304       # 4 MB discarded before the SSH banner
TAIL = 5                 # len(b"\nSSH-")


def close(writer):
    try:
        writer.close()
    except Exception:
        pass


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(BUFSIZE)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        close(writer)


def find_ssh(buf, line_start):
    """Index where the client's SSH identification line starts, or -1."""
    if line_start and buf.startswith(b"SSH-"):
        return 0
    i = buf.find(b"\nSSH-")
    return i + 1 if i >= 0 else -1


async def client_to_ssh(reader, writer, pending):
    """Forward client data to sshd, dropping everything before 'SSH-'."""
    buf = pending
    line_start = True
    synced = False
    discarded = 0
    try:
        while True:
            if not synced and buf:
                idx = find_ssh(buf, line_start)
                if idx >= 0:
                    discarded += idx
                    buf = buf[idx:]
                    synced = True
                elif len(buf) > TAIL:
                    # keep only a short tail, in case "SSH-" is split
                    discarded += len(buf) - TAIL
                    line_start = buf[-TAIL - 1:-TAIL] == b"\n"
                    buf = buf[-TAIL:]
                if discarded > MAX_JUNK:
                    return
            if synced and buf:
                writer.write(buf)
                await writer.drain()
                buf = b""
            data = await reader.read(BUFSIZE)
            if not data:
                break
            buf += data
    except Exception:
        pass
    finally:
        close(writer)


async def handle(client_reader, client_writer):
    remote_writer = None
    try:
        first = await asyncio.wait_for(client_reader.read(BUFSIZE), HEADER_TIMEOUT)
        if not first:
            return

        if first.startswith(b"SSH-"):
            # direct SSH client, no HTTP request in front
            pending = first
        else:
            buf = first
            while True:
                m = HDR_END.search(buf)
                if m:
                    break
                if len(buf) > MAX_HEADER:
                    return
                more = await asyncio.wait_for(client_reader.read(BUFSIZE), HEADER_TIMEOUT)
                if not more:
                    return
                buf += more
            pending = buf[m.end():]
            client_writer.write(RESPONSE)
            await client_writer.drain()

        remote_reader, remote_writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
        await asyncio.gather(
            client_to_ssh(client_reader, remote_writer, pending),
            pipe(remote_reader, client_writer),
        )
    except Exception:
        pass
    finally:
        close(client_writer)
        if remote_writer is not None:
            close(remote_writer)


def main():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    server = loop.run_until_complete(
        asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT, backlog=1024)
    )
    try:
        loop.run_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        loop.close()


if __name__ == "__main__":
    main()
PY_EOF
chmod 755 /usr/local/bin/ws-proxy.py

# TLS front: stunnel on the TLS port forwards to the plain WebSocket proxy
STUNNEL_BIN=$(command -v stunnel4 || command -v stunnel)
cat > /etc/sshws/stunnel.conf << EOF
foreground = yes
cert = ${PEM}
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ws-tls]
accept = ${WSS_PORT}
connect = 127.0.0.1:${WS_PORT}
EOF

cat > /etc/systemd/system/ws-proxy.service << EOF
[Unit]
Description=SSH WebSocket proxy
After=network.target

[Service]
Type=simple
User=nobody
Environment=WS_PORT=${WS_PORT}
Environment=SSH_PORT=${SSH_PORT}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/bin/python3 /usr/local/bin/ws-proxy.py
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/ws-tls.service << EOF
[Unit]
Description=TLS front for the SSH WebSocket proxy (stunnel)
After=network.target ws-proxy.service

[Service]
Type=simple
ExecStart=${STUNNEL_BIN} /etc/sshws/stunnel.conf
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ws-proxy ws-tls >/dev/null 2>&1
systemctl restart ws-proxy
systemctl restart ws-tls

# open the ports if ufw is active
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${WS_PORT}/tcp" >/dev/null 2>&1
    ufw allow "${WSS_PORT}/tcp" >/dev/null 2>&1
fi

# ---------- speed-limit helper ----------
echo -e "${YELLOW}[8/10] Installing per-user limits and torrent blocking...${NC}"
cat > /usr/local/bin/ws-limit << 'LIMIT_EOF'
#!/bin/bash
# Per-user speed limits for SSH tunnels - Script by Coldplay
#
#   ws-limit apply    rebuild all limits from the user list
#   ws-limit clear    remove every limit
#   ws-limit status   show the active limits
#
# How it works: sockets that sshd opens for a user's tunnelled traffic are
# owned by that user's uid. iptables marks them (and their connections) and
# tc/htb shapes the marked traffic: uploads on the network interface,
# downloads on an IFB device that is fed from the interface's ingress.

DB=/etc/sshws/users.db
IFACE_FILE=/etc/sshws/iface
CHAIN=WSLIMIT
IFB=ifbws0
DEF=ffe0

detect_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

fw_clear() {
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while "$ipt" -t mangle -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
        "$ipt" -t mangle -F "$CHAIN" 2>/dev/null
        "$ipt" -t mangle -X "$CHAIN" 2>/dev/null
    done
}

clear_all() {
    local dev
    fw_clear
    for dev in "$(cat "$IFACE_FILE" 2>/dev/null)" "$(detect_iface)"; do
        [[ -z $dev ]] && continue
        tc qdisc del dev "$dev" root 2>/dev/null
        tc qdisc del dev "$dev" ingress 2>/dev/null
    done
    ip link del "$IFB" 2>/dev/null
    rm -f "$IFACE_FILE"
}

# build_htb <device> <root-major>: one class per limited user, the rest unlimited
build_htb() {
    local dev=$1 maj=$2 i mark cls
    tc qdisc add dev "$dev" root handle "${maj}:" htb default "$DEF" || return 1
    tc class add dev "$dev" parent "${maj}:" classid "${maj}:1" htb rate 10gbit || return 1
    tc class add dev "$dev" parent "${maj}:1" classid "${maj}:${DEF}" htb \
        rate 10gbit ceil 10gbit burst 1m cburst 1m || return 1
    tc qdisc add dev "$dev" parent "${maj}:${DEF}" handle "${DEF}:" fq_codel 2>/dev/null
    for i in "${!names[@]}"; do
        mark=$((i + 1))
        cls=$(printf '%x' $((i + 16)))
        tc class add dev "$dev" parent "${maj}:1" classid "${maj}:${cls}" htb \
            rate "${rates[$i]}mbit" ceil "${rates[$i]}mbit" burst 64k cburst 64k || return 1
        tc qdisc add dev "$dev" parent "${maj}:${cls}" handle "${cls}:" fq_codel 2>/dev/null
        tc filter add dev "$dev" parent "${maj}:" protocol all prio 1 \
            handle "$mark" fw flowid "${maj}:${cls}" || return 1
    done
}

apply() {
    local c missing=""
    for c in tc ip iptables; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [[ -n $missing ]]; then
        echo "missing tools:$missing (install iproute2 and iptables)"
        return 1
    fi

    # users that have a speed limit
    local -a names=() uids=() rates=()
    local u exp m s uid
    if [[ -f $DB ]]; then
        while IFS='|' read -r u exp m s; do
            [[ -z $u || ! $s =~ ^[0-9]+$ ]] && continue
            s=$((10#$s))
            (( s > 0 )) || continue
            uid=$(id -u "$u" 2>/dev/null) || continue
            names+=("$u"); uids+=("$uid"); rates+=("$s")
        done < "$DB"
    fi

    clear_all
    (( ${#names[@]} == 0 )) && return 0

    local IF mod
    IF=$(detect_iface)
    if [[ -z $IF ]]; then
        echo "could not detect the network interface"
        return 1
    fi
    echo "$IF" > "$IFACE_FILE"

    for mod in sch_htb sch_fq_codel cls_fw xt_owner xt_MARK xt_CONNMARK act_connmark act_mirred; do
        modprobe "$mod" 2>/dev/null
    done
    modprobe ifb numifbs=0 2>/dev/null

    # mark everything each limited user's sshd sockets send
    local ipt i mark
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        "$ipt" -t mangle -N "$CHAIN" 2>/dev/null
        "$ipt" -t mangle -I OUTPUT 1 -j "$CHAIN" 2>/dev/null
        for i in "${!names[@]}"; do
            mark=$((i + 1))
            if ! "$ipt" -t mangle -A "$CHAIN" -m owner --uid-owner "${uids[$i]}" -j MARK --set-mark "$mark" 2>/dev/null \
               || ! "$ipt" -t mangle -A "$CHAIN" -m owner --uid-owner "${uids[$i]}" -j CONNMARK --save-mark 2>/dev/null; then
                if [[ $ipt == iptables ]]; then
                    echo "this kernel's iptables lacks the owner/MARK/CONNMARK modules"
                    clear_all
                    return 1
                fi
            fi
        done
    done

    # uploads: shape on the network interface
    if ! build_htb "$IF" 1; then
        echo "tc could not create the traffic classes on $IF (htb not available?)"
        clear_all
        return 1
    fi

    # downloads: mirror the interface's ingress to an IFB device and shape there
    if ip link add "$IFB" type ifb 2>/dev/null \
       && ip link set "$IFB" up \
       && build_htb "$IFB" 2 \
       && tc qdisc add dev "$IF" handle ffff: ingress \
       && tc filter add dev "$IF" parent ffff: protocol all prio 1 u32 match u32 0 0 \
              action connmark action mirred egress redirect dev "$IFB"; then
        return 0
    fi
    echo "warning: download limits are not available (kernel lacks ifb/act_connmark); only uploads are limited"
    tc qdisc del dev "$IF" ingress 2>/dev/null
    ip link del "$IFB" 2>/dev/null
    return 2
}

status() {
    local dev
    dev=$(cat "$IFACE_FILE" 2>/dev/null)
    if [[ -z $dev ]]; then
        echo "no speed limits are active"
        return 0
    fi
    echo "== upload side ($dev) =="
    tc -s class show dev "$dev" 2>/dev/null
    echo "== download side ($IFB) =="
    tc -s class show dev "$IFB" 2>/dev/null
}

case ${1:-apply} in
    apply)  apply ;;
    clear)  clear_all ;;
    status) status ;;
    *) echo "usage: ws-limit apply|clear|status"; exit 1 ;;
esac
LIMIT_EOF
chmod 755 /usr/local/bin/ws-limit

cat > /etc/systemd/system/ws-limit.service << EOF
[Unit]
Description=Per-user speed limits for SSH tunnels
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ws-limit apply
ExecStop=/usr/local/bin/ws-limit clear

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ws-limit >/dev/null 2>&1
/usr/local/bin/ws-limit apply >/dev/null 2>&1

cat > /usr/local/bin/ws-connlimit << 'CONN_EOF'
#!/bin/bash
# Enforce the per-user connection limit ("Max users") - Script by Coldplay
#
# sshd's own limit (pam_limits maxlogins) only counts interactive logins, so
# tunnel-only connections slip past it. This service counts the real SSH
# connections of every user in the user list and drops the NEWEST ones above
# that user's limit. The oldest connections are kept.
#
# usage: ws-connlimit [users.db]      (default /etc/sshws/users.db)

DB=${1:-/etc/sshws/users.db}
INTERVAL=2

enforce_once() {
    local out pid user lim
    # oldest connection first, so everything past the limit is the newest
    out=$(ps -eo user:32=,pid=,args= --sort=-etimes,pid 2>/dev/null | awk -v dbfile="$DB" '
        BEGIN {
            while ((getline line < dbfile) > 0) {
                split(line, f, "|")
                if (f[1] != "" && f[3] ~ /^[0-9]+$/ && f[3] + 0 > 0) limit[f[1]] = f[3] + 0
            }
            close(dbfile)
        }
        $3 ~ /^sshd(-session)?:$/ && ($1 in limit) {
            if (++seen[$1] > limit[$1]) print $2, $1, limit[$1]
        }')
    [[ -z $out ]] && return 0
    while read -r pid user lim; do
        kill -KILL "$pid" 2>/dev/null && echo "dropped an extra connection of '$user' (limit $lim)"
    done <<< "$out"
}

while true; do
    enforce_once
    sleep "$INTERVAL"
done
CONN_EOF
chmod 755 /usr/local/bin/ws-connlimit

cat > /etc/systemd/system/ws-connlimit.service << EOF
[Unit]
Description=Enforce per-user connection limits for SSH tunnels
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ws-connlimit /etc/sshws/users.db
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ws-connlimit >/dev/null 2>&1
systemctl restart ws-connlimit

# ---------- torrent blocking ----------
cat > /usr/local/bin/torrent-block << 'TORRENT_EOF'
#!/bin/bash
# Torrent and abuse blocking for SSH tunnel users - Script by Coldplay
#
#   torrent-block apply     build (or rebuild) the rules
#   torrent-block clear     remove all of them
#   torrent-block status    show whether they are active
#
# Based on https://github.com/090ebier/torrent-blocking-script, reviewed and
# changed so that:
#   - it is safe to re-run: no duplicate rules, older copies are removed first
#   - the rules go at the TOP of the chains, so an early "ACCEPT established"
#     rule (ufw, cloud images) cannot skip them
#   - outbound blocks only affect user accounts (uid 1000-65534), never the
#     server's own services (DNS, apt, certbot)
#   - it does not download or run any other script and does not need
#     iptables-persistent (torrent-block.service re-applies it at every boot)

USERS=1000-65534
RESOLV=${RESOLV_CONF:-/etc/resolv.conf}

STRINGS=("BitTorrent" "BitTorrent protocol" "peer_id=" ".torrent" "torrent" "announce" "info_hash" "get_peers" "announce_peer" "find_node")
SMTP_PORTS=(25 465 587)
BLOCK4=(10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
        192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
        240.0.0.0/24 224.0.0.0/4 233.252.0.0/24 185.235.86.0/24 185.235.87.0/24
        114.208.187.0/24 216.218.185.0/24 206.191.152.0/24 45.14.174.0/24
        195.137.167.0/24 103.58.50.0/24 25.0.0.0/19)
BLOCK6=(fc00::/7 fe80::/10 ff00::/8)
CHAINS=(TORRENT_CHAIN_INPUT TORRENT_CHAIN_OUTPUT TORRENT_CHAIN_FORWARD abuse-defender)

remove_rules() {   # remove_rules <iptables|ip6tables>
    local ipt=$1 c
    # jumps: the scoped form used here and the plain form of the original script
    while "$ipt" -D INPUT -j TORRENT_CHAIN_INPUT 2>/dev/null; do :; done
    while "$ipt" -D FORWARD -j TORRENT_CHAIN_FORWARD 2>/dev/null; do :; done
    while "$ipt" -D OUTPUT -j TORRENT_CHAIN_OUTPUT 2>/dev/null; do :; done
    while "$ipt" -D OUTPUT -j abuse-defender 2>/dev/null; do :; done
    while "$ipt" -D OUTPUT -m owner --uid-owner "$USERS" -j TORRENT_CHAIN_OUTPUT 2>/dev/null; do :; done
    while "$ipt" -D OUTPUT -m owner --uid-owner "$USERS" -j abuse-defender 2>/dev/null; do :; done
    for c in "${CHAINS[@]}"; do
        "$ipt" -F "$c" 2>/dev/null
        "$ipt" -X "$c" 2>/dev/null
    done
}

build() {   # build <iptables|ip6tables> <4|6>
    local ipt=$1 ver=$2 c s p ns cidr
    command -v "$ipt" >/dev/null 2>&1 || return 0
    remove_rules "$ipt"
    for c in "${CHAINS[@]}"; do
        "$ipt" -N "$c" 2>/dev/null || return 1
    done

    # inbound: the classic BitTorrent ports
    for p in tcp udp; do
        "$ipt" -A TORRENT_CHAIN_INPUT -p "$p" --dport 6881:6889 -j DROP || return 1
    done

    # outbound (only user accounts reach this chain, see the jump below)
    for s in "${STRINGS[@]}"; do
        "$ipt" -A TORRENT_CHAIN_OUTPUT -m string --algo bm --string "$s" -j DROP 2>/dev/null || return 3
        "$ipt" -A TORRENT_CHAIN_FORWARD -m string --algo bm --string "$s" -j DROP 2>/dev/null || return 3
    done
    for p in tcp udp; do
        "$ipt" -A TORRENT_CHAIN_OUTPUT -p "$p" --dport 6881:6889 -j DROP || return 1
    done
    for p in "${SMTP_PORTS[@]}"; do
        "$ipt" -A TORRENT_CHAIN_OUTPUT -p tcp --dport "$p" -j DROP || return 1
        "$ipt" -A TORRENT_CHAIN_FORWARD -p tcp --dport "$p" -j DROP || return 1
    done

    # private / reserved ranges: DNS to the server's own resolvers stays open
    for ns in $(awk '/^nameserver[ \t]/ {print $2}' "$RESOLV" 2>/dev/null); do
        ns=${ns%%%*}
        if { [[ $ver == 4 ]] && [[ $ns != *:* ]]; } || { [[ $ver == 6 ]] && [[ $ns == *:* ]]; }; then
            for p in udp tcp; do
                "$ipt" -A abuse-defender -d "$ns" -p "$p" --dport 53 -j RETURN || return 1
            done
        fi
    done
    if [[ $ver == 4 ]]; then
        for cidr in "${BLOCK4[@]}"; do "$ipt" -A abuse-defender -d "$cidr" -j DROP || return 1; done
    else
        for cidr in "${BLOCK6[@]}"; do "$ipt" -A abuse-defender -d "$cidr" -j DROP || return 1; done
    fi

    # hook the chains in at the very top
    "$ipt" -I INPUT 1 -j TORRENT_CHAIN_INPUT || return 1
    "$ipt" -I FORWARD 1 -j TORRENT_CHAIN_FORWARD || return 1
    "$ipt" -I OUTPUT 1 -m owner --uid-owner "$USERS" -j TORRENT_CHAIN_OUTPUT || return 1
    "$ipt" -I OUTPUT 1 -m owner --uid-owner "$USERS" -j abuse-defender || return 1
    return 0
}

clear_all() {
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 && remove_rules "$ipt"
    done
    return 0
}

apply() {
    if ! command -v iptables >/dev/null 2>&1; then
        echo "iptables is not installed"
        return 1
    fi
    modprobe xt_string 2>/dev/null
    modprobe xt_owner 2>/dev/null
    local rc
    build iptables 4
    rc=$?
    if (( rc == 3 )); then
        clear_all
        echo "this kernel's iptables has no 'string' match, so torrent blocking cannot be enabled here"
        return 1
    elif (( rc != 0 )); then
        clear_all
        echo "could not build the firewall rules"
        return 1
    fi
    # IPv6 is best effort
    if ! build ip6tables 6; then
        remove_rules ip6tables
        echo "warning: the IPv6 rules could not be applied (IPv4 is protected)"
    fi
    return 0
}

status() {
    if iptables -C OUTPUT -m owner --uid-owner "$USERS" -j TORRENT_CHAIN_OUTPUT 2>/dev/null; then
        echo "torrent blocking: active ($(iptables -S TORRENT_CHAIN_OUTPUT 2>/dev/null | grep -c -- '-j DROP') drop rules)"
        return 0
    fi
    echo "torrent blocking: off"
    return 1
}

case ${1:-apply} in
    apply)  apply ;;
    clear)  clear_all ;;
    status) status ;;
    *) echo "usage: torrent-block apply|clear|status"; exit 1 ;;
esac
TORRENT_EOF
chmod 755 /usr/local/bin/torrent-block

cat > /etc/systemd/system/torrent-block.service << EOF
[Unit]
Description=Torrent and abuse blocking for SSH tunnel users
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/torrent-block apply
ExecStop=/usr/local/bin/torrent-block clear

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable torrent-block >/dev/null 2>&1
systemctl restart torrent-block || echo -e "${YELLOW}Torrent blocking could not be enabled on this server (run: torrent-block apply).${NC}"

# rpcbind is not needed here and is often abused for DDoS amplification
systemctl stop rpcbind.service rpcbind.socket >/dev/null 2>&1
systemctl disable rpcbind.service rpcbind.socket >/dev/null 2>&1
systemctl mask rpcbind.service rpcbind.socket >/dev/null 2>&1

# ---------- web panel ----------
echo -e "${YELLOW}[9/10] Installing the SSH Manager web panel...${NC}"
PANEL_OK=0
PANEL_PASS=""
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' 2>/dev/null; then
    mkdir -p /usr/local/share/ssh-manager
cat > /usr/local/bin/ssh-manager-panel.py << 'PANEL_PY_EOF'
#!/usr/bin/env python3
"""SSH Manager by Coldplay - web panel for the SSH-over-WebSocket server.

Standard library only. Commands:
    ssh-manager-panel.py serve              run the panel (default)
    ssh-manager-panel.py init               create the panel login on first install
    ssh-manager-panel.py info               print port / path / username
    ssh-manager-panel.py reset              generate a new random password
    ssh-manager-panel.py set-port PORT      change the panel port
"""

import collections
import datetime
import hashlib
import hmac
import json
import os
import pwd
import random
import re
import secrets
import signal
import socket
import ssl
import string
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.1.0"

SSHWS_DIR = os.environ.get("SSHWS_DIR", "/etc/sshws")
CONF_FILE = os.path.join(SSHWS_DIR, "panel.json")
DB_FILE = os.path.join(SSHWS_DIR, "users.db")
USAGE_FILE = os.path.join(SSHWS_DIR, "usage.json")
EXTRAS_FILE = os.path.join(SSHWS_DIR, "extras.json")
LIMITS_FILE = os.environ.get("SSHWS_LIMITS", "/etc/security/limits.d/sshws.conf")
WEB_DIR = os.environ.get("SSHM_WEB", "/usr/local/share/ssh-manager")
WSLIMIT = os.environ.get("SSHM_WSLIMIT", "/usr/local/bin/ws-limit")
TORRENT_BLOCK = os.environ.get("SSHM_TORRENT", "/usr/local/bin/torrent-block")
CERT_PEM = os.environ.get("SSHM_CERT", os.path.join(SSHWS_DIR, "ssh-ws.pem"))
SSH_PORT = int(os.environ.get("SSH_PORT", "22"))

USERNAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{2,31}$")
HASH_RE = re.compile(r"^\$[A-Za-z0-9./$]{4,250}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

SESSION_TTL = 12 * 3600
MAX_BODY = 8 * 1024 * 1024
GB = 1024 ** 3
LOGIN_MAX_FAILS = 5
LOGIN_WINDOW = 600
LOGIN_LOCK = 300


def log(msg):
    print(f"[ssh-manager] {msg}", file=sys.stderr, flush=True)


# --------------------------------------------------------------------------- files

def atomic_write(path, text, mode=0o600):
    tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def read_text(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def run(cmd, input_text=None, timeout=30):
    try:
        p = subprocess.run(cmd, input=input_text, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 127, str(e)


# --------------------------------------------------------------------------- config / auth

def load_conf():
    try:
        with open(CONF_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save_conf(conf):
    os.makedirs(SSHWS_DIR, exist_ok=True)
    atomic_write(CONF_FILE, json.dumps(conf, indent=2), 0o600)


def make_hash(password, salt=None, iterations=200000):
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), iterations)
    return {"salt": salt, "iterations": iterations, "hash": dk.hex()}


def verify_login(conf, username, password):
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(conf["salt"]), int(conf["iterations"]))
    ok_pw = hmac.compare_digest(dk.hex(), conf["hash"])
    ok_user = hmac.compare_digest(username.encode(), conf["username"].encode())
    return ok_pw and ok_user


def pick_port():
    rnd = random.SystemRandom()
    for _ in range(300):
        port = rnd.randint(20000, 59999)
        with socket.socket() as s:
            try:
                s.bind(("0.0.0.0", port))
                return port
            except OSError:
                continue
    raise RuntimeError("no free port found")


def rand_text(n, alphabet):
    return "".join(secrets.choice(alphabet) for _ in range(n))


def new_conf():
    password = rand_text(14, string.ascii_letters + string.digits)
    conf = {
        "port": pick_port(),
        "path": rand_text(12, string.ascii_lowercase + string.digits),
        "username": rand_text(8, string.ascii_lowercase),
    }
    conf.update(make_hash(password))
    return conf, password


class Sessions:
    def __init__(self):
        self.lock = threading.Lock()
        self.items = {}
        self.fails = {}

    def create(self):
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
        with self.lock:
            now = time.time()
            self.items = {t: s for t, s in self.items.items() if s["exp"] > now}
            self.items[token] = {"csrf": csrf, "exp": now + SESSION_TTL}
        return token, csrf

    def get(self, token):
        if not token:
            return None
        with self.lock:
            s = self.items.get(token)
            if s and s["exp"] > time.time():
                return s
            self.items.pop(token, None)
        return None

    def drop(self, token):
        with self.lock:
            self.items.pop(token, None)

    def drop_all(self):
        with self.lock:
            self.items.clear()

    def locked(self, ip):
        with self.lock:
            f = self.fails.get(ip)
            return bool(f and f.get("until", 0) > time.time())

    def failed(self, ip):
        with self.lock:
            now = time.time()
            f = self.fails.get(ip)
            if not f or now - f["first"] > LOGIN_WINDOW:
                f = {"count": 0, "first": now, "until": 0}
            f["count"] += 1
            if f["count"] >= LOGIN_MAX_FAILS:
                f["until"] = now + LOGIN_LOCK
                f["count"] = 0
                f["first"] = now
            self.fails[ip] = f

    def ok(self, ip):
        with self.lock:
            self.fails.pop(ip, None)


SESSIONS = Sessions()


# --------------------------------------------------------------------------- users

class ApiError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.message, self.status = message, status


def system_user_exists(name):
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


def read_users():
    users = collections.OrderedDict()
    try:
        with open(DB_FILE) as f:
            for line in f:
                parts = line.rstrip("\n").split("|")
                if len(parts) < 3 or not USERNAME_RE.match(parts[0]):
                    continue
                try:
                    mx = max(1, int(parts[2]))
                except ValueError:
                    mx = 1
                try:
                    sp = max(0, int(parts[3])) if len(parts) > 3 and parts[3] != "" else 0
                except ValueError:
                    sp = 0
                users[parts[0]] = {"expires": parts[1], "max": mx, "speed": sp}
    except OSError:
        pass
    return users


def write_users(users):
    os.makedirs(SSHWS_DIR, exist_ok=True)
    text = "".join(f"{n}|{u['expires']}|{u['max']}|{u['speed']}\n" for n, u in users.items())
    atomic_write(DB_FILE, text, 0o600)


def set_maxlogins(name, count):
    lines = []
    try:
        with open(LIMITS_FILE) as f:
            lines = [l for l in f.read().splitlines() if not re.match(rf"^{re.escape(name)}\s", l)]
    except OSError:
        pass
    if count:
        lines.append(f"{name} hard maxlogins {count}")
    try:
        atomic_write(LIMITS_FILE, "\n".join(lines) + ("\n" if lines else ""), 0o644)
    except OSError:
        pass


def apply_limits():
    if os.path.exists(WSLIMIT):
        run([WSLIMIT, "apply"], timeout=60)


def today():
    return datetime.date.today()


def valid_date(text):
    if not DATE_RE.match(text or ""):
        return False
    try:
        datetime.date.fromisoformat(text)
        return True
    except ValueError:
        return False


def need_int(body, key, lo, hi, default=None):
    value = body.get(key, default)
    if value is None or value == "":
        raise ApiError(f"'{key}' is required")
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise ApiError(f"'{key}' must be a whole number")
    if not lo <= value <= hi:
        raise ApiError(f"'{key}' must be between {lo} and {hi}")
    return value


def need_quota(body, key="quota_gb"):
    """Data limit in GB (decimals allowed) -> bytes. Empty or 0 means unlimited."""
    value = body.get(key, 0)
    if value is None or value == "":
        return 0
    if isinstance(value, bool):
        raise ApiError("'quota_gb' must be a number")
    try:
        gb = float(value)
    except (TypeError, ValueError):
        raise ApiError("'quota_gb' must be a number")
    if not (0 <= gb <= 1000000):
        raise ApiError("'quota_gb' must be between 0 and 1,000,000")
    return int(gb * GB)


def need_password(body, key="password"):
    pw = body.get(key)
    if not isinstance(pw, str) or pw == "":
        raise ApiError("A password is required")
    if len(pw) > 128 or any(c in pw for c in "\r\n\0"):
        raise ApiError("Password is too long or contains a line break")
    return pw


def sys_add_user(name, expires, password=None, pw_hash=None):
    base = ["useradd", "-M", "-s", "/bin/false", "-e", expires]
    if pw_hash:
        base += ["-p", pw_hash]
    rc, out = run(base + [name])
    if rc != 0:
        rc, out = run(base[:1] + ["--badname"] + base[1:] + [name])
    if rc != 0:
        raise ApiError(f"Could not create the system user: {out or 'useradd failed'}", 500)
    if password is not None:
        rc, out = run(["chpasswd"], input_text=f"{name}:{password}\n")
        if rc != 0:
            run(["userdel", "-f", name])
            raise ApiError(f"Could not set the password: {out}", 500)


def sys_delete_user(name):
    run(["pkill", "-KILL", "-u", name])
    rc, out = run(["userdel", name])
    if rc != 0 and system_user_exists(name):
        rc, out = run(["userdel", "-f", name])
    return rc == 0 or not system_user_exists(name)


def shadow_hashes():
    out = {}
    try:
        with open("/etc/shadow") as f:
            for line in f:
                p = line.rstrip("\n").split(":")
                if len(p) > 1:
                    out[p[0]] = p[1]
    except OSError:
        pass
    return out


def days_left(expires):
    try:
        return (datetime.date.fromisoformat(expires) - today()).days
    except ValueError:
        return 0


# --------------------------------------------------------------------------- usage tracker

# Title of an authenticated sshd session process: "sshd: user" (port forwarding only), "sshd: user@notty"
# or "sshd: user@pts/0". The pre-login processes ("sshd: user [priv]", "[net]") do not match.
POST_AUTH = re.compile(rb"^sshd(?:-session)?: ([^\s@\[\]]+)(?:@\S+)?$")


def diag_tcp(family):
    """Established TCP sockets with byte counters, straight from the kernel (sock_diag)."""
    s = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, 4)
    s.settimeout(5)
    try:
        payload = struct.pack("=BBBBI", family, socket.IPPROTO_TCP, 1 << 1, 0, 1 << 1) + b"\x00" * 48
        s.send(struct.pack("=IHHII", 16 + len(payload), 20, 0x01 | 0x300, 1, 0) + payload)
        out, done = [], False
        while not done:
            data = s.recv(1 << 20)
            if not data:
                break
            off = 0
            while off + 16 <= len(data):
                ln, typ = struct.unpack_from("=IH", data, off)
                if ln < 16:
                    done = True
                    break
                if typ == 3:
                    done = True
                    break
                if typ == 2:
                    raise OSError("sock_diag refused the request")
                body = data[off + 16: off + ln]
                if len(body) >= 72:
                    sport, dport = struct.unpack_from("!HH", body, 4)
                    inode = struct.unpack_from("=I", body, 68)[0]
                    rec = {"sport": sport, "dport": dport, "inode": inode}
                    a = 72
                    while a + 4 <= len(body):
                        alen, atype = struct.unpack_from("=HH", body, a)
                        if alen < 4:
                            break
                        if atype == 2 and alen - 4 >= 136:
                            rec["acked"], rec["recv"] = struct.unpack_from("=QQ", body, a + 4 + 120)
                        a += (alen + 3) & ~3
                    out.append(rec)
                off += (ln + 3) & ~3
        return out
    finally:
        s.close()


def proc_owners():
    """socket inode -> username, for sockets held by an authenticated sshd session process."""
    owners = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                cmd = f.read(256)
        except OSError:
            continue
        m = POST_AUTH.match(cmd.split(b"\0")[0].rstrip())
        if not m:
            continue
        user = m.group(1).decode("utf-8", "replace")
        try:
            for fd in os.listdir(f"/proc/{pid}/fd"):
                try:
                    link = os.readlink(f"/proc/{pid}/fd/{fd}")
                except OSError:
                    continue
                if link.startswith("socket:["):
                    owners[int(link[8:-1])] = user
        except OSError:
            continue
    return owners


class Tracker(threading.Thread):
    """Counts the bytes every managed user moves through the SSH connections."""

    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.totals = {}
        self.conns = {}
        self.online = {}
        self.first = True
        self.dirty = False
        self.ok = None
        self.last_save = time.time()
        try:
            with open(USAGE_FILE) as f:
                data = json.load(f).get("users", {})
            for n, v in data.items():
                self.totals[n] = {"up": int(v.get("up", 0)), "down": int(v.get("down", 0))}
        except (OSError, ValueError, AttributeError):
            pass

    def run(self):
        while True:
            try:
                self.sample()
                self.ok = True
            except Exception as e:  # keep the thread alive whatever happens
                if self.ok is not False:
                    log(f"usage tracking problem: {e}")
                self.ok = False
            try:
                enforce_policies()
            except Exception as e:
                log(f"policy problem: {e}")
            if self.dirty and time.time() - self.last_save >= 5:
                self.save()
            time.sleep(1)

    def sample(self):
        entries = diag_tcp(socket.AF_INET)
        try:
            entries += diag_tcp(socket.AF_INET6)
        except OSError:
            pass
        ssh = [e for e in entries if e["sport"] == SSH_PORT and "recv" in e]
        managed = set(read_users())
        owners = proc_owners() if ssh else {}
        now_conns, online = {}, collections.Counter()
        with self.lock:
            for e in ssh:
                user = owners.get(e["inode"])
                if not user or user not in managed:
                    continue
                rx, tx = e["recv"], e["acked"]
                prev = self.conns.get(e["inode"])
                if prev is None:
                    d_rx, d_tx = (0, 0) if self.first else (rx, tx)
                else:
                    d_rx, d_tx = rx - prev[0], tx - prev[1]
                    if d_rx < 0 or d_tx < 0:
                        d_rx, d_tx = rx, tx
                if d_rx or d_tx:
                    t = self.totals.setdefault(user, {"up": 0, "down": 0})
                    t["up"] += d_rx
                    t["down"] += d_tx
                    self.dirty = True
                now_conns[e["inode"]] = (rx, tx, user)
                online[user] += 1
            self.conns, self.online, self.first = now_conns, dict(online), False

    def save(self):
        with self.lock:
            data = {"users": self.totals, "updated": int(time.time())}
            self.dirty = False
        try:
            atomic_write(USAGE_FILE, json.dumps(data), 0o600)
        except OSError as e:
            log(f"could not save usage: {e}")
        self.last_save = time.time()

    def get(self, name):
        with self.lock:
            t = self.totals.get(name, {"up": 0, "down": 0})
            return t["up"], t["down"], self.online.get(name, 0)

    def reset(self, name):
        with self.lock:
            self.totals[name] = {"up": 0, "down": 0}
            self.dirty = True
        self.save()

    def forget(self, name):
        with self.lock:
            self.totals.pop(name, None)
            self.dirty = True
        self.save()

    def set_totals(self, name, up, down):
        with self.lock:
            self.totals[name] = {"up": max(0, int(up)), "down": max(0, int(down))}
            self.dirty = True


TRACKER = Tracker()


class Extras:
    """Per-user settings that are not part of users.db: paused flag and data limit (bytes)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.data = {}
        try:
            with open(EXTRAS_FILE) as f:
                for n, v in json.load(f).get("users", {}).items():
                    self.data[n] = {"paused": bool(v.get("paused", False)), "quota": max(0, int(v.get("quota", 0)))}
        except (OSError, ValueError, AttributeError):
            pass

    def get(self, name):
        with self.lock:
            v = self.data.get(name)
            return dict(v) if v else {"paused": False, "quota": 0}

    def save(self):
        with self.lock:
            text = json.dumps({"users": self.data})
        try:
            atomic_write(EXTRAS_FILE, text, 0o600)
        except OSError as e:
            log(f"could not save user settings: {e}")

    def set(self, name, paused=None, quota=None):
        with self.lock:
            v = dict(self.data.get(name) or {"paused": False, "quota": 0})
            if paused is not None:
                v["paused"] = bool(paused)
            if quota is not None:
                v["quota"] = int(quota)
            if v["paused"] or v["quota"]:
                self.data[name] = v
            else:
                self.data.pop(name, None)
        self.save()

    def forget(self, name):
        with self.lock:
            existed = self.data.pop(name, None) is not None
        if existed:
            self.save()

    def prune(self, names):
        keep = set(names)
        with self.lock:
            gone = [n for n in self.data if n not in keep]
            for n in gone:
                del self.data[n]
        if gone:
            self.save()


EXTRAS = Extras()
NO_PASSWORD = ("", "!", "!!", "*", "x")


def blocked_reason(name):
    """'paused', 'quota' or None."""
    ex = EXTRAS.get(name)
    if ex["paused"]:
        return "paused"
    up, down, _ = TRACKER.get(name)
    if ex["quota"] > 0 and up + down >= ex["quota"]:
        return "quota"
    return None


def sync_lock(name, shadow=None):
    """Lock the system account while the user is paused or over the data limit, unlock it otherwise.
    A locked account cannot log in, and its open connections are dropped."""
    h = (shadow if shadow is not None else shadow_hashes()).get(name)
    if h is None or h in NO_PASSWORD:
        return
    want = blocked_reason(name) is not None
    locked = h.startswith("!")
    if want and not locked:
        run(["usermod", "-L", name])
    elif not want and locked:
        run(["usermod", "-U", name])
    if want and (not locked or TRACKER.get(name)[2]):
        run(["pkill", "-KILL", "-u", name])


def enforce_policies():
    # the lock keeps this from pruning while a restore / add is half way through
    with STORE_LOCK:
        names = list(read_users())
        if os.path.exists(DB_FILE):
            EXTRAS.prune(names)
    shadow = shadow_hashes()
    for n in names:
        sync_lock(n, shadow)


# --------------------------------------------------------------------------- VPS stats

def primary_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return ""
    finally:
        s.close()


def os_name():
    for line in read_text("/etc/os-release").splitlines():
        if line.startswith("PRETTY_NAME="):
            return line.split("=", 1)[1].strip('"')
    return os.uname().sysname


def cpu_model():
    for line in read_text("/proc/cpuinfo").splitlines():
        if line.lower().startswith(("model name", "hardware", "cpu model")):
            return line.split(":", 1)[1].strip()
    return "unknown"


class Stats(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.history = collections.deque(maxlen=90)
        self.cpu = 0.0
        self.rx_rate = self.tx_rate = 0.0
        self._cpu = self._net = None
        self.static = {
            "hostname": socket.gethostname(),
            "os": os_name(),
            "kernel": os.uname().release,
            "cpu_model": cpu_model(),
            "cores": os.cpu_count() or 1,
        }
        self.ip = ""
        self.ip_at = 0
        self.services = []
        self.services_at = 0

    @staticmethod
    def read_cpu():
        parts = read_text("/proc/stat").splitlines()[0].split()[1:]
        vals = [int(x) for x in parts[:8]]
        idle = vals[3] + vals[4]
        return sum(vals), idle

    @staticmethod
    def read_net():
        rx = tx = 0
        for line in read_text("/proc/net/dev").splitlines()[2:]:
            name, _, data = line.partition(":")
            name = name.strip()
            if not data or name == "lo" or name.startswith(("docker", "veth", "br-", "virbr")):
                continue
            f = data.split()
            rx += int(f[0])
            tx += int(f[8])
        return rx, tx

    @staticmethod
    def memory():
        m = {}
        for line in read_text("/proc/meminfo").splitlines():
            k, _, v = line.partition(":")
            m[k] = int(v.split()[0]) * 1024 if v.split() else 0
        total = m.get("MemTotal", 0)
        used = total - m.get("MemAvailable", m.get("MemFree", 0))
        st, sf = m.get("SwapTotal", 0), m.get("SwapFree", 0)
        return {"total": total, "used": max(0, used), "swap_total": st, "swap_used": max(0, st - sf)}

    def run(self):
        while True:
            try:
                self.sample()
            except Exception as e:
                log(f"stats problem: {e}")
            time.sleep(2)

    def sample(self):
        now = time.time()
        total, idle = self.read_cpu()
        rx, tx = self.read_net()
        with self.lock:
            if self._cpu:
                dt, di = total - self._cpu[0], idle - self._cpu[1]
                self.cpu = round(100.0 * (dt - di) / dt, 1) if dt > 0 else 0.0
            if self._net:
                span = max(now - self._net[2], 0.1)
                self.rx_rate = max(0.0, (rx - self._net[0]) / span)
                self.tx_rate = max(0.0, (tx - self._net[1]) / span)
            self._cpu, self._net = (total, idle), (rx, tx, now)
            mem = self.memory()
            self.history.append({
                "t": int(now), "cpu": self.cpu,
                "mem": round(100.0 * mem["used"] / mem["total"], 1) if mem["total"] else 0,
                "rx": int(self.rx_rate), "tx": int(self.tx_rate),
            })

    @staticmethod
    def count_sockets():
        tcp = 0
        for p in ("/proc/net/tcp", "/proc/net/tcp6"):
            for line in read_text(p).splitlines()[1:]:
                f = line.split()
                if len(f) > 3 and f[3] == "01":
                    tcp += 1
        udp = sum(max(0, len(read_text(p).splitlines()) - 1) for p in ("/proc/net/udp", "/proc/net/udp6"))
        return tcp, udp

    def service_states(self):
        if time.time() - self.services_at < 5 and self.services:
            return self.services
        wanted = [("ws-proxy", "WebSocket proxy", ["ws-proxy"]),
                  ("ws-tls", "TLS front (stunnel)", ["ws-tls"]),
                  ("ssh", "OpenSSH server", ["ssh", "sshd"]),
                  ("udpgw", "UDP gateway", ["udpgw"]),
                  ("ws-connlimit", "Connection limits", ["ws-connlimit"]),
                  ("torrent-block", "Torrent blocking", ["torrent-block"])]
        out = []
        for key, label, units in wanted:
            state = "unknown"
            if key == "torrent-block":
                # the rules can be switched on from the menu without the boot unit running, so ask the rules themselves
                if os.path.exists(TORRENT_BLOCK):
                    state = "active" if run([TORRENT_BLOCK, "status"], timeout=10)[0] == 0 else "off"
                out.append({"key": key, "label": label, "state": state})
                continue
            for u in units:
                rc, text = run(["systemctl", "is-active", u], timeout=5)
                if rc == 127:
                    break
                if text == "active":
                    state = "active"
                    break
                if text in ("inactive", "failed", "activating", "deactivating"):
                    state = state if state == "active" else text
            out.append({"key": key, "label": label, "state": state})
        self.services, self.services_at = out, time.time()
        return out

    def snapshot(self):
        mem = self.memory()
        st = os.statvfs("/")
        disk_total = st.f_blocks * st.f_frsize
        disk_used = disk_total - st.f_bavail * st.f_frsize
        rx, tx = self.read_net()
        tcp, udp = self.count_sockets()
        if time.time() - self.ip_at > 300:
            self.ip, self.ip_at = primary_ip(), time.time()
        try:
            up = float(read_text("/proc/uptime").split()[0])
        except (ValueError, IndexError):
            up = 0.0
        with self.lock:
            hist = list(self.history)
            cpu, rxr, txr = self.cpu, self.rx_rate, self.tx_rate
        return {
            **self.static,
            "ip": self.ip,
            "uptime": int(up),
            "load": [round(x, 2) for x in os.getloadavg()],
            "cpu": cpu,
            "mem": mem,
            "disk": {"total": disk_total, "used": disk_used},
            "net": {"rx_rate": rxr, "tx_rate": txr, "rx_total": rx, "tx_total": tx},
            "tcp": tcp, "udp": udp,
            "history": hist,
            "services": self.service_states(),
        }


STATS = Stats()


# --------------------------------------------------------------------------- API actions

STORE_LOCK = threading.RLock()


def panel_info():
    ip = STATS.ip or primary_ip()
    domain = read_text(os.path.join(SSHWS_DIR, "domain"))
    host = domain or ip
    return {
        "host": host, "domain": domain, "ip": ip,
        "ws_port": read_text(os.path.join(SSHWS_DIR, "ws_port"), "80"),
        "wss_port": read_text(os.path.join(SSHWS_DIR, "wss_port"), "443"),
        "udpgw": read_text(os.path.join(SSHWS_DIR, "udpgw_port")),
        "payload": f"GET / HTTP/1.1[crlf]Host: {host}[crlf]Upgrade: websocket[crlf][crlf]",
    }


def user_row(name, u):
    up, down, online = TRACKER.get(name)
    left = days_left(u["expires"])
    ex = EXTRAS.get(name)
    over = ex["quota"] > 0 and up + down >= ex["quota"]
    if ex["paused"]:
        status = "paused"
    elif over:
        status = "quota"
    elif left < 0:
        status = "expired"
    else:
        status = "online" if online else "offline"
    return {
        "username": name, "expires": u["expires"], "days_left": left, "expired": left < 0,
        "max_connections": u["max"], "speed_mbps": u["speed"],
        "online": online, "up": up, "down": down, "total": up + down,
        "paused": ex["paused"], "quota_bytes": ex["quota"], "quota_gb": round(ex["quota"] / GB, 2),
        "over_quota": over,
        "has_account": system_user_exists(name),
        "status": status,
    }


def list_users():
    with STORE_LOCK:
        users = read_users()
    rows = [user_row(n, u) for n, u in users.items()]
    return {
        "users": rows,
        "summary": {
            "total": len(rows),
            "online_users": sum(1 for r in rows if r["online"]),
            "connections": sum(r["online"] for r in rows),
            "expired": sum(1 for r in rows if r["expired"]),
            "paused": sum(1 for r in rows if r["paused"]),
            "over_quota": sum(1 for r in rows if r["over_quota"]),
            "up": sum(r["up"] for r in rows), "down": sum(r["down"] for r in rows),
        },
        "tracking": TRACKER.ok,
    }


def add_user(body):
    name = str(body.get("username", "")).strip()
    if not USERNAME_RE.match(name):
        raise ApiError("Username must be 3-32 characters: letters (any case), digits, _ or -, starting with a letter or _")
    password = need_password(body)
    days = need_int(body, "days", 1, 3650, 30)
    mx = need_int(body, "max_connections", 1, 1000, 1)
    speed = need_int(body, "speed_mbps", 0, 100000, 0)
    quota = need_quota(body)
    with STORE_LOCK:
        users = read_users()
        if name in users or system_user_exists(name):
            raise ApiError("That username already exists", 409)
        expires = (today() + datetime.timedelta(days=days)).isoformat()
        sys_add_user(name, expires, password=password)
        users[name] = {"expires": expires, "max": mx, "speed": speed}
        write_users(users)
        set_maxlogins(name, mx)
        TRACKER.forget(name)
        EXTRAS.set(name, paused=False, quota=quota)
    if speed > 0:
        apply_limits()
    info = panel_info()
    return {"ok": True, "user": user_row(name, users[name]), "connection": {
        **info, "username": name, "password": password, "expires": expires,
        "max_connections": mx, "speed_mbps": speed}}


def update_user(name, body):
    with STORE_LOCK:
        users = read_users()
        if name not in users:
            raise ApiError("No such user", 404)
        u = dict(users[name])
        old_speed = u["speed"]
        if body.get("expires"):
            if not valid_date(body["expires"]):
                raise ApiError("Expiry must be a date like 2026-12-31")
            u["expires"] = body["expires"]
        elif "days" in body and body["days"] not in (None, ""):
            u["expires"] = (today() + datetime.timedelta(days=need_int(body, "days", 1, 3650))).isoformat()
        if "max_connections" in body and body["max_connections"] not in (None, ""):
            u["max"] = need_int(body, "max_connections", 1, 1000)
        if "speed_mbps" in body and body["speed_mbps"] not in (None, ""):
            u["speed"] = need_int(body, "speed_mbps", 0, 100000)
        new_quota = need_quota(body) if body.get("quota_gb") not in (None, "") else None
        new_pw = body.get("password")
        if new_pw not in (None, ""):
            pw = need_password(body)
            rc, out = run(["chpasswd"], input_text=f"{name}:{pw}\n")
            if rc != 0:
                raise ApiError(f"Could not set the password: {out}", 500)
        rc, out = run(["usermod", "-e", u["expires"], name])
        if rc != 0 and system_user_exists(name):
            raise ApiError(f"Could not update the expiry: {out}", 500)
        users[name] = u
        write_users(users)
        set_maxlogins(name, u["max"])
        if new_quota is not None:
            EXTRAS.set(name, quota=new_quota)
        sync_lock(name)        # a new password must not unlock a paused user, a higher limit may unblock one
    if old_speed > 0 or u["speed"] > 0:
        apply_limits()
    return {"ok": True, "user": user_row(name, u)}


def delete_user(name):
    with STORE_LOCK:
        users = read_users()
        if name not in users:
            raise ApiError("No such user", 404)
        speed = users[name]["speed"]
        if not sys_delete_user(name):
            raise ApiError("Could not remove the system account", 500)
        del users[name]
        write_users(users)
        set_maxlogins(name, 0)
    TRACKER.forget(name)
    EXTRAS.forget(name)
    if speed > 0:
        apply_limits()
    return {"ok": True}


def set_paused(name, paused):
    with STORE_LOCK:
        users = read_users()
        if name not in users:
            raise ApiError("No such user", 404)
        EXTRAS.set(name, paused=paused)
        sync_lock(name)
        return {"ok": True, "user": user_row(name, users[name])}


def make_backup():
    with STORE_LOCK:
        users = read_users()
    shadow = shadow_hashes()
    rows = []
    for name, u in users.items():
        up, down, _ = TRACKER.get(name)
        h = shadow.get(name, "")
        if h.startswith("!"):
            h = h[1:]          # a locked account (paused / over its limit): store the normal hash
        ex = EXTRAS.get(name)
        rows.append({
            "username": name, "password_hash": h if HASH_RE.match(h) else "",
            "expires": u["expires"], "max_connections": u["max"], "speed_mbps": u["speed"],
            "up": up, "down": down, "paused": ex["paused"], "quota_bytes": ex["quota"],
        })
    return {
        "app": "ssh-manager", "format": 1, "panel_version": VERSION,
        "created": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0, tzinfo=None).isoformat() + "Z",
        "users": rows,
    }


def restore_backup(body):
    data = body.get("data")
    mode = body.get("mode", "merge")
    if mode not in ("merge", "replace"):
        raise ApiError("mode must be 'merge' or 'replace'")
    if not isinstance(data, dict) or data.get("app") != "ssh-manager" or not isinstance(data.get("users"), list):
        raise ApiError("This is not an SSH Manager backup file")
    if len(data["users"]) > 20000:
        raise ApiError("Backup has too many users")

    entries, seen = [], set()
    for i, r in enumerate(data["users"]):
        if not isinstance(r, dict):
            raise ApiError(f"Entry {i + 1} is not valid")
        name = str(r.get("username", ""))
        if not USERNAME_RE.match(name):
            raise ApiError(f"Entry {i + 1}: invalid username")
        if name in seen:
            raise ApiError(f"Entry {i + 1}: '{name}' appears twice")
        seen.add(name)
        expires = str(r.get("expires", ""))
        if not valid_date(expires):
            raise ApiError(f"'{name}': invalid expiry date")
        try:
            mx, sp = int(r.get("max_connections", 1)), int(r.get("speed_mbps", 0))
            up, down = int(r.get("up", 0)), int(r.get("down", 0))
        except (TypeError, ValueError):
            raise ApiError(f"'{name}': numbers are not valid")
        if not (1 <= mx <= 1000 and 0 <= sp <= 100000 and up >= 0 and down >= 0):
            raise ApiError(f"'{name}': value out of range")
        pw_hash = str(r.get("password_hash", ""))
        if pw_hash.startswith("!"):
            pw_hash = pw_hash[1:]
        paused = r.get("paused", False)
        if not isinstance(paused, bool):
            raise ApiError(f"'{name}': 'paused' must be true or false")
        try:
            quota = int(r.get("quota_bytes", 0))
        except (TypeError, ValueError):
            raise ApiError(f"'{name}': the data limit is not valid")
        if not 0 <= quota <= 10 ** 18:
            raise ApiError(f"'{name}': the data limit is out of range")
        entries.append({"name": name, "expires": expires, "max": mx, "speed": sp, "up": up, "down": down,
                        "paused": paused, "quota": quota,
                        "hash": pw_hash if HASH_RE.match(pw_hash) else ""})

    result = {"created": [], "updated": [], "skipped": [], "deleted": [], "no_password": []}
    with STORE_LOCK:
        users = read_users()
        speed_touched = False
        for e in entries:
            name = e["name"]
            if name not in users and system_user_exists(name):
                result["skipped"].append(f"{name} (a different system account with this name exists)")
                continue
            if name in users:
                if e["hash"]:
                    run(["usermod", "-p", e["hash"], name])
                rc, out = run(["usermod", "-e", e["expires"], name])
                if rc != 0 and not system_user_exists(name):
                    sys_add_user(name, e["expires"], pw_hash=e["hash"] or None)
                if users[name]["speed"] > 0:
                    speed_touched = True
                result["updated"].append(name)
            else:
                try:
                    sys_add_user(name, e["expires"], pw_hash=e["hash"] or None)
                except ApiError as err:
                    result["skipped"].append(f"{name} ({err.message})")
                    continue
                result["created"].append(name)
            if not e["hash"]:
                result["no_password"].append(name)
            users[name] = {"expires": e["expires"], "max": e["max"], "speed": e["speed"]}
            if e["speed"] > 0:
                speed_touched = True
            set_maxlogins(name, e["max"])
            TRACKER.set_totals(name, e["up"], e["down"])
            EXTRAS.set(name, paused=e["paused"], quota=e["quota"])
            sync_lock(name)
        if mode == "replace":
            for name in [n for n in users if n not in seen]:
                if users[name]["speed"] > 0:
                    speed_touched = True
                sys_delete_user(name)
                del users[name]
                set_maxlogins(name, 0)
                TRACKER.forget(name)
                EXTRAS.forget(name)
                result["deleted"].append(name)
        write_users(users)
    TRACKER.save()
    if speed_touched:
        apply_limits()
    result["ok"] = True
    return result


def change_credentials(conf, body):
    current = str(body.get("current_password", ""))
    if not verify_login(conf, conf["username"], current):
        raise ApiError("Current password is wrong", 403)
    new_user = str(body.get("username", "")).strip() or conf["username"]
    if not re.match(r"^[A-Za-z0-9_.-]{3,32}$", new_user):
        raise ApiError("Login name must be 3-32 characters (letters, digits, . _ -)")
    new_pw = body.get("new_password", "")
    updated = dict(conf)
    updated["username"] = new_user
    if new_pw:
        if not isinstance(new_pw, str) or len(new_pw) < 8 or len(new_pw) > 128:
            raise ApiError("New password must be 8-128 characters")
        updated.update(make_hash(new_pw))
    save_conf(updated)
    return updated


# --------------------------------------------------------------------------- HTTP

CONF = load_conf() or {}
TLS_ON = False
CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8",
                 ".css": "text/css; charset=utf-8"}


class Handler(BaseHTTPRequestHandler):
    server_version = "SSHManager"
    sys_version = ""
    timeout = 20

    def setup(self):
        if isinstance(self.request, ssl.SSLSocket):
            self.request.settimeout(15)
            self.request.do_handshake()
        super().setup()

    def log_message(self, *args):
        pass

    # -- helpers
    def security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
                         "script-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
        if TLS_ON:
            self.send_header("Strict-Transport-Security", "max-age=31536000")

    def reply(self, status, body, ctype, extra=None, cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.security_headers()
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def json_reply(self, obj, status=200, extra=None):
        self.reply(status, json.dumps(obj).encode(), "application/json", extra)

    def fail(self, message, status=400):
        self.json_reply({"ok": False, "error": message}, status)

    def session(self):
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "sshm":
                return v, SESSIONS.get(v)
        return None, None

    def read_json(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ApiError("Bad request")
        if length < 0 or length > MAX_BODY:
            raise ApiError("Request is too large", 413)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ApiError("Request body is not valid JSON")
        if not isinstance(data, dict):
            raise ApiError("Request body must be a JSON object")
        return data

    def same_origin(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        host = self.headers.get("Host", "")
        return origin.split("://", 1)[-1] == host

    # -- dispatch
    def do_GET(self):
        self.dispatch("GET")

    def do_HEAD(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def dispatch(self, method):
        global CONF
        try:
            base = "/" + CONF["path"]
            path = self.path.split("?", 1)[0]
            if path == base:
                self.send_response(301)
                self.send_header("Location", base + "/")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if not path.startswith(base + "/"):
                self.reply(404, b"404 page not found\n", "text/plain; charset=utf-8")
                return
            rel = path[len(base):]
            if method == "GET" and not rel.startswith("/api/"):
                return self.static(rel)
            if not rel.startswith("/api/"):
                return self.fail("Not found", 404)
            self.api(method, rel[4:])
        except ApiError as e:
            self.fail(e.message, e.status)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, socket.timeout):
            pass
        except Exception as e:
            log(f"error handling {self.path}: {e!r}")
            try:
                self.fail("Internal error", 500)
            except OSError:
                pass

    def static(self, rel):
        files = {"/": "index.html", "/index.html": "index.html",
                 "/static/app.js": "app.js", "/static/app.css": "app.css"}
        name = files.get(rel)
        if not name:
            return self.reply(404, b"404 page not found\n", "text/plain; charset=utf-8")
        try:
            with open(os.path.join(WEB_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return self.reply(500, b"panel files are missing\n", "text/plain; charset=utf-8")
        ctype = CONTENT_TYPES[os.path.splitext(name)[1]]
        self.reply(200, body, ctype, cache="no-cache" if name == "index.html" else "max-age=300")

    def api(self, method, rel):
        global CONF
        ip = self.client_address[0]

        if method == "POST" and rel == "/login":
            CONF = load_conf() or CONF
            if SESSIONS.locked(ip):
                return self.fail("Too many attempts. Try again in a few minutes.", 429)
            body = self.read_json()
            if verify_login(CONF, str(body.get("username", "")), str(body.get("password", ""))):
                SESSIONS.ok(ip)
                token, csrf = SESSIONS.create()
                cookie = f"sshm={token}; Path=/{CONF['path']}/; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}"
                if TLS_ON:
                    cookie += "; Secure"
                log(f"login from {ip}")
                return self.json_reply({"ok": True, "csrf": csrf}, extra=[("Set-Cookie", cookie)])
            SESSIONS.failed(ip)
            log(f"failed login from {ip}")
            time.sleep(0.5)
            return self.fail("Wrong username or password", 401)

        token, sess = self.session()
        if rel == "/me":
            if not sess:
                return self.fail("Not signed in", 401)
            return self.json_reply({"ok": True, "csrf": sess["csrf"], "version": VERSION,
                                    "login": CONF["username"]})
        if not sess:
            return self.fail("Not signed in", 401)

        if method == "POST":
            if not self.same_origin() or not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), sess["csrf"]):
                return self.fail("Request rejected (security check failed). Reload the page.", 403)

        if method == "GET":
            if rel == "/status":
                return self.json_reply({"ok": True, **STATS.snapshot()})
            if rel == "/users":
                return self.json_reply({"ok": True, **list_users()})
            if rel == "/info":
                return self.json_reply({"ok": True, **panel_info(), "panel_port": CONF["port"],
                                        "panel_path": CONF["path"], "version": VERSION,
                                        "tracking": TRACKER.ok})
            if rel == "/backup":
                stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
                body = json.dumps(make_backup(), indent=2).encode()
                return self.reply(200, body, "application/json",
                                  [("Content-Disposition", f'attachment; filename="ssh-manager-backup-{stamp}.json"')])
            return self.fail("Not found", 404)

        if method == "POST":
            if rel == "/logout":
                SESSIONS.drop(token)
                return self.json_reply({"ok": True}, extra=[(
                    "Set-Cookie", f"sshm=; Path=/{CONF['path']}/; HttpOnly; SameSite=Strict; Max-Age=0")])
            if rel == "/users":
                return self.json_reply(add_user(self.read_json()))
            if rel == "/restore":
                return self.json_reply(restore_backup(self.read_json()))
            if rel == "/password":
                CONF = change_credentials(CONF, self.read_json())
                SESSIONS.drop_all()
                return self.json_reply({"ok": True, "relogin": True})
            m = re.match(r"^/users/([A-Za-z0-9_-]{3,32})/(update|delete|reset-usage|pause|resume)$", rel)
            if m:
                name, action = m.groups()
                if action == "update":
                    return self.json_reply(update_user(name, self.read_json()))
                if action == "delete":
                    return self.json_reply(delete_user(name))
                if action in ("pause", "resume"):
                    return self.json_reply(set_paused(name, action == "pause"))
                if name not in read_users():
                    raise ApiError("No such user", 404)
                TRACKER.reset(name)
                sync_lock(name)        # the user may have been blocked only because of the data limit
                return self.json_reply({"ok": True})
        return self.fail("Not found", 404)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        # plain-HTTP clients, scanners and broken TLS handshakes on the panel port are routine: no traceback spam
        pass


def serve():
    global CONF, TLS_ON
    CONF = load_conf()
    if not CONF:
        CONF, password = new_conf()
        save_conf(CONF)
        log(f"first start: login {CONF['username']} / {password}")
    httpd = Server(("0.0.0.0", int(CONF["port"])), Handler)
    if os.path.exists(CERT_PEM) and not os.environ.get("SSHM_NO_TLS"):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(CERT_PEM)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)
        TLS_ON = True
    else:
        log("WARNING: no certificate found, serving plain HTTP")

    def stop(*_):
        TRACKER.save()
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    TRACKER.start()
    STATS.start()
    log(f"SSH Manager {VERSION} listening on port {CONF['port']} ({'https' if TLS_ON else 'http'})")
    httpd.serve_forever()


def cli(argv):
    cmd = argv[1] if len(argv) > 1 else "serve"
    if cmd == "serve":
        return serve()
    conf = load_conf()
    if cmd == "init":
        password = None
        if not conf:
            conf, password = new_conf()
            save_conf(conf)
    elif cmd == "reset":
        if not conf:
            conf, password = new_conf()
        else:
            password = rand_text(14, string.ascii_letters + string.digits)
            conf.update(make_hash(password))
        save_conf(conf)
    elif cmd == "set-port":
        if not conf:
            conf, _ = new_conf()
        try:
            port = int(argv[2])
            assert 1024 <= port <= 65535
        except (IndexError, ValueError, AssertionError):
            print("error=port must be a number between 1024 and 65535")
            return 1
        conf["port"] = port
        save_conf(conf)
        password = None
    elif cmd == "info":
        password = None
        if not conf:
            print("error=panel is not initialised")
            return 1
    else:
        print(__doc__)
        return 1
    print(f"port={conf['port']}")
    print(f"path={conf['path']}")
    print(f"username={conf['username']}")
    if password:
        print(f"password={password}")
    return 0


if __name__ == "__main__":
    sys.exit(cli(sys.argv))
PANEL_PY_EOF
chmod 755 /usr/local/bin/ssh-manager-panel.py
cat > /usr/local/share/ssh-manager/index.html << 'PANEL_HTML_EOF'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="color-scheme" content="dark light">
<title>SSH Manager by Coldplay</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%234f8cff'/%3E%3Cpath d='M9 11l6 5-6 5' fill='none' stroke='white' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'/%3E%3Cpath d='M17 22h7' stroke='white' stroke-width='3' stroke-linecap='round'/%3E%3C/svg%3E">
<link rel="stylesheet" href="static/app.css">
</head>
<body>
<div id="app"></div>
<div id="toasts" aria-live="polite"></div>
<noscript><p style="padding:24px;font-family:sans-serif">SSH Manager needs JavaScript.</p></noscript>
<script src="static/app.js"></script>
</body>
</html>
PANEL_HTML_EOF
cat > /usr/local/share/ssh-manager/app.css << 'PANEL_CSS_EOF'
:root {
  --bg: #0a0f1e;
  --bg-2: #0e1427;
  --surface: #121a30;
  --surface-2: #17213c;
  --border: #223052;
  --text: #e8edf8;
  --muted: #8d99b8;
  --accent: #4f8cff;
  --accent-2: #8b5cf6;
  --good: #22c55e;
  --warn: #f59e0b;
  --bad: #ef4444;
  --shadow: 0 10px 30px rgba(0, 0, 0, .35);
  --radius: 14px;
  --sidebar: 248px;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
}
[data-theme="light"] {
  --bg: #f3f6fc;
  --bg-2: #eaeff9;
  --surface: #ffffff;
  --surface-2: #f6f8fd;
  --border: #dfe6f3;
  --text: #0f172a;
  --muted: #62708c;
  --shadow: 0 10px 30px rgba(30, 50, 100, .10);
}
* { box-sizing: border-box; }
html, body { margin: 0; height: 100%; }
body {
  background: radial-gradient(1200px 600px at 80% -10%, rgba(79, 140, 255, .12), transparent 60%), var(--bg);
  color: var(--text);
  font-size: 14px;
  line-height: 1.45;
  -webkit-font-smoothing: antialiased;
}
button, input, select { font: inherit; color: inherit; }
a { color: var(--accent); text-decoration: none; }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.muted { color: var(--muted); }
.hidden { display: none !important; }

/* ---------- logo / brand ---------- */
.brand { display: flex; align-items: center; gap: 12px; }
.logo {
  width: 40px; height: 40px; border-radius: 11px; flex: none;
  display: grid; place-items: center; color: #fff;
  background: linear-gradient(135deg, var(--accent), var(--accent-2));
  box-shadow: 0 6px 18px rgba(79, 140, 255, .45);
}
.logo svg { width: 22px; height: 22px; }
.brand-name { font-weight: 700; font-size: 16px; letter-spacing: .2px; }
.brand-sub { font-size: 12px; color: var(--muted); }
.brand-sub b { color: var(--accent); font-weight: 600; }

/* ---------- login ---------- */
.login-wrap { min-height: 100vh; display: grid; place-items: center; padding: 24px; }
.login-card {
  width: 100%; max-width: 400px; padding: 32px; border-radius: 18px;
  background: var(--surface); border: 1px solid var(--border); box-shadow: var(--shadow);
}
.login-card .brand { justify-content: center; margin-bottom: 8px; flex-direction: column; text-align: center; gap: 12px; }
.login-card .logo { width: 56px; height: 56px; border-radius: 16px; }
.login-card .logo svg { width: 30px; height: 30px; }
.login-card h1 { margin: 0; font-size: 22px; }
.login-card .lead { margin: 4px 0 22px; text-align: center; color: var(--muted); font-size: 13px; }
.form-error { min-height: 20px; color: var(--bad); font-size: 13px; margin: 4px 0 10px; }

/* ---------- form controls ---------- */
.field { display: flex; flex-direction: column; gap: 6px; margin-bottom: 14px; }
.field > label { font-size: 12px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: .6px; }
.input {
  width: 100%; padding: 10px 12px; border-radius: 10px;
  background: var(--bg-2); border: 1px solid var(--border); outline: none;
  transition: border-color .15s, box-shadow .15s;
}
.input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(79, 140, 255, .22); }
.input-row { display: flex; gap: 8px; }
.input-row .input { flex: 1; }
.hint { font-size: 12px; color: var(--muted); }
.grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }

.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  padding: 9px 14px; border-radius: 10px; border: 1px solid var(--border);
  background: var(--surface-2); cursor: pointer; font-weight: 600; white-space: nowrap;
  transition: transform .05s, background .15s, border-color .15s, opacity .15s;
}
.btn:hover { border-color: var(--accent); }
.btn:active { transform: translateY(1px); }
.btn:disabled { opacity: .55; cursor: not-allowed; }
.btn svg { width: 16px; height: 16px; flex: none; }
.btn-primary { background: linear-gradient(135deg, var(--accent), var(--accent-2)); border-color: transparent; color: #fff; box-shadow: 0 6px 16px rgba(79, 140, 255, .35); }
.btn-primary:hover { border-color: transparent; filter: brightness(1.08); }
.btn-danger { background: rgba(239, 68, 68, .12); border-color: rgba(239, 68, 68, .45); color: var(--bad); }
.btn-danger:hover { border-color: var(--bad); }
.btn-block { width: 100%; }
.btn-sm { padding: 6px 9px; border-radius: 8px; }
.icon-btn { padding: 7px; border-radius: 9px; }

/* ---------- shell ---------- */
.shell { display: grid; grid-template-columns: var(--sidebar) 1fr; min-height: 100vh; }
.sidebar {
  position: sticky; top: 0; height: 100vh; padding: 20px 14px;
  background: var(--bg-2); border-right: 1px solid var(--border);
  display: flex; flex-direction: column; gap: 22px;
}
.sidebar .brand { padding: 0 8px; }
.nav { display: flex; flex-direction: column; gap: 4px; }
.nav a {
  display: flex; align-items: center; gap: 12px; padding: 11px 12px; border-radius: 10px;
  color: var(--muted); font-weight: 600; cursor: pointer; transition: background .15s, color .15s;
}
.nav a svg { width: 18px; height: 18px; flex: none; }
.nav a:hover { background: var(--surface-2); color: var(--text); }
.nav a.active { color: #fff; background: linear-gradient(135deg, var(--accent), var(--accent-2)); box-shadow: 0 6px 16px rgba(79, 140, 255, .3); }
.sidebar-foot { margin-top: auto; padding: 0 8px; font-size: 12px; color: var(--muted); }
.sidebar-foot b { color: var(--text); }

.main { min-width: 0; display: flex; flex-direction: column; }
.topbar {
  position: sticky; top: 0; z-index: 20; display: flex; align-items: center; gap: 12px;
  padding: 14px 28px; background: color-mix(in srgb, var(--bg) 85%, transparent);
  backdrop-filter: blur(10px); border-bottom: 1px solid var(--border);
}
.topbar h2 { margin: 0; font-size: 18px; flex: 1; }
.menu-btn { display: none; }
.content { padding: 24px 28px 48px; max-width: 1400px; width: 100%; margin: 0 auto; }
.pill {
  display: inline-flex; align-items: center; gap: 8px; padding: 6px 12px; border-radius: 999px;
  background: var(--surface); border: 1px solid var(--border); font-size: 12px; color: var(--muted);
}
.pill b { color: var(--text); }

/* ---------- cards ---------- */
.cards { display: grid; gap: 16px; }
.cards.c4 { grid-template-columns: repeat(4, 1fr); }
.cards.c3 { grid-template-columns: repeat(3, 1fr); }
.cards.c2 { grid-template-columns: repeat(2, 1fr); }
.card {
  background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
  padding: 18px; box-shadow: var(--shadow); min-width: 0;
}
.card-title { display: flex; align-items: center; gap: 8px; margin: 0 0 14px; font-size: 12px; font-weight: 700; color: var(--muted); text-transform: uppercase; letter-spacing: .7px; }
.card-title svg { width: 16px; height: 16px; }
.section-gap { margin-top: 16px; }

.gauge { display: flex; flex-direction: column; align-items: center; gap: 10px; text-align: center; }
.gauge-ring { position: relative; width: 124px; height: 124px; }
.gauge-ring svg { width: 100%; height: 100%; transform: rotate(-90deg); }
.gauge-ring .track { stroke: var(--surface-2); }
.gauge-ring .value { transition: stroke-dashoffset .6s ease, stroke .3s; }
.gauge-num { position: absolute; inset: 0; display: grid; place-items: center; font-size: 24px; font-weight: 800; }
.gauge-num small { font-size: 13px; font-weight: 600; color: var(--muted); }
.gauge-label { font-weight: 700; }
.gauge-sub { font-size: 12px; color: var(--muted); }

.kv { display: flex; flex-direction: column; gap: 10px; }
.kv-row { display: flex; justify-content: space-between; gap: 16px; padding-bottom: 10px; border-bottom: 1px dashed var(--border); }
.kv-row:last-child { border-bottom: 0; padding-bottom: 0; }
.kv-row span:first-child { color: var(--muted); }
.kv-row span:last-child { font-weight: 600; text-align: right; word-break: break-word; }

.big { font-size: 26px; font-weight: 800; letter-spacing: -.3px; }
.big small { font-size: 13px; font-weight: 600; color: var(--muted); }
.net-rows { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }
.net-rows .lbl { font-size: 12px; color: var(--muted); display: flex; align-items: center; gap: 6px; }
.net-rows .lbl svg { width: 14px; height: 14px; }
.up { color: #38bdf8; }
.down { color: var(--good); }
.spark { width: 100%; height: 64px; display: block; margin-top: 12px; }
.spark path.line { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }

.svc { display: grid; grid-template-columns: 1fr 1fr; gap: 10px 18px; }
.svc div { display: flex; align-items: center; gap: 10px; }
.dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); flex: none; }
.dot.good { background: var(--good); box-shadow: 0 0 0 3px rgba(34, 197, 94, .18); }
.dot.bad { background: var(--bad); box-shadow: 0 0 0 3px rgba(239, 68, 68, .18); }
.dot.warn { background: var(--warn); box-shadow: 0 0 0 3px rgba(245, 158, 11, .18); }

/* ---------- toolbar + table ---------- */
.toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin-bottom: 16px; }
.toolbar .grow { flex: 1; min-width: 160px; }
.search { position: relative; max-width: 360px; flex: 1; min-width: 180px; }
.search svg { position: absolute; left: 11px; top: 50%; width: 16px; height: 16px; transform: translateY(-50%); color: var(--muted); }
.search .input { padding-left: 36px; }
.chips { display: flex; gap: 6px; }
.chip {
  padding: 7px 12px; border-radius: 999px; border: 1px solid var(--border); background: var(--surface);
  cursor: pointer; font-size: 12px; font-weight: 600; color: var(--muted);
}
.chip.active { color: #fff; border-color: transparent; background: linear-gradient(135deg, var(--accent), var(--accent-2)); }

.table-wrap { overflow-x: auto; border-radius: var(--radius); border: 1px solid var(--border); background: var(--surface); box-shadow: var(--shadow); }
table { width: 100%; border-collapse: collapse; min-width: 860px; }
th, td { padding: 13px 16px; text-align: left; white-space: nowrap; }
th { font-size: 11px; font-weight: 700; color: var(--muted); text-transform: uppercase; letter-spacing: .7px; background: var(--surface-2); border-bottom: 1px solid var(--border); }
td { border-bottom: 1px solid var(--border); }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover td { background: color-mix(in srgb, var(--accent) 5%, transparent); }
.user-cell { display: flex; align-items: center; gap: 12px; font-weight: 700; }
.avatar {
  width: 34px; height: 34px; border-radius: 10px; display: grid; place-items: center; font-weight: 800; color: #fff; flex: none;
  background: linear-gradient(135deg, var(--accent), var(--accent-2));
}
.avatar.expired { background: linear-gradient(135deg, #6b7280, #4b5563); }
.usage { min-width: 190px; }
.usage-nums { display: flex; gap: 12px; font-size: 12px; margin-bottom: 6px; }
.bar { height: 6px; border-radius: 999px; background: var(--surface-2); overflow: hidden; display: flex; }
.bar i { display: block; height: 100%; }
.bar .u { background: #38bdf8; }
.bar .d { background: var(--good); }
.bar .q { background: var(--accent); transition: width .4s ease; }
.quick { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
.actions { display: flex; gap: 6px; justify-content: flex-end; }
.badge { display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 700; }
.badge.good { background: rgba(34, 197, 94, .14); color: var(--good); }
.badge.bad { background: rgba(239, 68, 68, .14); color: var(--bad); }
.badge.warn { background: rgba(245, 158, 11, .15); color: var(--warn); }
.badge.off { background: var(--surface-2); color: var(--muted); }
.empty { padding: 48px 16px; text-align: center; color: var(--muted); }
.empty svg { width: 40px; height: 40px; margin-bottom: 8px; opacity: .6; }

.stat-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 16px; margin-bottom: 16px; }
.mini { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 14px 16px; }
.mini .lbl { font-size: 12px; color: var(--muted); font-weight: 600; }
.mini .val { font-size: 22px; font-weight: 800; margin-top: 2px; }

/* ---------- modal / toast ---------- */
.overlay {
  position: fixed; inset: 0; z-index: 100; display: grid; place-items: center; padding: 20px;
  background: rgba(3, 7, 18, .62); backdrop-filter: blur(3px);
  animation: fade .15s ease;
}
.modal {
  width: 100%; max-width: 520px; max-height: calc(100vh - 40px); overflow-y: auto;
  background: var(--surface); border: 1px solid var(--border); border-radius: 16px; box-shadow: var(--shadow);
  animation: pop .18s ease;
}
.modal-head { display: flex; align-items: center; gap: 10px; padding: 18px 22px; border-bottom: 1px solid var(--border); }
.modal-head h3 { margin: 0; font-size: 16px; flex: 1; }
.modal-body { padding: 20px 22px; }
.modal-foot { display: flex; justify-content: flex-end; gap: 10px; padding: 14px 22px; border-top: 1px solid var(--border); background: var(--surface-2); border-radius: 0 0 16px 16px; }
.copy-box { display: flex; align-items: center; gap: 8px; padding: 8px 10px; border-radius: 10px; background: var(--bg-2); border: 1px solid var(--border); }
.copy-box code { flex: 1; word-break: break-all; font-size: 12.5px; }
.copy-list { display: flex; flex-direction: column; gap: 8px; }
.copy-list .row { display: grid; grid-template-columns: 110px 1fr; align-items: center; gap: 10px; }
.copy-list .row > span { color: var(--muted); font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: .5px; }
.callout { padding: 12px 14px; border-radius: 10px; font-size: 13px; background: rgba(245, 158, 11, .12); border: 1px solid rgba(245, 158, 11, .4); color: var(--text); }
.callout.info { background: rgba(79, 140, 255, .1); border-color: rgba(79, 140, 255, .4); }
.radio-cards { display: grid; gap: 10px; margin-bottom: 14px; }
.radio-card { display: flex; gap: 12px; padding: 12px 14px; border-radius: 12px; border: 1px solid var(--border); background: var(--bg-2); cursor: pointer; }
.radio-card.active { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(79, 140, 255, .18); }
.radio-card b { display: block; }
.radio-card span { color: var(--muted); font-size: 12.5px; }
.result-list { margin: 8px 0 0; padding-left: 18px; color: var(--muted); font-size: 13px; }

#toasts { position: fixed; right: 18px; bottom: 18px; z-index: 200; display: flex; flex-direction: column; gap: 10px; }
.toast {
  min-width: 240px; max-width: 360px; padding: 12px 16px; border-radius: 12px; font-weight: 600;
  background: var(--surface); border: 1px solid var(--border); border-left: 4px solid var(--accent); box-shadow: var(--shadow);
  animation: pop .2s ease;
}
.toast.good { border-left-color: var(--good); }
.toast.bad { border-left-color: var(--bad); }

.spinner { width: 18px; height: 18px; border-radius: 50%; border: 2px solid var(--border); border-top-color: var(--accent); animation: spin .7s linear infinite; display: inline-block; }
.center-load { display: grid; place-items: center; padding: 60px; }

@keyframes spin { to { transform: rotate(360deg); } }
@keyframes fade { from { opacity: 0; } }
@keyframes pop { from { opacity: 0; transform: translateY(8px) scale(.98); } }

/* ---------- responsive ---------- */
@media (max-width: 1100px) {
  .cards.c4 { grid-template-columns: repeat(2, 1fr); }
  .cards.c3 { grid-template-columns: 1fr 1fr; }
  .stat-strip { grid-template-columns: repeat(2, 1fr); }
}
@media (max-width: 860px) {
  .shell { grid-template-columns: 1fr; }
  .sidebar {
    position: fixed; z-index: 60; left: 0; top: 0; width: var(--sidebar); transform: translateX(-100%);
    transition: transform .2s ease; box-shadow: var(--shadow);
  }
  .sidebar.open { transform: none; }
  .scrim { position: fixed; inset: 0; z-index: 50; background: rgba(3, 7, 18, .55); }
  .menu-btn { display: inline-flex; }
  .topbar, .content { padding-left: 16px; padding-right: 16px; }
  .cards.c2, .cards.c3 { grid-template-columns: 1fr; }
  .pill.hide-sm { display: none; }
}
@media (max-width: 520px) {
  .cards.c4 { grid-template-columns: 1fr; }
  .grid-2 { grid-template-columns: 1fr; }
  .stat-strip { grid-template-columns: 1fr 1fr; gap: 10px; }
  .copy-list .row { grid-template-columns: 1fr; gap: 4px; }
  .svc { grid-template-columns: 1fr; }
}
PANEL_CSS_EOF
cat > /usr/local/share/ssh-manager/app.js << 'PANEL_JS_EOF'
(() => {
'use strict';

const BASE = location.pathname.replace(/[^/]*$/, '');
const SVG_NS = 'http://www.w3.org/2000/svg';
const USERNAME_RE = /^[A-Za-z_][A-Za-z0-9_-]{2,31}$/;
let CSRF = '';
let ME = null;
let INFO = null;
const state = { timers: [], page: '' };

/* ------------------------------------------------------------------ helpers */

function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'value') el.value = v;
    else if (k === 'checked') el.checked = !!v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid === null || kid === undefined || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

function svgEl(tag, attrs, ...kids) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs || {})) el.setAttribute(k, v);
  for (const kid of kids) el.append(kid);
  return el;
}

const ICONS = {
  logo: '<path d="M5 8l5 4-5 4"/><path d="M13 17h6"/>',
  dashboard: '<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>',
  users: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
  backup: '<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.7 4 3 9 3s9-1.3 9-3V5"/><path d="M3 12c0 1.7 4 3 9 3s9-1.3 9-3"/>',
  settings: '<line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/><line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/><line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/><line x1="1" y1="14" x2="7" y2="14"/><line x1="9" y1="8" x2="15" y2="8"/><line x1="17" y1="16" x2="23" y2="16"/>',
  logout: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/>',
  plus: '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
  trash: '<polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/>',
  edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  info: '<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/>',
  refresh: '<polyline points="23 4 23 10 17 10"/><path d="M20.5 15a9 9 0 1 1-2.1-9.4L23 10"/>',
  reset: '<polyline points="1 4 1 10 7 10"/><path d="M3.5 15a9 9 0 1 0 2.1-9.4L1 10"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/>',
  upload: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/>',
  search: '<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  moon: '<path d="M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8Z"/>',
  cpu: '<rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 1v3M15 1v3M9 20v3M15 20v3M20 9h3M20 14h3M1 9h3M1 14h3"/>',
  server: '<rect x="2" y="3" width="20" height="8" rx="2"/><rect x="2" y="13" width="20" height="8" rx="2"/><line x1="6" y1="7" x2="6.01" y2="7"/><line x1="6" y1="17" x2="6.01" y2="17"/>',
  activity: '<polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>',
  arrowup: '<line x1="12" y1="19" x2="12" y2="5"/><polyline points="5 12 12 5 19 12"/>',
  arrowdown: '<line x1="12" y1="5" x2="12" y2="19"/><polyline points="19 12 12 19 5 12"/>',
  menu: '<line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/>',
  x: '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
  eye: '<path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8S1 12 1 12Z"/><circle cx="12" cy="12" r="3"/>',
  key: '<circle cx="7.5" cy="15.5" r="4.5"/><path d="M10.7 12.3 21 2"/><path d="M16 7l3 3"/>',
  pause: '<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>',
  play: '<polygon points="6 3 20 12 6 21 6 3"/>',
  users2: '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/>',
};

function icon(name) {
  return svgEl('svg', {
    viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '2',
    'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', 'data-icon': name,
  }, ...rawNodes(ICONS[name] || ''));
}

function rawNodes(markup) {
  const parts = [];
  const re = /<(\w+)([^>]*?)\/?>/g;
  let m;
  while ((m = re.exec(markup))) {
    const attrs = {};
    m[2].replace(/([\w-]+)="([^"]*)"/g, (_, k, v) => { attrs[k] = v; return ''; });
    parts.push(svgEl(m[1], attrs));
  }
  return parts;
}

function fmtBytes(n) {
  n = Number(n) || 0;
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  const d = i === 0 ? 0 : (n < 10 ? 2 : n < 100 ? 1 : 0);
  return n.toFixed(d) + ' ' + units[i];
}
const fmtRate = (n) => fmtBytes(n) + '/s';
function fmtUptime(sec) {
  sec = Math.max(0, Math.floor(sec || 0));
  const d = Math.floor(sec / 86400), hr = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${hr}h ${m}m` : hr ? `${hr}h ${m}m` : `${m}m`;
}
const pct = (a, b) => (b > 0 ? Math.min(100, (100 * a) / b) : 0);
const level = (p) => (p < 70 ? 'var(--accent)' : p < 90 ? 'var(--warn)' : 'var(--bad)');

function toast(message, kind) {
  const el = h('div', { class: 'toast ' + (kind || ''), text: message });
  document.getElementById('toasts').append(el);
  setTimeout(() => el.remove(), kind === 'bad' ? 6500 : 3200);
}

async function copyText(text, quiet) {
  try {
    await navigator.clipboard.writeText(text);
  } catch (e) {
    const ta = h('textarea', { value: text, style: 'position:fixed;opacity:0' });
    document.body.append(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e2) { /* ignore */ }
    ta.remove();
  }
  if (!quiet) toast('Copied to clipboard', 'good');
}

function genPassword(len) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const buf = new Uint32Array(len);
  crypto.getRandomValues(buf);
  return Array.from(buf, (x) => chars[x % chars.length]).join('');
}

async function api(path, opts) {
  opts = opts || {};
  const init = { method: opts.method || 'GET', credentials: 'same-origin', headers: {} };
  if (init.method === 'POST') {
    init.headers['Content-Type'] = 'application/json';
    init.headers['X-CSRF-Token'] = CSRF;
    init.body = JSON.stringify(opts.body || {});
  }
  let res;
  try {
    res = await fetch(BASE + 'api' + path, init);
  } catch (e) {
    throw new Error('Cannot reach the server');
  }
  if (opts.raw) return res;
  let data = {};
  try { data = await res.json(); } catch (e) { /* not json */ }
  if (res.status === 401 && path !== '/login') {
    showLogin('Your session has ended. Please sign in again.');
    throw new Error('Session ended');
  }
  if (!res.ok || data.ok === false) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

function stopTimers() {
  state.timers.forEach(clearInterval);
  state.timers = [];
}

/* ------------------------------------------------------------------ modal */

function openModal(title, body, buttons) {
  const overlay = h('div', { class: 'overlay' });
  const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  const foot = buttons && buttons.length ? h('div', { class: 'modal-foot' }, buttons.map((b) => b(close))) : null;
  const box = h('div', { class: 'modal', role: 'dialog', 'aria-modal': 'true' },
    h('div', { class: 'modal-head' }, h('h3', { text: title }),
      h('button', { class: 'btn btn-sm icon-btn', 'aria-label': 'Close', onclick: close }, icon('x'))),
    h('div', { class: 'modal-body' }, body), foot);
  overlay.addEventListener('mousedown', (e) => { if (e.target === overlay) close(); });
  document.addEventListener('keydown', onKey);
  overlay.append(box);
  document.body.append(overlay);
  const first = box.querySelector ? box.querySelector('input') : null;
  if (first && first.focus) first.focus();
  return { close, box };
}

const btn = (label, cls, onclick, ic) => (close) => {
  const b = h('button', { class: 'btn ' + (cls || ''), type: 'button' }, ic ? icon(ic) : null, label);
  b.addEventListener('click', () => onclick(close, b));
  return b;
};
const closeBtn = (label) => btn(label || 'Close', '', (close) => close());

function confirmBox(title, message, label, danger) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (v, close) => { if (!done) { done = true; resolve(v); } close(); };
    const m = openModal(title, h('p', { text: message, style: 'margin:0;line-height:1.6' }), [
      btn('Cancel', '', (close) => finish(false, close)),
      btn(label || 'Confirm', danger ? 'btn-danger' : 'btn-primary', (close) => finish(true, close)),
    ]);
    m.box.parentNode.addEventListener('mousedown', (e) => { if (e.target === m.box.parentNode && !done) { done = true; resolve(false); } });
  });
}

/* ------------------------------------------------------------------ small widgets */

function field(label, input, hint) {
  return h('div', { class: 'field' }, h('label', { text: label }), input, hint ? h('div', { class: 'hint', text: hint }) : null);
}

function copyRow(label, value, mono) {
  return h('div', { class: 'row' }, h('span', { text: label }),
    h('div', { class: 'copy-box' }, h('code', { class: mono === false ? '' : 'mono', text: value }),
      h('button', { class: 'btn btn-sm icon-btn', type: 'button', 'aria-label': 'Copy ' + label, onclick: () => copyText(value) }, icon('copy'))));
}

function gauge(label) {
  const C = 2 * Math.PI * 52;
  const value = svgEl('circle', { class: 'value', cx: 60, cy: 60, r: 52, fill: 'none', 'stroke-width': 10, 'stroke-linecap': 'round', 'stroke-dasharray': C, 'stroke-dashoffset': C });
  const track = svgEl('circle', { class: 'track', cx: 60, cy: 60, r: 52, fill: 'none', 'stroke-width': 10 });
  const num = h('div', { class: 'gauge-num' });
  const sub = h('div', { class: 'gauge-sub' });
  const root = h('div', { class: 'card gauge' },
    h('div', { class: 'gauge-ring' }, svgEl('svg', { viewBox: '0 0 120 120' }, track, value), num),
    h('div', { class: 'gauge-label', text: label }), sub);
  return {
    root,
    set(p, text) {
      p = Math.max(0, Math.min(100, p || 0));
      value.setAttribute('stroke-dashoffset', String(C * (1 - p / 100)));
      value.style.stroke = level(p);
      num.replaceChildren(String(Math.round(p)), h('small', { text: '%' }));
      sub.textContent = text || '';
    },
  };
}

function sparkline() {
  const W = 300, H = 64;
  const down = svgEl('path', { class: 'line', d: '' });
  down.style.stroke = 'var(--good)';
  const up = svgEl('path', { class: 'line', d: '' });
  up.style.stroke = '#38bdf8';
  const svg = svgEl('svg', { class: 'spark', viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: 'none' }, down, up);
  const path = (vals, max) => {
    if (vals.length < 2) return '';
    const step = W / (vals.length - 1);
    return vals.map((v, i) => `${i ? 'L' : 'M'}${(i * step).toFixed(1)},${(H - 4 - (v / max) * (H - 8)).toFixed(1)}`).join('');
  };
  return {
    svg,
    set(rx, tx) {
      const max = Math.max(1, ...rx, ...tx);
      down.setAttribute('d', path(rx, max));
      up.setAttribute('d', path(tx, max));
    },
  };
}

function kvList(keys) {
  const refs = {};
  const rows = keys.map(([key, label]) => {
    refs[key] = h('span', { text: '-' });
    return h('div', { class: 'kv-row' }, h('span', { text: label }), refs[key]);
  });
  return { root: h('div', { class: 'kv' }, rows), set(key, value) { refs[key].textContent = value; } };
}

function cardTitle(ic, text) {
  return h('div', { class: 'card-title' }, icon(ic), text);
}

/* ------------------------------------------------------------------ login + shell */

function showLogin(message) {
  stopTimers();
  const err = h('div', { class: 'form-error', text: message || '' });
  const user = h('input', { class: 'input', id: 'login-user', autocomplete: 'username', autocapitalize: 'none', spellcheck: 'false', required: true });
  const pass = h('input', { class: 'input', id: 'login-pass', type: 'password', autocomplete: 'current-password', required: true });
  const submit = h('button', { class: 'btn btn-primary btn-block', type: 'submit' }, 'Sign in');
  const form = h('form', { novalidate: true },
    field('Username', user), field('Password', pass), err, submit);
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.textContent = '';
    submit.disabled = true;
    try {
      const d = await api('/login', { method: 'POST', body: { username: user.value, password: pass.value } });
      CSRF = d.csrf;
      await boot();
    } catch (ex) {
      err.textContent = ex.message;
      submit.disabled = false;
      pass.value = '';
    }
  });
  document.getElementById('app').replaceChildren(
    h('div', { class: 'login-wrap' }, h('div', { class: 'login-card' },
      h('div', { class: 'brand' }, h('div', { class: 'logo' }, icon('logo')),
        h('div', null, h('h1', { text: 'SSH Manager' }), h('div', { class: 'brand-sub' }, 'by ', h('b', { text: 'Coldplay' })))),
      h('p', { class: 'lead', text: 'Sign in to manage your SSH tunnel users' }), form)));
  user.focus();
}

const PAGES = {
  dashboard: { title: 'Dashboard', icon: 'dashboard', render: pageDashboard },
  users: { title: 'Users', icon: 'users', render: pageUsers },
  backup: { title: 'Backup & Restore', icon: 'backup', render: pageBackup },
  settings: { title: 'Settings', icon: 'settings', render: pageSettings },
};

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  try { localStorage.setItem('sshm-theme', theme); } catch (e) { /* ignore */ }
}

function renderShell() {
  const nav = h('nav', { class: 'nav' }, Object.entries(PAGES).map(([key, p]) =>
    h('a', { href: '#/' + key, 'data-page': key }, icon(p.icon), p.title)));
  const sidebar = h('aside', { class: 'sidebar', id: 'sidebar' },
    h('div', { class: 'brand' }, h('div', { class: 'logo' }, icon('logo')),
      h('div', null, h('div', { class: 'brand-name', text: 'SSH Manager' }), h('div', { class: 'brand-sub' }, 'by ', h('b', { text: 'Coldplay' })))),
    nav,
    h('div', { class: 'sidebar-foot' }, 'Signed in as ', h('b', { text: ME.login }), h('br'), 'Version ' + ME.version));
  const title = h('h2', { id: 'page-title', text: 'Dashboard' });
  const themeBtn = h('button', { class: 'btn icon-btn', type: 'button', 'aria-label': 'Toggle theme' });
  const syncThemeIcon = () => themeBtn.replaceChildren(icon(document.documentElement.getAttribute('data-theme') === 'dark' ? 'sun' : 'moon'));
  themeBtn.addEventListener('click', () => {
    applyTheme(document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
    syncThemeIcon();
  });
  syncThemeIcon();
  const scrim = h('div', { class: 'scrim hidden', id: 'scrim' });
  const toggleMenu = (open) => {
    sidebar.classList.toggle('open', open);
    scrim.classList.toggle('hidden', !open);
  };
  scrim.addEventListener('click', () => toggleMenu(false));
  nav.addEventListener('click', () => toggleMenu(false));
  const logout = h('button', { class: 'btn', type: 'button' }, icon('logout'), 'Sign out');
  logout.addEventListener('click', async () => {
    try { await api('/logout', { method: 'POST' }); } catch (e) { /* ignore */ }
    showLogin('You have been signed out.');
  });
  document.getElementById('app').replaceChildren(h('div', { class: 'shell' },
    sidebar, scrim,
    h('div', { class: 'main' },
      h('header', { class: 'topbar' },
        h('button', { class: 'btn icon-btn menu-btn', type: 'button', 'aria-label': 'Menu', onclick: () => toggleMenu(true) }, icon('menu')),
        title, h('span', { class: 'pill hide-sm', id: 'uptime-pill' }), themeBtn, logout),
      h('main', { class: 'content', id: 'content' }))));
}

function route() {
  stopTimers();
  const key = (location.hash.replace(/^#\/?/, '') || 'dashboard');
  const page = PAGES[key] || PAGES.dashboard;
  const pageKey = PAGES[key] ? key : 'dashboard';
  state.page = pageKey;
  document.getElementById('page-title').textContent = page.title;
  document.querySelectorAll('.nav a').forEach((a) => a.classList.toggle('active', a.getAttribute('data-page') === pageKey));
  const content = document.getElementById('content');
  content.replaceChildren(h('div', { class: 'center-load' }, h('span', { class: 'spinner' })));
  Promise.resolve(page.render(content, pageKey)).catch((e) => {
    if (e.message !== 'Session ended') toast(e.message, 'bad');
  });
}

async function boot() {
  const d = await api('/me');
  CSRF = d.csrf;
  ME = d;
  INFO = null;
  renderShell();
  route();
}

/* ------------------------------------------------------------------ dashboard */

async function pageDashboard(root) {
  const g = { cpu: gauge('CPU'), mem: gauge('Memory'), swap: gauge('Swap'), disk: gauge('Disk') };
  const spark = sparkline();
  const netUp = h('div', { class: 'big up', text: '0 B/s' });
  const netDown = h('div', { class: 'big down', text: '0 B/s' });
  const netTotals = h('div', { class: 'hint', text: '' });
  const sys = kvList([['host', 'Hostname'], ['os', 'Operating system'], ['kernel', 'Kernel'], ['cpu', 'Processor'],
    ['load', 'Load average'], ['uptime', 'Uptime'], ['ip', 'IP address'], ['conn', 'TCP / UDP sockets']]);
  const ssh = kvList([['users', 'Total users'], ['online', 'Online now'], ['conns', 'Active connections'], ['expired', 'Expired accounts'], ['paused', 'Paused users'], ['overq', 'Over data limit'],
    ['up', 'Uploaded (all users)'], ['down', 'Downloaded (all users)']]);
  const services = h('div', { class: 'svc' });

  root.replaceChildren(
    h('div', { class: 'cards c4' }, g.cpu.root, g.mem.root, g.swap.root, g.disk.root),
    h('div', { class: 'cards c2 section-gap' },
      h('div', { class: 'card' }, cardTitle('activity', 'Network'),
        h('div', { class: 'net-rows' },
          h('div', null, h('div', { class: 'lbl' }, icon('arrowup'), 'Upload'), netUp),
          h('div', null, h('div', { class: 'lbl' }, icon('arrowdown'), 'Download'), netDown)),
        spark.svg, netTotals),
      h('div', { class: 'card' }, cardTitle('server', 'System'), sys.root)),
    h('div', { class: 'cards c2 section-gap' },
      h('div', { class: 'card' }, cardTitle('users', 'SSH users'), ssh.root),
      h('div', { class: 'card' }, cardTitle('cpu', 'Services'), services)));

  const tick = async () => {
    const [s, u] = await Promise.all([api('/status'), api('/users')]);
    g.cpu.set(s.cpu, `${s.cores} core${s.cores > 1 ? 's' : ''} · load ${s.load[0]}`);
    g.mem.set(pct(s.mem.used, s.mem.total), `${fmtBytes(s.mem.used)} / ${fmtBytes(s.mem.total)}`);
    g.swap.set(pct(s.mem.swap_used, s.mem.swap_total), s.mem.swap_total ? `${fmtBytes(s.mem.swap_used)} / ${fmtBytes(s.mem.swap_total)}` : 'No swap configured');
    g.disk.set(pct(s.disk.used, s.disk.total), `${fmtBytes(s.disk.used)} / ${fmtBytes(s.disk.total)}`);
    netUp.textContent = fmtRate(s.net.tx_rate);
    netDown.textContent = fmtRate(s.net.rx_rate);
    netTotals.textContent = `Since boot: ${fmtBytes(s.net.tx_total)} sent · ${fmtBytes(s.net.rx_total)} received`;
    spark.set(s.history.map((p) => p.rx), s.history.map((p) => p.tx));
    sys.set('host', s.hostname); sys.set('os', s.os); sys.set('kernel', s.kernel); sys.set('cpu', s.cpu_model);
    sys.set('load', s.load.join(' / ')); sys.set('uptime', fmtUptime(s.uptime)); sys.set('ip', s.ip || '-');
    sys.set('conn', `${s.tcp} / ${s.udp}`);
    const pill = document.getElementById('uptime-pill');
    if (pill) pill.replaceChildren('Uptime ', h('b', { text: fmtUptime(s.uptime) }));
    const sm = u.summary;
    ssh.set('users', String(sm.total)); ssh.set('online', String(sm.online_users)); ssh.set('conns', String(sm.connections));
    ssh.set('expired', String(sm.expired)); ssh.set('paused', String(sm.paused || 0)); ssh.set('overq', String(sm.over_quota || 0)); ssh.set('up', fmtBytes(sm.up)); ssh.set('down', fmtBytes(sm.down));
    services.replaceChildren(...s.services.map((v) => h('div', null,
      h('span', { class: 'dot ' + (v.state === 'active' ? 'good' : (v.state === 'unknown' || v.state === 'off') ? '' : 'bad') }),
      h('span', { text: v.label }))));
  };
  await tick();
  state.timers.push(setInterval(() => tick().catch(() => {}), 3000));
}

/* ------------------------------------------------------------------ users */

async function getInfo() {
  if (!INFO) INFO = await api('/info');
  return INFO;
}

function connectionRows(info, user, password) {
  const host = info.host || '';
  return [
    ['Host', host], ['WS port', String(info.ws_port)], ['WSS (TLS) port', String(info.wss_port)],
    info.udpgw ? ['UDPGW', `127.0.0.1:${info.udpgw}`] : null,
    ['Username', user.username], ['Password', password],
    ['Expires', user.expires], ['Max connections', String(user.max_connections)],
    ['Speed limit', user.speed_mbps > 0 ? `${user.speed_mbps} Mbps` : 'Unlimited'],
    ['Data limit', user.quota_gb > 0 ? `${user.quota_gb} GB` : 'Unlimited'],
  ].filter(Boolean);
}

function showConnection(info, user, password, heading) {
  const rows = connectionRows(info, user, password || '(hidden - set a new one with Edit)');
  const payload = `GET / HTTP/1.1[crlf]Host: ${info.host}[crlf]Upgrade: websocket[crlf][crlf]`;
  const text = rows.map(([k, v]) => `${k}: ${v}`).join('\n') + `\nPayload: ${payload}`;
  openModal(heading, h('div', null,
    h('div', { class: 'copy-list' }, rows.map(([k, v]) => (k === 'Password' && !password ? h('div', { class: 'row' }, h('span', { text: k }), h('span', { class: 'muted', text: v })) : copyRow(k, v)))),
    h('div', { class: 'field section-gap' }, h('label', { text: 'Payload' }),
      h('div', { class: 'copy-box' }, h('code', { class: 'mono', text: payload }),
        h('button', { class: 'btn btn-sm icon-btn', type: 'button', 'aria-label': 'Copy payload', onclick: () => copyText(payload) }, icon('copy'))))),
  [btn('Copy all', '', () => copyText(text), 'copy'), closeBtn('Done')]);
}

async function pageUsers(root) {
  let users = [], summary = {};
  let filter = 'all', query = '', sort = 'name';

  const search = h('input', { class: 'input', placeholder: 'Search users...', 'aria-label': 'Search users' });
  const sortSel = h('select', { class: 'input', style: 'width:auto', 'aria-label': 'Sort' },
    h('option', { value: 'name', text: 'Sort: Name' }), h('option', { value: 'usage', text: 'Sort: Usage' }),
    h('option', { value: 'expiry', text: 'Sort: Expiry' }), h('option', { value: 'online', text: 'Sort: Online first' }));
  const FILTERS = [['all', 'All'], ['online', 'Online'], ['paused', 'Paused'], ['limit', 'Over limit'], ['expired', 'Expired']];
  const chips = FILTERS.map(([k, label]) => {
    const c = h('button', { class: 'chip' + (k === filter ? ' active' : ''), type: 'button', text: label });
    c.addEventListener('click', () => { filter = k; chips.forEach((x, i) => x.classList.toggle('active', FILTERS[i][0] === k)); render(); });
    return c;
  });
  const strip = h('div', { class: 'stat-strip' });
  const tbody = h('tbody');
  const trackNote = h('div', { class: 'callout hidden section-gap', text: 'Bandwidth tracking is not available on this server (the kernel connection counters could not be read). Users still work normally.' });

  const mini = (label, value) => h('div', { class: 'mini' }, h('div', { class: 'lbl', text: label }), h('div', { class: 'val', text: value }));

  function render() {
    strip.replaceChildren(mini('Total users', String(summary.total || 0)), mini('Online now', `${summary.online_users || 0} (${summary.connections || 0} conn)`),
      mini('Paused / over limit', `${summary.paused || 0} / ${summary.over_quota || 0}`),
      mini('Uploaded', fmtBytes(summary.up)), mini('Downloaded', fmtBytes(summary.down)));
    let rows = users.filter((u) => (filter === 'all' || (filter === 'online' && u.online > 0) || (filter === 'paused' && u.paused)
      || (filter === 'limit' && u.over_quota) || (filter === 'expired' && u.expired))
      && u.username.toLowerCase().includes(query.toLowerCase()));
    const by = {
      name: (a, b) => a.username.toLowerCase().localeCompare(b.username.toLowerCase()),
      usage: (a, b) => b.total - a.total,
      expiry: (a, b) => a.days_left - b.days_left,
      online: (a, b) => b.online - a.online || a.username.toLowerCase().localeCompare(b.username.toLowerCase()),
    };
    rows = rows.slice().sort(by[sort]);
    const maxTotal = Math.max(1, ...users.map((u) => u.total));
    if (!rows.length) {
      tbody.replaceChildren(h('tr', null, h('td', { colspan: '7' }, h('div', { class: 'empty' }, icon('users'), h('div', { text: users.length ? 'No users match your search.' : 'No users yet. Click "Add user" to create the first one.' })))));
      return;
    }
    tbody.replaceChildren(...rows.map((u) => userRow(u, maxTotal)));
  }

  function userRow(u, maxTotal) {
    const statusBadge = u.paused ? h('span', { class: 'badge warn' }, h('span', { class: 'dot warn' }), 'Paused')
      : u.over_quota ? h('span', { class: 'badge bad' }, 'Limit reached')
        : u.expired ? h('span', { class: 'badge bad' }, 'Expired')
          : u.online ? h('span', { class: 'badge good' }, h('span', { class: 'dot good' }), 'Online')
            : h('span', { class: 'badge off' }, 'Offline');
    const left = u.expired ? 'expired' : u.days_left === 0 ? 'today' : `${u.days_left} day${u.days_left === 1 ? '' : 's'}`;
    const leftBadge = h('span', { class: 'badge ' + (u.expired ? 'bad' : u.days_left <= 3 ? 'warn' : 'good'), text: left });
    let bar, total;
    if (u.quota_bytes > 0) {
      // with a data limit the bar shows how much of it is used
      const frac = Math.min(100, (100 * u.total) / u.quota_bytes);
      bar = h('div', { class: 'bar' }, h('i', { class: 'q' }));
      bar.children[0].style.width = frac.toFixed(1) + '%';
      bar.children[0].style.background = level(frac);
      total = h('span', { class: 'muted', text: `${fmtBytes(u.total)} / ${fmtBytes(u.quota_bytes)}` });
    } else {
      const upW = (100 * u.up) / maxTotal, downW = (100 * u.down) / maxTotal;
      bar = h('div', { class: 'bar' }, h('i', { class: 'u' }), h('i', { class: 'd' }));
      bar.children[0].style.width = upW.toFixed(1) + '%';
      bar.children[1].style.width = downW.toFixed(1) + '%';
      total = h('span', { class: 'muted', text: fmtBytes(u.total) });
    }
    return h('tr', null,
      h('td', null, h('div', { class: 'user-cell' }, h('div', { class: 'avatar' + (u.expired || u.paused ? ' expired' : ''), text: u.username[0].toUpperCase() }),
        h('div', null, h('div', { text: u.username }), u.has_account ? null : h('div', { class: 'hint', text: 'system account missing' })))),
      h('td', null, statusBadge),
      h('td', { text: `${u.online} / ${u.max_connections}` }),
      h('td', null, h('div', { class: 'usage' },
        h('div', { class: 'usage-nums' }, h('span', { class: 'up' }, '↑ ' + fmtBytes(u.up)), h('span', { class: 'down' }, '↓ ' + fmtBytes(u.down)), total), bar)),
      h('td', { text: u.speed_mbps > 0 ? `${u.speed_mbps} Mbps` : 'Unlimited' }),
      h('td', null, h('div', null, u.expires), leftBadge),
      h('td', null, h('div', { class: 'actions' },
        iconAction('info', 'Connection details', () => showInfo(u)),
        iconAction('edit', 'Edit user', () => editUser(u)),
        iconAction(u.paused ? 'play' : 'pause', u.paused ? 'Resume user' : 'Pause user', () => togglePause(u)),
        iconAction('reset', 'Reset usage', () => resetUsage(u)),
        iconAction('trash', 'Delete user', () => deleteUser(u), true))));
  }

  const iconAction = (ic, label, fn, danger) => h('button', { class: 'btn btn-sm icon-btn' + (danger ? ' btn-danger' : ''), type: 'button', title: label, 'aria-label': label, onclick: fn }, icon(ic));

  async function load() {
    const d = await api('/users');
    users = d.users; summary = d.summary;
    trackNote.classList.toggle('hidden', d.tracking !== false);
    render();
  }

  async function showInfo(u) {
    showConnection(await getInfo(), u, null, `Connection details - ${u.username}`);
  }

  function quotaField(input, usedText) {
    const quick = [50, 100, 200, 500].map((g) => h('button', { class: 'btn btn-sm', type: 'button', onclick: () => { input.value = String(g); } }, `${g} GB`));
    quick.push(h('button', { class: 'btn btn-sm', type: 'button', onclick: () => { input.value = '0'; } }, 'Unlimited'));
    return field('Data limit (GB)', h('div', null, input, h('div', { class: 'quick' }, quick)),
      '0 = unlimited. The user is blocked when upload + download reaches this amount.' + (usedText ? ` Used so far: ${usedText}.` : ''));
  }

  function addUser() {
    const err = h('div', { class: 'form-error' });
    const name = h('input', { class: 'input', autocomplete: 'off', autocapitalize: 'none', spellcheck: 'false', placeholder: 'e.g. Alice01' });
    const pass = h('input', { class: 'input mono', type: 'text', autocomplete: 'off', value: genPassword(12) });
    const days = h('input', { class: 'input', type: 'number', min: '1', max: '3650', value: '30' });
    const max = h('input', { class: 'input', type: 'number', min: '1', max: '1000', value: '1' });
    const speed = h('input', { class: 'input', type: 'number', min: '0', max: '100000', value: '0' });
    const quota = h('input', { class: 'input', type: 'number', min: '0', step: 'any', value: '0' });
    const body = h('div', null,
      field('Username', name, '3-32 characters: letters (any case), digits, _ or -'),
      field('Password', h('div', { class: 'input-row' }, pass,
        h('button', { class: 'btn', type: 'button', onclick: () => { pass.value = genPassword(12); } }, icon('key'), 'Generate'))),
      h('div', { class: 'grid-2' }, field('Valid for (days)', days), field('Max connections', max)),
      field('Speed limit (Mbps)', speed, '0 = unlimited'), quotaField(quota), err);
    openModal('Add user', body, [closeBtn('Cancel'), btn('Create user', 'btn-primary', async (close, b) => {
      err.textContent = '';
      if (!USERNAME_RE.test(name.value.trim())) { err.textContent = 'Invalid username.'; return; }
      if (!pass.value) { err.textContent = 'Enter a password.'; return; }
      b.disabled = true;
      try {
        const d = await api('/users', { method: 'POST', body: {
          username: name.value.trim(), password: pass.value, days: Number(days.value),
          max_connections: Number(max.value), speed_mbps: Number(speed.value), quota_gb: Number(quota.value) } });
        close();
        toast(`User ${d.user.username} created`, 'good');
        await load();
        showConnection(d.connection, d.user, d.connection.password, 'User created');
      } catch (e) { err.textContent = e.message; b.disabled = false; }
    }, 'plus')]);
  }

  function editUser(u) {
    const err = h('div', { class: 'form-error' });
    const exp = h('input', { class: 'input', type: 'date', value: u.expires });
    const max = h('input', { class: 'input', type: 'number', min: '1', max: '1000', value: String(u.max_connections) });
    const speed = h('input', { class: 'input', type: 'number', min: '0', max: '100000', value: String(u.speed_mbps) });
    const quota = h('input', { class: 'input', type: 'number', min: '0', step: 'any', value: String(u.quota_gb || 0) });
    const pass = h('input', { class: 'input mono', type: 'text', autocomplete: 'off', placeholder: 'Leave empty to keep the current password' });
    const addDays = (n) => {
      const base = new Date(Math.max(Date.now(), Date.parse(exp.value || u.expires) || Date.now()));
      base.setDate(base.getDate() + n);
      exp.value = base.toISOString().slice(0, 10);
    };
    const body = h('div', null,
      field('Expiry date', h('div', { class: 'input-row' }, exp,
        h('button', { class: 'btn', type: 'button', onclick: () => addDays(30) }, '+30 d'),
        h('button', { class: 'btn', type: 'button', onclick: () => addDays(90) }, '+90 d'))),
      h('div', { class: 'grid-2' }, field('Max connections', max), field('Speed limit (Mbps)', speed, '0 = unlimited')),
      quotaField(quota, fmtBytes(u.total)),
      field('New password', h('div', { class: 'input-row' }, pass,
        h('button', { class: 'btn', type: 'button', onclick: () => { pass.value = genPassword(12); } }, icon('key'), 'Generate'))), err);
    openModal(`Edit ${u.username}`, body, [closeBtn('Cancel'), btn('Save changes', 'btn-primary', async (close, b) => {
      err.textContent = '';
      b.disabled = true;
      try {
        const payload = { expires: exp.value, max_connections: Number(max.value), speed_mbps: Number(speed.value), quota_gb: Number(quota.value) };
        if (pass.value) payload.password = pass.value;
        await api(`/users/${encodeURIComponent(u.username)}/update`, { method: 'POST', body: payload });
        close();
        toast(`${u.username} updated` + (pass.value ? ` - new password: ${pass.value}` : ''), 'good');
        await load();
      } catch (e) { err.textContent = e.message; b.disabled = false; }
    })]);
  }

  async function resetUsage(u) {
    if (!(await confirmBox('Reset usage', `Set the traffic counters of ${u.username} back to zero?`, 'Reset', false))) return;
    await api(`/users/${encodeURIComponent(u.username)}/reset-usage`, { method: 'POST' });
    toast('Usage reset', 'good');
    await load();
  }

  async function deleteUser(u) {
    if (!(await confirmBox('Delete user', `Delete ${u.username}? Their connections are dropped and the account is removed.`, 'Delete', true))) return;
    await api(`/users/${encodeURIComponent(u.username)}/delete`, { method: 'POST' });
    toast(`${u.username} deleted`, 'good');
    await load();
  }

  async function togglePause(u) {
    if (!u.paused && !(await confirmBox('Pause user', `Pause ${u.username}? Their connections are dropped and they cannot connect until you resume the account.`, 'Pause', false))) return;
    await api(`/users/${encodeURIComponent(u.username)}/${u.paused ? 'resume' : 'pause'}`, { method: 'POST' });
    if (u.paused && u.over_quota) toast(`${u.username} resumed, but is still over the data limit: reset the usage or raise the limit`, 'bad');
    else toast(u.paused ? `${u.username} resumed` : `${u.username} paused`, 'good');
    await load();
  }

  search.addEventListener('input', () => { query = search.value; render(); });
  sortSel.addEventListener('change', () => { sort = sortSel.value; render(); });

  root.replaceChildren(strip,
    h('div', { class: 'toolbar' },
      h('div', { class: 'search' }, icon('search'), search), h('div', { class: 'chips' }, chips), sortSel, h('div', { class: 'grow' }),
      h('button', { class: 'btn', type: 'button', onclick: () => load().then(() => toast('Refreshed')).catch((e) => toast(e.message, 'bad')) }, icon('refresh'), 'Refresh'),
      h('button', { class: 'btn btn-primary', type: 'button', onclick: addUser }, icon('plus'), 'Add user')),
    h('div', { class: 'table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['User', 'Status', 'Connections', 'Bandwidth usage', 'Speed', 'Expires', ''].map((t) => h('th', { text: t })))), tbody)),
    trackNote);
  await load();
  state.timers.push(setInterval(() => load().catch(() => {}), 5000));
}

/* ------------------------------------------------------------------ backup */

async function pageBackup(root) {
  let parsed = null;
  let mode = 'merge';
  const fileInput = h('input', { type: 'file', accept: 'application/json,.json', class: 'input' });
  const fileInfo = h('div', { class: 'hint', text: 'No file selected.' });
  const restoreBtn = h('button', { class: 'btn btn-primary', type: 'button', disabled: true }, icon('upload'), 'Restore users');

  const cards = ['merge', 'replace'].map((k) => {
    const c = h('div', { class: 'radio-card' + (k === mode ? ' active' : ''), role: 'radio' },
      h('div', null, h('b', { text: k === 'merge' ? 'Merge (recommended)' : 'Replace everything' }),
        h('span', { text: k === 'merge' ? 'Add users from the file and update the ones that already exist. Other users stay.' : 'Make this server match the file exactly. Users that are not in the file are deleted.' })));
    c.addEventListener('click', () => { mode = k; cards.forEach((x, i) => x.classList.toggle('active', ['merge', 'replace'][i] === k)); });
    return c;
  });

  const download = async (b) => {
    b.disabled = true;
    try {
      const res = await api('/backup', { raw: true });
      if (!res.ok) throw new Error('Could not create the backup');
      const blob = await res.blob();
      const m = (res.headers.get('Content-Disposition') || '').match(/filename="([^"]+)"/);
      const a = h('a', { href: URL.createObjectURL(blob), download: m ? m[1] : 'ssh-manager-backup.json' });
      document.body.append(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 4000);
      toast('Backup downloaded', 'good');
    } catch (e) { toast(e.message, 'bad'); }
    b.disabled = false;
  };

  fileInput.addEventListener('change', async () => {
    parsed = null;
    restoreBtn.disabled = true;
    const f = fileInput.files && fileInput.files[0];
    if (!f) { fileInfo.textContent = 'No file selected.'; return; }
    try {
      const data = JSON.parse(await f.text());
      if (data.app !== 'ssh-manager' || !Array.isArray(data.users)) throw new Error('This is not an SSH Manager backup file');
      parsed = data;
      fileInfo.textContent = `${f.name} - ${data.users.length} user${data.users.length === 1 ? '' : 's'} - created ${data.created || 'unknown'}`;
      restoreBtn.disabled = false;
    } catch (e) {
      fileInfo.textContent = '';
      toast(e instanceof SyntaxError ? 'That file is not valid JSON' : e.message, 'bad');
    }
  });

  restoreBtn.addEventListener('click', async () => {
    if (!parsed) return;
    const msg = mode === 'replace'
      ? `This makes the server match the backup: users that are not in the file will be DELETED. Continue with ${parsed.users.length} users?`
      : `Add or update ${parsed.users.length} users from the backup?`;
    if (!(await confirmBox('Restore backup', msg, 'Restore', mode === 'replace'))) return;
    restoreBtn.disabled = true;
    try {
      const r = await api('/restore', { method: 'POST', body: { mode, data: parsed } });
      const list = (title, items) => (items.length ? h('div', { class: 'section-gap' }, h('b', { text: `${title} (${items.length})` }),
        h('ul', { class: 'result-list' }, items.slice(0, 15).map((x) => h('li', { text: x })), items.length > 15 ? h('li', { text: `... and ${items.length - 15} more` }) : null)) : null);
      openModal('Restore finished', h('div', null,
        h('div', { class: 'stat-strip', style: 'grid-template-columns:repeat(2,1fr)' },
          h('div', { class: 'mini' }, h('div', { class: 'lbl', text: 'Created' }), h('div', { class: 'val', text: String(r.created.length) })),
          h('div', { class: 'mini' }, h('div', { class: 'lbl', text: 'Updated' }), h('div', { class: 'val', text: String(r.updated.length) }))),
        list('Deleted', r.deleted), list('Skipped', r.skipped),
        r.no_password.length ? h('div', { class: 'callout section-gap', text: `${r.no_password.length} user(s) had no password hash in the file and cannot log in until you set a new password with Edit.` }) : null),
      [closeBtn('Done')]);
      INFO = null;
    } catch (e) { toast(e.message, 'bad'); }
    restoreBtn.disabled = !parsed;
  });

  const dl = h('button', { class: 'btn btn-primary', type: 'button' }, icon('download'), 'Download backup');
  dl.addEventListener('click', () => download(dl));

  root.replaceChildren(h('div', { class: 'cards c2' },
    h('div', { class: 'card' }, cardTitle('download', 'Download database'),
      h('p', { class: 'muted', style: 'margin-top:0', text: 'Saves every user with their password, expiry, connection limit, speed limit and bandwidth usage in one file. Use it to move to a new server or as a safety copy.' }),
      h('div', { class: 'callout' }, 'The file contains password hashes. Keep it private.'),
      h('div', { class: 'section-gap' }, dl)),
    h('div', { class: 'card' }, cardTitle('upload', 'Restore database'),
      field('Backup file', fileInput), fileInfo,
      h('div', { class: 'section-gap radio-cards' }, cards),
      restoreBtn)));
}

/* ------------------------------------------------------------------ settings */

async function pageSettings(root) {
  const info = await getInfo();
  const err = h('div', { class: 'form-error' });
  const cur = h('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
  const login = h('input', { class: 'input', autocomplete: 'username', value: ME.login });
  const np = h('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
  const np2 = h('input', { class: 'input', type: 'password', autocomplete: 'new-password' });
  const save = h('button', { class: 'btn btn-primary', type: 'button' }, icon('key'), 'Update login');
  save.addEventListener('click', async () => {
    err.textContent = '';
    if (np.value && np.value !== np2.value) { err.textContent = 'The new passwords do not match.'; return; }
    save.disabled = true;
    try {
      await api('/password', { method: 'POST', body: { current_password: cur.value, username: login.value, new_password: np.value } });
      toast('Login updated. Please sign in again.', 'good');
      showLogin('Login updated. Please sign in again.');
    } catch (e) { err.textContent = e.message; save.disabled = false; }
  });
  const rows = kvList([['version', 'Panel version'], ['port', 'Panel port'], ['host', 'Server host'], ['ws', 'WebSocket port'],
    ['wss', 'WebSocket TLS port'], ['udp', 'UDP gateway'], ['track', 'Bandwidth tracking']]);
  rows.set('version', info.version); rows.set('port', String(info.panel_port)); rows.set('host', info.host || '-');
  rows.set('ws', String(info.ws_port)); rows.set('wss', String(info.wss_port)); rows.set('udp', info.udpgw ? `127.0.0.1:${info.udpgw}` : 'not installed');
  rows.set('track', info.tracking === false ? 'unavailable' : 'active');
  root.replaceChildren(h('div', { class: 'cards c2' },
    h('div', { class: 'card' }, cardTitle('key', 'Panel login'),
      field('Current password', cur), field('Login name', login),
      h('div', { class: 'grid-2' }, field('New password', np, 'At least 8 characters. Leave empty to keep it.'), field('Repeat new password', np2)),
      err, save),
    h('div', { class: 'card' }, cardTitle('server', 'About'), rows.root)));
}

/* ------------------------------------------------------------------ start */

(async function start() {
  let theme = 'dark';
  try { theme = localStorage.getItem('sshm-theme') || (matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'); } catch (e) { /* ignore */ }
  applyTheme(theme);
  window.addEventListener('hashchange', () => { if (ME && document.getElementById('content')) route(); });
  try {
    await boot();
  } catch (e) {
    if (e.message !== 'Session ended') showLogin('');
  }
})();
})();
PANEL_JS_EOF
    chmod 644 /usr/local/share/ssh-manager/*

    # login: created on the first install only, kept on every re-run
    PANEL_INFO=$(SSH_PORT=$SSH_PORT python3 /usr/local/bin/ssh-manager-panel.py init)
    PANEL_PORT=$(echo "$PANEL_INFO" | awk -F= '$1=="port"{print $2}')
    PANEL_PATH=$(echo "$PANEL_INFO" | awk -F= '$1=="path"{print $2}')
    PANEL_USER=$(echo "$PANEL_INFO" | awk -F= '$1=="username"{print $2}')
    PANEL_PASS=$(echo "$PANEL_INFO" | awk -F= '$1=="password"{print $2}')

    cat > /etc/systemd/system/ws-panel.service << EOF
[Unit]
Description=SSH Manager by Coldplay (web panel)
After=network.target ssh.service

[Service]
Type=simple
User=root
Environment=SSH_PORT=${SSH_PORT}
ExecStart=/usr/bin/python3 /usr/local/bin/ssh-manager-panel.py serve
Restart=always
RestartSec=3
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ws-panel >/dev/null 2>&1
    systemctl restart ws-panel
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1
    fi
    sleep 1
    systemctl is-active --quiet ws-panel && PANEL_OK=1
else
    PANEL_OK=skipped
    echo -e "${YELLOW}Python 3.7 or newer is needed for the web panel, so it was skipped.${NC}"
fi

# ---------- menu ----------
echo -e "${YELLOW}[10/10] Installing menu...${NC}"
cat > /usr/local/bin/wsmenu << 'MENU_EOF'
#!/bin/bash
# SSH over WebSocket user manager - Script by Coldplay

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
CYAN='\033[1;36m'; WHITE='\033[1;37m'; NC='\033[0m'

DB=/etc/sshws/users.db
LIMITS=/etc/security/limits.d/sshws.conf
BANNER=/etc/sshws/banner
WS_PORT=$(cat /etc/sshws/ws_port 2>/dev/null || echo 80)
WSS_PORT=$(cat /etc/sshws/wss_port 2>/dev/null || echo 443)
DOMAIN=$(cat /etc/sshws/domain 2>/dev/null)
UDPGW=$(cat /etc/sshws/udpgw_port 2>/dev/null)

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Run as root.${NC}"
    exit 1
fi
touch "$DB" "$LIMITS"

pause() { echo; read -r -p " Press Enter to continue..."; }

# usernames: 3-32 chars, letters (any case), digits, _ and -, must start with a letter or _
valid_username() {
    local LC_ALL=C
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_-]{2,31}$ ]]
}

reload_ssh() {
    sshd -t 2>/dev/null && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; }
}

count_online() { ps -u "$1" -o args= 2>/dev/null | grep -c '^sshd:'; }

apply_limits() {
    local out rc
    out=$(/usr/local/bin/ws-limit apply 2>&1)
    rc=$?
    if (( rc != 0 )); then
        echo -e " ${YELLOW}Speed limits are saved, but could not be fully enforced here:${NC}"
        echo -e " ${RED}${out}${NC}"
    fi
    return $rc
}

set_limit() {
    sed -i "/^$1[[:space:]]/d" "$LIMITS"
    echo "$1 hard maxlogins $2" >> "$LIMITS"
}

db_set() {   # db_set <user> <field-number> <value>
    awk -F'|' -v u="$1" -v f="$2" -v v="$3" 'BEGIN{OFS="|"} $1==u{$f=v} {print}' "$DB" > "$DB.tmp" && mv "$DB.tmp" "$DB"
}

choose_user() {
    mapfile -t U < <(cut -d'|' -f1 "$DB" | grep .)
    if [[ ${#U[@]} -eq 0 ]]; then
        echo -e " ${RED}No users yet.${NC}"
        return 1
    fi
    local i=1 x
    for x in "${U[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $x"
        i=$((i + 1))
    done
    echo
    read -r -p " Select user number: " n
    if [[ ! $n =~ ^[0-9]+$ || $n -lt 1 || $n -gt ${#U[@]} ]]; then
        echo -e " ${RED}Invalid choice.${NC}"
        return 1
    fi
    SEL=${U[$((n - 1))]}
}

header() {
    clear
    local total=0 users u
    while IFS='|' read -r u _ _; do
        [[ -z $u ]] && continue
        total=$((total + $(count_online "$u")))
    done < "$DB"
    users=$(grep -c . "$DB")
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}        SSH over WebSocket - User Manager   ${CYAN}║${NC}"
    echo -e "${CYAN}║${RED}             Script by Coldplay             ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════╣${NC}"
    printf "${CYAN}║${NC} WS: ${GREEN}%-5s${NC} WSS: ${GREEN}%-5s${NC} Users: ${GREEN}%-3s${NC} Online: ${GREEN}%-3s${CYAN}║${NC}\n" "$WS_PORT" "$WSS_PORT" "$users" "$total"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo
}

add_user() {
    header
    echo -e " ${YELLOW}--- Add user ---${NC}"
    echo
    read -r -p " Username          : " u
    if ! valid_username "$u"; then
        echo -e " ${RED}Invalid username (3-32 chars: letters A-Z a-z, 0-9, _ -).${NC}"; pause; return
    fi
    if id "$u" &>/dev/null; then
        echo -e " ${RED}User already exists.${NC}"; pause; return
    fi
    IFS= read -r -s -p " Password          : " p; echo
    if [[ -z $p ]]; then
        echo -e " ${RED}Password cannot be empty.${NC}"; pause; return
    fi
    read -r -p " Days (expiry)    : " d
    if [[ ! $d =~ ^[0-9]+$ || $d -lt 1 ]]; then
        echo -e " ${RED}Days must be a number above 0.${NC}"; pause; return
    fi
    read -r -p " Max users        : " m
    if [[ ! $m =~ ^[0-9]+$ || $m -lt 1 ]]; then
        echo -e " ${RED}Max users must be a number above 0.${NC}"; pause; return
    fi
    read -r -p " Speed Mbps (0=off) : " s
    s=${s:-0}
    if [[ ! $s =~ ^[0-9]+$ ]]; then
        echo -e " ${RED}Speed must be a whole number (0 = unlimited).${NC}"; pause; return
    fi
    s=$((10#$s))

    local exp ip
    exp=$(date -d "+$d days" +%Y-%m-%d)
    if ! useradd -M -s /bin/false -e "$exp" "$u" 2>/dev/null \
       && ! useradd --badname -M -s /bin/false -e "$exp" "$u"; then
        echo -e " ${RED}Could not create user.${NC}"; pause; return
    fi
    printf '%s:%s\n' "$u" "$p" | chpasswd
    set_limit "$u" "$m"
    sed -i "/^$u|/d" "$DB"
    echo "$u|$exp|$m|$s" >> "$DB"
    (( s > 0 )) && apply_limits

    ip=$(curl -s -m 3 ifconfig.me 2>/dev/null)
    [[ -z $ip ]] && ip=$(hostname -I | awk '{print $1}')
    echo
    echo -e " ${GREEN}User created successfully${NC}"
    echo -e " ${CYAN}------------------------------${NC}"
    echo -e " Host      : ${WHITE}${DOMAIN:-$ip}${NC}"
    [[ -n $DOMAIN ]] && echo -e " Server IP : ${WHITE}$ip${NC}"
    echo -e " WS port   : ${WHITE}$WS_PORT${NC}"
    echo -e " WSS port  : ${WHITE}$WSS_PORT${NC}"
    [[ -n $UDPGW ]] && echo -e " UDPGW     : ${WHITE}127.0.0.1:$UDPGW${NC}"
    echo -e " Username  : ${WHITE}$u${NC}"
    printf ' Password  : %b%s%b\n' "$WHITE" "$p" "$NC"
    echo -e " Expires   : ${WHITE}$exp${NC}"
    echo -e " Max users : ${WHITE}$m${NC}"
    if (( s > 0 )); then
        echo -e " Speed     : ${WHITE}$s Mbps${NC}"
    else
        echo -e " Speed     : ${WHITE}unlimited${NC}"
    fi
    echo -e " ${CYAN}------------------------------${NC}"
    echo -e " Payload   :"
    echo -e " ${WHITE}GET / HTTP/1.1[crlf]Host: ${DOMAIN:-$ip}[crlf]Upgrade: websocket[crlf][crlf]${NC}"
    pause
}

delete_user() {
    header
    echo -e " ${YELLOW}--- Delete user ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " Delete '$SEL'? [y/N]: " c
    if [[ $c =~ ^[Yy]$ ]]; then
        local old_s
        old_s=$(awk -F'|' -v u="$SEL" '$1==u{print $4}' "$DB")
        pkill -KILL -u "$SEL" 2>/dev/null
        userdel "$SEL" 2>/dev/null
        sed -i "/^$SEL[[:space:]]/d" "$LIMITS"
        sed -i "/^$SEL|/d" "$DB"
        [[ $old_s =~ ^[0-9]+$ ]] && (( 10#$old_s > 0 )) && apply_limits
        echo -e " ${GREEN}User '$SEL' deleted.${NC}"
    else
        echo -e " Cancelled."
    fi
    pause
}

list_users() {
    header
    echo -e " ${YELLOW}--- All users ---${NC}"
    echo
    printf " ${WHITE}%-16s %-12s %-10s %-5s %-10s${NC}\n" "USERNAME" "EXPIRES" "DAYS LEFT" "MAX" "SPEED"
    echo -e " ${CYAN}----------------------------------------------------------${NC}"
    local u exp m s sp left col
    while IFS='|' read -r u exp m s; do
        [[ -z $u ]] && continue
        left=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 ))
        col=$GREEN
        (( left <= 3 )) && col=$YELLOW
        (( left < 0 )) && { col=$RED; left="expired"; }
        sp="unlimited"
        [[ $s =~ ^[0-9]+$ ]] && (( 10#$s > 0 )) && sp="$((10#$s)) Mbps"
        printf " %-16s %-12s ${col}%-10s${NC} %-5s %-10s\n" "$u" "$exp" "$left" "$m" "$sp"
    done < "$DB"
    pause
}

online_users() {
    header
    echo -e " ${YELLOW}--- Online users ---${NC}"
    echo
    printf " ${WHITE}%-16s %-12s %-8s${NC}\n" "USERNAME" "CONNECTIONS" "LIMIT"
    echo -e " ${CYAN}-------------------------------------${NC}"
    local u m c any=0
    while IFS='|' read -r u _ m _; do
        [[ -z $u ]] && continue
        c=$(count_online "$u")
        if (( c > 0 )); then
            printf " %-16s ${GREEN}%-12s${NC} %-8s\n" "$u" "$c" "$m"
            any=1
        fi
    done < "$DB"
    (( any == 0 )) && echo -e " ${YELLOW}Nobody is online right now.${NC}"
    pause
}

change_expiry() {
    header
    echo -e " ${YELLOW}--- Change expiry ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New expiry in days from today: " d
    if [[ ! $d =~ ^[0-9]+$ || $d -lt 1 ]]; then
        echo -e " ${RED}Days must be a number above 0.${NC}"; pause; return
    fi
    local exp
    exp=$(date -d "+$d days" +%Y-%m-%d)
    usermod -e "$exp" "$SEL"
    db_set "$SEL" 2 "$exp"
    echo -e " ${GREEN}'$SEL' now expires on $exp.${NC}"
    pause
}

change_limit() {
    header
    echo -e " ${YELLOW}--- Change connection limit ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New max users (connections) for '$SEL': " m
    if [[ ! $m =~ ^[0-9]+$ || $m -lt 1 ]]; then
        echo -e " ${RED}Must be a number above 0.${NC}"; pause; return
    fi
    set_limit "$SEL" "$m"
    db_set "$SEL" 3 "$m"
    echo -e " ${GREEN}'$SEL' can now have $m connection(s) (enforced within a few seconds).${NC}"
    pause
}

change_speed() {
    header
    echo -e " ${YELLOW}--- Change speed limit ---${NC}"
    echo
    choose_user || { pause; return; }
    read -r -p " New speed limit in Mbps for '$SEL' (0 = unlimited): " s
    if [[ ! $s =~ ^[0-9]+$ ]]; then
        echo -e " ${RED}Enter a whole number (0 = unlimited).${NC}"; pause; return
    fi
    s=$((10#$s))
    db_set "$SEL" 4 "$s"
    if apply_limits; then
        if (( s > 0 )); then
            echo -e " ${GREEN}'$SEL' is now limited to $s Mbps.${NC}"
        else
            echo -e " ${GREEN}'$SEL' is now unlimited.${NC}"
        fi
    fi
    pause
}

torrent_toggle() {
    header
    echo -e " ${YELLOW}--- Torrent blocking ---${NC}"
    echo
    local out
    if /usr/local/bin/torrent-block status >/dev/null 2>&1; then
        echo -e " Torrent blocking is ${GREEN}ON${NC}."
        read -r -p " Turn it off? [y/N]: " c
        if [[ $c =~ ^[Yy]$ ]]; then
            systemctl disable torrent-block >/dev/null 2>&1
            /usr/local/bin/torrent-block clear
            echo -e " ${YELLOW}Torrent blocking is now OFF.${NC}"
        fi
    else
        echo -e " Torrent blocking is ${RED}OFF${NC}."
        read -r -p " Turn it on? [y/N]: " c
        if [[ $c =~ ^[Yy]$ ]]; then
            systemctl enable torrent-block >/dev/null 2>&1
            if out=$(/usr/local/bin/torrent-block apply 2>&1); then
                echo -e " ${GREEN}Torrent blocking is now ON.${NC}"
            else
                echo -e " ${RED}${out}${NC}"
            fi
        fi
    fi
    pause
}

panel_menu() {
    header
    echo -e " ${YELLOW}--- Web panel (SSH Manager) ---${NC}"
    echo
    local info port path user host out o np
    info=$(python3 /usr/local/bin/ssh-manager-panel.py info 2>/dev/null)
    if [[ -z $info || $info == error=* ]]; then
        echo -e " ${RED}The web panel is not installed. Re-run the installer to add it.${NC}"
        pause; return
    fi
    port=$(echo "$info" | awk -F= '$1=="port"{print $2}')
    path=$(echo "$info" | awk -F= '$1=="path"{print $2}')
    user=$(echo "$info" | awk -F= '$1=="username"{print $2}')
    host=${DOMAIN:-$(curl -s -m 3 ifconfig.me 2>/dev/null)}
    [[ -z $host ]] && host=$(hostname -I | awk '{print $1}')
    if systemctl is-active --quiet ws-panel; then
        echo -e " Status   : ${GREEN}running${NC}"
    else
        echo -e " Status   : ${RED}stopped${NC}"
    fi
    echo -e " URL      : ${WHITE}https://${host}:${port}/${path}/${NC}"
    echo -e " Username : ${WHITE}${user}${NC}"
    echo -e " Password : ${WHITE}(hidden - option 1 creates a new one)${NC}"
    echo
    echo -e "  ${GREEN}1)${NC} Reset password (random)"
    echo -e "  ${GREEN}2)${NC} Change panel port"
    echo -e "  ${GREEN}3)${NC} Restart panel"
    echo -e "  ${RED}0)${NC} Back"
    echo
    read -r -p " Select: " o
    case $o in
        1)
            out=$(python3 /usr/local/bin/ssh-manager-panel.py reset)
            systemctl restart ws-panel
            echo
            echo -e " New password : ${WHITE}$(echo "$out" | awk -F= '$1=="password"{print $2}')${NC}"
            ;;
        2)
            read -r -p " New port (1024-65535): " np
            if [[ ! $np =~ ^[0-9]+$ ]]; then
                echo -e " ${RED}Enter a number.${NC}"
            else
                np=$((10#$np))
                if (( np < 1024 || np > 65535 )); then
                    echo -e " ${RED}The port must be between 1024 and 65535.${NC}"
                elif ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${np}$"; then
                    echo -e " ${RED}Port $np is already in use.${NC}"
                else
                    python3 /usr/local/bin/ssh-manager-panel.py set-port "$np" >/dev/null
                    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
                        ufw allow "${np}/tcp" >/dev/null 2>&1
                        ufw delete allow "${port}/tcp" >/dev/null 2>&1
                    fi
                    systemctl restart ws-panel
                    echo -e " ${GREEN}Done. New URL: https://${host}:${np}/${path}/${NC}"
                fi
            fi
            ;;
        3) systemctl restart ws-panel && echo -e " ${GREEN}Panel restarted.${NC}" ;;
    esac
    pause
}

set_banner() {
    header
    echo -e " ${YELLOW}--- Login banner ---${NC}"
    echo
    echo -e "  ${GREEN}1)${NC} Set / change banner"
    echo -e "  ${GREEN}2)${NC} Remove banner"
    echo
    read -r -p " Select: " b
    case $b in
        1)
            echo -e " Type the banner text. Use ${WHITE}\\\\n${NC} for a new line."
            read -r -p " > " text
            if [[ -z $text ]]; then
                echo -e " ${RED}Banner cannot be empty.${NC}"; pause; return
            fi
            printf '%b\n' "$text" > "$BANNER"
            sed -i '/^\s*#\?\s*Banner\s/d' /etc/ssh/sshd_config
            sed -i "1i Banner $BANNER" /etc/ssh/sshd_config
            reload_ssh
            echo -e " ${GREEN}Banner saved.${NC}"
            ;;
        2)
            rm -f "$BANNER"
            sed -i '/^\s*Banner\s/d' /etc/ssh/sshd_config
            reload_ssh
            echo -e " ${GREEN}Banner removed.${NC}"
            ;;
        *) echo -e " ${RED}Invalid choice.${NC}" ;;
    esac
    pause
}

remove_expired() {
    header
    echo -e " ${YELLOW}--- Remove expired users ---${NC}"
    echo
    local today u exp m s n=0 limited=0
    today=$(date +%Y-%m-%d)
    while IFS='|' read -r u exp m s; do
        [[ -z $u ]] && continue
        if [[ $exp < $today ]]; then
            pkill -KILL -u "$u" 2>/dev/null
            userdel "$u" 2>/dev/null
            sed -i "/^$u[[:space:]]/d" "$LIMITS"
            sed -i "/^$u|/d" "$DB"
            echo -e " Removed ${RED}$u${NC} (expired $exp)"
            [[ $s =~ ^[0-9]+$ ]] && (( 10#$s > 0 )) && limited=1
            n=$((n + 1))
        fi
    done < <(cat "$DB")
    echo
    (( limited )) && apply_limits
    echo -e " ${GREEN}$n expired user(s) removed.${NC}"
    pause
}

service_status() {
    header
    echo -e " ${YELLOW}--- Services ---${NC}"
    echo
    local s
    for s in ws-proxy ws-tls ssh udpgw ws-connlimit ws-panel; do
        if systemctl is-active --quiet "$s" 2>/dev/null || { [[ $s == ssh ]] && systemctl is-active --quiet sshd 2>/dev/null; }; then
            echo -e " $s : ${GREEN}running${NC}"
        else
            echo -e " $s : ${RED}stopped${NC}"
        fi
    done
    if /usr/local/bin/torrent-block status >/dev/null 2>&1; then
        echo -e " torrent block : ${GREEN}active${NC}"
    else
        echo -e " torrent block : ${YELLOW}off${NC}"
    fi
    local lim rules
    lim=$(awk -F'|' '$4+0>0{n++} END{print n+0}' "$DB")
    rules=$(iptables -t mangle -S WSLIMIT 2>/dev/null | grep -c 'MARK --set')
    if (( lim == 0 )); then
        echo -e " speed limits : ${YELLOW}none set${NC}"
    elif (( rules >= lim )); then
        echo -e " speed limits : ${GREEN}active for $lim user(s)${NC}"
    else
        echo -e " speed limits : ${RED}$lim user(s) set but NOT enforced${NC}"
    fi
    echo
    read -r -p " Restart ws-proxy, ws-tls and udpgw now? [y/N]: " c
    if [[ $c =~ ^[Yy]$ ]]; then
        systemctl restart ws-proxy && echo -e " ${GREEN}ws-proxy restarted.${NC}"
        systemctl restart ws-tls && echo -e " ${GREEN}ws-tls restarted.${NC}"
        systemctl restart udpgw 2>/dev/null && echo -e " ${GREEN}udpgw restarted.${NC}"
        systemctl restart ws-connlimit 2>/dev/null && echo -e " ${GREEN}ws-connlimit restarted.${NC}"
        systemctl restart ws-panel 2>/dev/null && echo -e " ${GREEN}ws-panel restarted.${NC}"
        apply_limits && echo -e " ${GREEN}speed limits re-applied.${NC}"
    fi
    pause
}

while true; do
    header
    echo -e "  ${GREEN}1)${NC} Add user"
    echo -e "  ${GREEN}2)${NC} Delete user"
    echo -e "  ${GREEN}3)${NC} List users"
    echo -e "  ${GREEN}4)${NC} Online users"
    echo -e "  ${GREEN}5)${NC} Change expiry"
    echo -e "  ${GREEN}6)${NC} Change connection limit"
    echo -e "  ${GREEN}7)${NC} Login banner"
    echo -e "  ${GREEN}8)${NC} Remove expired users"
    echo -e "  ${GREEN}9)${NC} Service status / restart"
    echo -e " ${GREEN}10)${NC} Change speed limit"
    echo -e " ${GREEN}11)${NC} Torrent blocking on/off"
    echo -e " ${GREEN}12)${NC} Web panel (URL / password)"
    echo -e "  ${RED}0)${NC} Exit"
    echo
    read -r -p " Select option: " opt
    case $opt in
        1) add_user ;;
        2) delete_user ;;
        3) list_users ;;
        4) online_users ;;
        5) change_expiry ;;
        6) change_limit ;;
        7) set_banner ;;
        8) remove_expired ;;
        9) service_status ;;
        10) change_speed ;;
        11) torrent_toggle ;;
        12) panel_menu ;;
        0) clear; exit 0 ;;
        *) echo -e " ${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
MENU_EOF
chmod +x /usr/local/bin/wsmenu

# "menu" shortcut, unless another script already owns that name
MENU_CMD=wsmenu
if [[ ! -e /usr/local/bin/menu ]]; then
    ln -s /usr/local/bin/wsmenu /usr/local/bin/menu
    MENU_CMD=menu
elif [[ $(readlink /usr/local/bin/menu) == /usr/local/bin/wsmenu ]]; then
    MENU_CMD=menu
fi

# ---------- done ----------
sleep 1
echo
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}  Installation complete${NC}"
echo -e "${GREEN}==============================================${NC}"
if systemctl is-active --quiet ws-proxy; then
    echo -e " WebSocket     : ${WHITE}port ${WS_PORT}${NC}"
else
    echo -e " WebSocket     : ${RED}not running (check: systemctl status ws-proxy)${NC}"
fi
if systemctl is-active --quiet ws-tls; then
    echo -e " WebSocket TLS : ${WHITE}port ${WSS_PORT}${NC}"
else
    echo -e " WebSocket TLS : ${RED}not running (check: systemctl status ws-tls)${NC}"
fi
[[ -n $DOMAIN ]] && echo -e " Domain        : ${WHITE}${DOMAIN}${NC}"
echo -e " Certificate   : ${WHITE}${CERT_TYPE}${NC}"
if systemctl is-active --quiet udpgw; then
    echo -e " UDPGW         : ${WHITE}127.0.0.1:${UDPGW_PORT}${NC} (reach it through the SSH tunnel)"
else
    echo -e " UDPGW         : ${RED}not running${NC}"
fi
echo -e " TCP control   : ${WHITE}${BBR_STATE:-unknown}${NC}"
echo -e " Conn. limits  : ${WHITE}enforced per user${NC}"
if /usr/local/bin/torrent-block status >/dev/null 2>&1; then
    echo -e " Torrent block : ${WHITE}active${NC}"
else
    echo -e " Torrent block : ${RED}not active${NC} (run: torrent-block apply)"
fi
echo -e " Speed limits  : ${WHITE}per user (menu option 10)${NC}"
if [[ $PANEL_OK == 1 ]]; then
    PANEL_HOST=${DOMAIN:-$(curl -s -m 5 ifconfig.me 2>/dev/null)}
    [[ -z $PANEL_HOST ]] && PANEL_HOST=$(hostname -I | awk '{print $1}')
    echo
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${WHITE}  SSH Manager panel${NC}  ${RED}by Coldplay${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo -e " URL      : ${WHITE}https://${PANEL_HOST}:${PANEL_PORT}/${PANEL_PATH}/${NC}"
    echo -e " Username : ${WHITE}${PANEL_USER}${NC}"
    if [[ -n $PANEL_PASS ]]; then
        echo -e " Password : ${WHITE}${PANEL_PASS}${NC}   ${YELLOW}<- save it now, it is shown only once${NC}"
    else
        echo -e " Password : ${WHITE}(unchanged - reset it from the menu: Web panel)${NC}"
    fi
    [[ $CERT_TYPE == "self-signed" ]] && echo -e " ${YELLOW}The browser will warn about the certificate: choose Advanced, then Continue.${NC}"
    echo
elif [[ $PANEL_OK == skipped ]]; then
    echo -e " Web panel     : ${YELLOW}skipped (needs Python 3.7+)${NC}"
else
    echo -e " Web panel     : ${RED}not running (check: systemctl status ws-panel)${NC}"
fi
echo -e " Type ${WHITE}${MENU_CMD}${NC} to open the user manager"
echo -e "${RED}                         Script by Coldplay${NC}"
echo
