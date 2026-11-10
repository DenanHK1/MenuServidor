#!/usr/bin/env bash
# ==============================================================
#  MenuServidor - Menu de administração para servidores Ubuntu
#  Repositório: https://github.com/DenanHK1/MenuServidor (main)
#
#  Uso:
#    sudo bash menu.sh
#    bash <(curl -Ss https://raw.githubusercontent.com/DenanHK1/MenuServidor/main/menu.sh)   (como root)
# ==============================================================

# ---------- Auto-sudo ----------
if [[ $EUID -ne 0 ]]; then
    if [[ -f "$0" ]]; then
        exec sudo bash "$0" "$@"
    else
        echo "Este script precisa de root. Baixe o arquivo e execute com sudo:"
        echo "  curl -Ss -o menu.sh https://raw.githubusercontent.com/DenanHK1/MenuServidor/main/menu.sh"
        echo "  sudo bash menu.sh"
        exit 1
    fi
fi

# ---------- Somente Ubuntu ----------
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
fi
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "Este script funciona apenas no Ubuntu (detectado: ${PRETTY_NAME:-desconhecido})."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ---------- Cores e utilitários ----------
R=$'\e[1;31m'; G=$'\e[1;32m'; Y=$'\e[1;33m'; B=$'\e[1;34m'; C=$'\e[1;36m'; N=$'\e[0m'

ok()   { echo -e "${G}[OK]${N} $*"; }
err()  { echo -e "${R}[ERRO]${N} $*"; }
warn() { echo -e "${Y}[AVISO]${N} $*"; }
info() { echo -e "${C}[INFO]${N} $*"; }

pause() { echo; read -rp "Pressione ENTER para continuar..." _; }

confirm() {
    local r
    read -rp "$1 [s/N]: " r
    [[ "$r" =~ ^[sSyY]$ ]]
}

header() {
    clear
    echo -e "${B}==================================================${N}"
    echo -e "${B}  $1${N}"
    echo -e "${B}==================================================${N}"
}

invalid() { err "Opção inválida."; sleep 1; }

valid_ip() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -ra oct <<<"$ip"
    for o in "${oct[@]}"; do (( o <= 255 )) || return 1; done
    return 0
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

need_pkg() {
    # need_pkg <comando> <pacote>
    if ! command -v "$1" >/dev/null 2>&1; then
        info "Instalando $2..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "$2" >/dev/null 2>&1 || { err "Falha ao instalar $2."; return 1; }
    fi
    return 0
}

# ==============================================================
#  SSH
# ==============================================================
SSHD_CONF=/etc/ssh/sshd_config

ssh_installed() { command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; }

ssh_require() {
    if ! ssh_installed; then
        warn "OpenSSH Server não está instalado."
        if confirm "Instalar agora?"; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y openssh-server || { err "Falha na instalação."; return 1; }
        else
            return 1
        fi
    fi
    return 0
}

# Define uma opção no topo do sshd_config (antes de qualquer Include/Match,
# assim ela tem prioridade, pois no sshd o primeiro valor vale).
sshd_set() {
    local key=$1 value=$2
    sed -i -E "/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]/d" "$SSHD_CONF"
    sed -i "1i ${key} ${value}" "$SSHD_CONF"
}

sshd_unset() {
    local key=$1
    sed -i -E "/^[[:space:]]*${key}[[:space:]]/d" "$SSHD_CONF"
}

sshd_backup() {
    SSHD_BAK="${SSHD_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$SSHD_CONF" "$SSHD_BAK"
}

# Valida e reinicia o SSH; se a config for inválida, restaura o backup.
sshd_apply() {
    mkdir -p /run/sshd
    if ! sshd -t 2>/tmp/sshd_test.err; then
        err "Configuração inválida, restaurando backup:"
        cat /tmp/sshd_test.err
        cp -a "$SSHD_BAK" "$SSHD_CONF"
        return 1
    fi
    if systemctl is-active --quiet ssh; then
        # Ubuntu 24.04 usa ssh.socket, que ignora Port/ListenAddress
        if systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
            systemctl disable --now ssh.socket >/dev/null 2>&1
            systemctl enable --now ssh >/dev/null 2>&1
        fi
        systemctl restart ssh && ok "SSH reiniciado com a nova configuração."
    else
        ok "Configuração salva (o serviço SSH está desativado)."
    fi
}

ssh_status() {
    header "Status do SSH"
    if systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket 2>/dev/null; then
        echo -e "Serviço:        ${G}ATIVO${N}"
    else
        echo -e "Serviço:        ${R}INATIVO${N}"
    fi
    if systemctl is-enabled --quiet ssh 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        echo -e "Início no boot: ${G}SIM${N}"
    else
        echo -e "Início no boot: ${R}NÃO${N}"
    fi
    if ssh_installed; then
        mkdir -p /run/sshd
        echo
        echo "Configuração efetiva:"
        sshd -T 2>/dev/null | grep -E '^(port|listenaddress|permitrootlogin|passwordauthentication|subsystem) ' | sed 's/^/  /'
    fi
    echo
    echo "Portas em escuta (sshd):"
    ss -tlnp 2>/dev/null | grep sshd | sed 's/^/  /' || true
}

ssh_ativar() {
    ssh_require || return
    systemctl unmask ssh >/dev/null 2>&1
    systemctl enable --now ssh >/dev/null 2>&1
    if systemctl is-active --quiet ssh; then ok "SSH ativado."; else err "Não foi possível ativar o SSH."; fi
}

ssh_desativar() {
    if ! ssh_installed; then warn "SSH não está instalado."; return; fi
    warn "Se você estiver conectado por SSH, a conexão pode cair."
    confirm "Desativar o SSH?" || return
    systemctl disable --now ssh.socket >/dev/null 2>&1
    systemctl disable --now ssh >/dev/null 2>&1
    ok "SSH desativado."
}

ssh_acesso() {
    ssh_require || return
    while true; do
        header "SSH > Mudar acesso (ListenAddress)"
        echo "Atual:"
        sshd -T 2>/dev/null | grep -E '^listenaddress ' | sed 's/^/  /'
        echo
        echo " 1) 127.0.0.1  (somente local / via túnel)"
        echo " 2) Todas as interfaces (padrão: 0.0.0.0 e ::)"
        echo " 3) Somente IPv4 em todas as interfaces (0.0.0.0)"
        echo " 4) Escolher um IP da máquina"
        echo " 5) Digitar um IP personalizado"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        local addr=""
        case $op in
            1)
                warn "Com 127.0.0.1 o SSH só aceitará conexões vindas da própria máquina."
                confirm "Continuar?" || continue
                addr="127.0.0.1" ;;
            2)
                sshd_backup; sshd_unset ListenAddress; sshd_apply; pause; continue ;;
            3) addr="0.0.0.0" ;;
            4)
                echo; ip -4 -o addr show | awk '{print "  " $2 " -> " $4}'
                echo
                read -rp "Digite o IP (sem /mask): " addr
                valid_ip "$addr" || { err "IP inválido."; pause; continue; } ;;
            5)
                read -rp "IP: " addr
                valid_ip "$addr" || { err "IP inválido."; pause; continue; } ;;
            0) return ;;
            *) invalid; continue ;;
        esac
        sshd_backup
        sshd_unset ListenAddress
        sshd_set ListenAddress "$addr"
        sshd_apply
        pause
    done
}

ssh_porta() {
    ssh_require || return
    read -rp "Nova porta SSH (padrão 22): " p
    valid_port "$p" || { err "Porta inválida."; return; }
    warn "Lembre de liberar a porta $p no firewall (iptables/ufw/provedor)."
    confirm "Alterar a porta para $p?" || return
    sshd_backup
    sshd_set Port "$p"
    sshd_apply
}

ssh_root() {
    ssh_require || return
    while true; do
        header "SSH > Acesso root"
        sshd -T 2>/dev/null | grep -E '^permitrootlogin ' | sed 's/^/Atual: /'
        echo
        echo " 1) Permitir root (com senha e chave)  [yes]"
        echo " 2) Permitir root somente com chave    [prohibit-password]"
        echo " 3) Negar root                         [no]"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        local v=""
        case $op in
            1) v="yes"; warn "Login root com senha é arriscado. Use senha forte ou chaves." ;;
            2) v="prohibit-password" ;;
            3) v="no" ;;
            0) return ;;
            *) invalid; continue ;;
        esac
        sshd_backup
        sshd_set PermitRootLogin "$v"
        sshd_apply
        pause
    done
}

ssh_sftp() {
    ssh_require || return
    while true; do
        header "SSH > SFTP"
        sshd -T 2>/dev/null | grep -E '^subsystem ' | sed 's/^/Atual: /'
        echo
        echo " 1) Ativar SFTP (sftp-server padrão)"
        echo " 2) Ativar SFTP (internal-sftp)"
        echo " 3) Desativar SFTP"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1)
                sshd_backup
                sed -i -E '/^[[:space:]]*#?[[:space:]]*Subsystem[[:space:]]+sftp/d' "$SSHD_CONF"
                sed -i "1i Subsystem sftp /usr/lib/openssh/sftp-server" "$SSHD_CONF"
                sshd_apply; pause ;;
            2)
                sshd_backup
                sed -i -E '/^[[:space:]]*#?[[:space:]]*Subsystem[[:space:]]+sftp/d' "$SSHD_CONF"
                sed -i "1i Subsystem sftp internal-sftp" "$SSHD_CONF"
                sshd_apply; pause ;;
            3)
                sshd_backup
                sed -i -E '/^[[:space:]]*#?[[:space:]]*Subsystem[[:space:]]+sftp/d' "$SSHD_CONF"
                sshd_apply; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

menu_ssh() {
    while true; do
        header "Menu SSH"
        echo " 1) Ver status"
        echo " 2) Ativar SSH"
        echo " 3) Desativar SSH"
        echo " 4) Mudar acesso do SSH (127.0.0.1, todas, IP específico)"
        echo " 5) Permitir / negar acesso root"
        echo " 6) SFTP (ativar / desativar)"
        echo " 7) Mudar porta do SSH"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) ssh_status; pause ;;
            2) ssh_ativar; pause ;;
            3) ssh_desativar; pause ;;
            4) ssh_acesso ;;
            5) ssh_root ;;
            6) ssh_sftp ;;
            7) ssh_porta; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Pelican / Wings
# ==============================================================
instalar_pelican() {
    header "Instalar Pelican ou Wings"
    echo "Será executado o instalador:"
    echo "  https://raw.githubusercontent.com/DenanHK1/Pelinstaller-pt-BR/Production/install.sh"
    echo
    confirm "Continuar?" || return
    need_pkg curl curl
    need_pkg wget wget
    bash <(curl -Ss https://raw.githubusercontent.com/DenanHK1/Pelinstaller-pt-BR/Production/install.sh || wget -O - https://raw.githubusercontent.com/DenanHK1/Pelinstaller/Production/install.sh)
    pause
}

# ==============================================================
#  Rede
# ==============================================================
NETPLAN_FILE=/etc/netplan/99-menuservidor.yaml

rede_info() {
    header "Informações de rede"
    ip -br addr
    echo
    echo "Rotas:"
    ip route | sed 's/^/  /'
    echo
    echo "DNS:"
    (resolvectl dns 2>/dev/null || cat /etc/resolv.conf) | sed 's/^/  /'
    echo
    echo -n "IPv6: "
    if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]]; then
        echo -e "${R}DESATIVADO${N}"
    else
        echo -e "${G}ATIVADO${N}"
    fi
}

rede_ipv4_fixo() {
    header "Definir IPv4 fixo (netplan)"
    echo "Interfaces disponíveis:"
    ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -v '^lo$' | sed 's/^/  - /'
    echo
    read -rp "Interface (ex: eth0, ens3): " iface
    ip link show "$iface" >/dev/null 2>&1 || { err "Interface não encontrada."; return; }
    read -rp "IP/CIDR (ex: 192.168.1.50/24): " ipcidr
    valid_ip "${ipcidr%/*}" && [[ "${ipcidr#*/}" =~ ^[0-9]+$ ]] && (( ${ipcidr#*/} <= 32 )) || { err "IP/CIDR inválido."; return; }
    read -rp "Gateway (ex: 192.168.1.1): " gw
    valid_ip "$gw" || { err "Gateway inválido."; return; }
    read -rp "DNS separados por vírgula [1.1.1.1,8.8.8.8]: " dns
    dns=${dns:-1.1.1.1,8.8.8.8}
    for d in ${dns//,/ }; do valid_ip "$d" || { err "DNS inválido: $d"; return; }; done

    warn "Se estiver conectado por SSH, um IP errado derruba o acesso."
    info "Será usado 'netplan try': se você não confirmar em 60s, volta ao normal."
    confirm "Aplicar?" || return

    [[ -f $NETPLAN_FILE ]] && cp -a "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"
    cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: false
      addresses: [$ipcidr]
      routes:
        - to: 0.0.0.0/0
          via: $gw
      nameservers:
        addresses: [${dns}]
EOF
    chmod 600 "$NETPLAN_FILE"
    if ! netplan generate; then
        err "Netplan inválido. Revertendo."
        rm -f "$NETPLAN_FILE"
        [[ -f ${NETPLAN_FILE}.bak ]] && mv "${NETPLAN_FILE}.bak" "$NETPLAN_FILE"
        return
    fi
    if netplan try --timeout 60; then
        ok "IPv4 fixo aplicado."
    else
        err "Não confirmado, configuração revertida."
        rm -f "$NETPLAN_FILE"
        [[ -f ${NETPLAN_FILE}.bak ]] && mv "${NETPLAN_FILE}.bak" "$NETPLAN_FILE"
    fi
}

rede_voltar_dhcp() {
    if [[ ! -f $NETPLAN_FILE ]]; then
        warn "Nenhum IP fixo criado por este menu foi encontrado."
        return
    fi
    confirm "Remover o IP fixo e voltar ao padrão (DHCP/config original)?" || return
    rm -f "$NETPLAN_FILE"
    netplan apply && ok "Configuração de IP fixo removida."
}

rede_ipv6() {
    local v=$1
    cat > /etc/sysctl.d/99-menuservidor-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = $v
net.ipv6.conf.default.disable_ipv6 = $v
net.ipv6.conf.lo.disable_ipv6 = $v
EOF
    sysctl --system >/dev/null 2>&1
    if [[ $v == 1 ]]; then
        ok "IPv6 desativado (persistente)."
    else
        ok "IPv6 ativado (persistente). Pode ser necessário reiniciar a rede: netplan apply"
    fi
}

teste_portas() {
    header "Testador de portas"
    echo " 1) Testar TCP"
    echo " 2) Testar UDP"
    echo " 3) Ver portas em escuta nesta máquina"
    echo " 0) Voltar"
    echo
    read -rp "Opção: " op
    case $op in
        1|2)
            read -rp "Host/IP [127.0.0.1]: " h
            h=${h:-127.0.0.1}
            read -rp "Porta(s) (ex: 22 80 443 ou 22,80,443): " ports
            ports=${ports//,/ }
            echo
            for p in $ports; do
                valid_port "$p" || { err "Porta inválida: $p"; continue; }
                if [[ $op == 1 ]]; then
                    if timeout 3 bash -c "</dev/tcp/$h/$p" 2>/dev/null; then
                        echo -e "TCP $h:$p -> ${G}ABERTA${N}"
                    else
                        echo -e "TCP $h:$p -> ${R}FECHADA / SEM RESPOSTA${N}"
                    fi
                else
                    need_pkg nc netcat-openbsd || continue
                    if nc -u -z -w3 "$h" "$p" 2>/dev/null; then
                        echo -e "UDP $h:$p -> ${G}SEM ERRO (provavelmente aberta)${N}"
                    else
                        echo -e "UDP $h:$p -> ${R}FECHADA / FILTRADA${N}"
                    fi
                fi
            done
            if [[ $op == 2 ]]; then
                echo
                warn "UDP não tem handshake: o teste é aproximado e pode dar falso positivo."
            fi
            pause ;;
        3)
            echo
            ss -tulpn
            pause ;;
        0) return ;;
        *) invalid ;;
    esac
}

teste_internet() {
    header "Teste de conexão com a internet"
    echo "- Ping 1.1.1.1 (conectividade IP):"
    if ping -c 3 -W 2 1.1.1.1 >/dev/null 2>&1; then ok "OK"; else err "Falhou"; fi
    echo "- Ping 8.8.8.8:"
    if ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1; then ok "OK"; else err "Falhou"; fi
    echo "- Resolução de DNS (google.com):"
    if getent hosts google.com >/dev/null 2>&1; then ok "OK ($(getent hosts google.com | awk '{print $1}' | head -1))"; else err "Falhou"; fi
    echo "- HTTP/HTTPS:"
    need_pkg curl curl
    code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' https://www.google.com 2>/dev/null)
    if [[ $code =~ ^(200|301|302)$ ]]; then ok "OK (HTTP $code)"; else err "Falhou (HTTP ${code:-sem resposta})"; fi
    echo "- IP público:"
    pub=$(curl -s -m 6 https://ifconfig.me 2>/dev/null)
    echo "  ${pub:-não foi possível obter}"
    pause
}

menu_rede() {
    while true; do
        header "Menu de Rede"
        echo " 1) Ver informações de rede"
        echo " 2) Definir IPv4 fixo"
        echo " 3) Remover IPv4 fixo (voltar ao padrão)"
        echo " 4) Ativar IPv6"
        echo " 5) Desativar IPv6"
        echo " 6) Testar portas TCP / UDP"
        echo " 7) Testar conexão com a internet"
        echo " 8) Teste de velocidade (speedtest)"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) rede_info; pause ;;
            2) rede_ipv4_fixo; pause ;;
            3) rede_voltar_dhcp; pause ;;
            4) rede_ipv6 0; pause ;;
            5) confirm "Desativar o IPv6?" && rede_ipv6 1; pause ;;
            6) teste_portas ;;
            7) teste_internet ;;
            8)
                need_pkg speedtest-cli speedtest-cli && { info "Medindo (pode levar alguns segundos)..."; speedtest-cli --simple; }
                pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  iptables
# ==============================================================
ipt_require() { need_pkg iptables iptables; }

ipt_tabela() {
    echo " 1) filter  2) nat  3) mangle  4) raw" >&2
    read -rp "Tabela [1]: " t >&2
    case ${t:-1} in
        1) echo filter ;; 2) echo nat ;; 3) echo mangle ;; 4) echo raw ;;
        *) echo filter ;;
    esac
}

ipt_ver() {
    header "iptables > Ver regras"
    local t; t=$(ipt_tabela)
    echo
    echo " 1) Lista detalhada (com números)"
    echo " 2) Formato -S (comandos)"
    read -rp "Formato [1]: " f
    echo
    if [[ ${f:-1} == 2 ]]; then
        iptables -t "$t" -S
    else
        iptables -t "$t" -L -n -v --line-numbers
    fi
}

ipt_deletar() {
    header "iptables > Deletar regra"
    local t; t=$(ipt_tabela)
    echo
    echo "Chains da tabela $t:"
    iptables -t "$t" -S | awk '$1=="-P"||$1=="-N"{print "  " $2}'
    echo
    read -rp "Chain (ex: INPUT): " ch
    [[ -n $ch ]] || return
    echo
    iptables -t "$t" -L "$ch" -n -v --line-numbers || return
    echo
    read -rp "Número da regra a deletar: " n
    [[ $n =~ ^[0-9]+$ ]] || { err "Número inválido."; return; }
    confirm "Deletar a regra $n da chain $ch ($t)?" || return
    iptables -t "$t" -D "$ch" "$n" && ok "Regra deletada."
}

ipt_regra_rapida() {
    # ipt_regra_rapida <ACCEPT|DROP> porta
    local alvo=$1
    read -rp "Protocolo (tcp/udp) [tcp]: " proto
    proto=${proto:-tcp}
    [[ $proto =~ ^(tcp|udp)$ ]] || { err "Protocolo inválido."; return; }
    read -rp "Porta: " p
    valid_port "$p" || { err "Porta inválida."; return; }
    if iptables -C INPUT -p "$proto" --dport "$p" -j "$alvo" 2>/dev/null; then
        warn "Essa regra já existe."
        return
    fi
    iptables -I INPUT 1 -p "$proto" --dport "$p" -j "$alvo" && ok "Regra $alvo $proto/$p inserida no topo da INPUT."
}

ipt_regra_ip() {
    local alvo=$1
    read -rp "IP ou rede (ex: 1.2.3.4 ou 10.0.0.0/24): " ip
    valid_ip "${ip%/*}" || { err "IP inválido."; return; }
    if iptables -C INPUT -s "$ip" -j "$alvo" 2>/dev/null; then
        warn "Essa regra já existe."
        return
    fi
    iptables -I INPUT 1 -s "$ip" -j "$alvo" && ok "Regra $alvo para $ip inserida no topo da INPUT."
}

ipt_politica() {
    header "iptables > Política padrão"
    iptables -S | grep '^-P' | sed 's/^/  /'
    echo
    read -rp "Chain (INPUT/FORWARD/OUTPUT): " ch
    [[ $ch =~ ^(INPUT|FORWARD|OUTPUT)$ ]] || { err "Chain inválida."; return; }
    read -rp "Política (ACCEPT/DROP): " pol
    [[ $pol =~ ^(ACCEPT|DROP)$ ]] || { err "Política inválida."; return; }
    if [[ $ch == INPUT && $pol == DROP ]]; then
        warn "INPUT em DROP bloqueia TUDO que não tiver regra ACCEPT, inclusive seu SSH!"
        warn "Garanta antes uma regra liberando a porta do SSH."
    fi
    confirm "Aplicar $ch = $pol?" || return
    iptables -P "$ch" "$pol" && ok "Política alterada."
}

ipt_limpar_chain() {
    header "iptables > Limpar (flush) uma chain"
    local t; t=$(ipt_tabela)
    read -rp "Chain (ex: INPUT): " ch
    [[ -n $ch ]] || return
    confirm "Apagar TODAS as regras da chain $ch ($t)?" || return
    iptables -t "$t" -F "$ch" && ok "Chain limpa."
}

ipt_limpar_tudo() {
    header "iptables > Resetar tudo"
    warn "Isso apaga todas as regras e define as políticas como ACCEPT."
    confirm "Continuar?" || return
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    for t in filter nat mangle raw; do
        iptables -t "$t" -F 2>/dev/null
        iptables -t "$t" -X 2>/dev/null
    done
    ok "iptables resetado."
}

ipt_salvar() {
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        info "Instalando iptables-persistent..."
        echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq iptables-persistent >/dev/null 2>&1 || { err "Falha ao instalar."; return; }
    fi
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 && ok "Regras salvas em /etc/iptables/rules.v4 (carregam no boot)."
}

ipt_restaurar() {
    if [[ -f /etc/iptables/rules.v4 ]]; then
        confirm "Restaurar as regras salvas em /etc/iptables/rules.v4?" || return
        iptables-restore < /etc/iptables/rules.v4 && ok "Regras restauradas."
    else
        err "Nenhum arquivo /etc/iptables/rules.v4 encontrado."
    fi
}

menu_iptables() {
    ipt_require || { pause; return; }
    while true; do
        header "Menu iptables"
        echo " 1) Ver regras / tabelas"
        echo " 2) Deletar regra (por número)"
        echo " 3) Liberar porta (ACCEPT)"
        echo " 4) Bloquear porta (DROP)"
        echo " 5) Liberar IP/rede (ACCEPT)"
        echo " 6) Bloquear IP/rede (DROP)"
        echo " 7) Mudar política padrão (ACCEPT/DROP)"
        echo " 8) Limpar uma chain"
        echo " 9) Resetar tudo"
        echo "10) Salvar regras (persistir no boot)"
        echo "11) Restaurar regras salvas"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) ipt_ver; pause ;;
            2) ipt_deletar; pause ;;
            3) ipt_regra_rapida ACCEPT; pause ;;
            4) ipt_regra_rapida DROP; pause ;;
            5) ipt_regra_ip ACCEPT; pause ;;
            6) ipt_regra_ip DROP; pause ;;
            7) ipt_politica; pause ;;
            8) ipt_limpar_chain; pause ;;
            9) ipt_limpar_tudo; pause ;;
            10) ipt_salvar; pause ;;
            11) ipt_restaurar; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Sistema
# ==============================================================
sys_atualizar() {
    header "Sistema > Atualizar pacotes"
    confirm "Executar apt update e upgrade?" || return
    apt-get update && apt-get upgrade -y
    if confirm "Remover pacotes não utilizados (autoremove)?"; then
        apt-get autoremove -y
    fi
    [[ -f /var/run/reboot-required ]] && warn "O sistema pede reinicialização."
}

sys_info() {
    header "Sistema > Informações e uso de recursos"
    hostnamectl 2>/dev/null | sed 's/^/  /'
    echo
    echo "Uptime / carga:"; uptime | sed 's/^/  /'
    echo
    echo "Memória:"; free -h | sed 's/^/  /'
    echo
    echo "Disco:"; df -h -x tmpfs -x devtmpfs -x squashfs | sed 's/^/  /'
    echo
    echo "Top 5 processos por CPU:"
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -6 | sed 's/^/  /'
}

sys_hostname() {
    echo "Hostname atual: $(hostname)"
    read -rp "Novo hostname: " h
    [[ $h =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || { err "Hostname inválido."; return; }
    hostnamectl set-hostname "$h" && ok "Hostname alterado para $h."
}

sys_timezone() {
    echo "Fuso atual: $(timedatectl show -p Timezone --value 2>/dev/null)"
    read -rp "Novo fuso [America/Sao_Paulo]: " tz
    tz=${tz:-America/Sao_Paulo}
    timedatectl set-timezone "$tz" 2>/dev/null && ok "Fuso alterado para $tz." || err "Fuso inválido (veja: timedatectl list-timezones)."
}

sys_swap() {
    header "Sistema > Swap"
    swapon --show
    echo
    if [[ -f /swapfile ]]; then
        warn "Já existe /swapfile."
        if confirm "Remover o /swapfile atual?"; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
            sed -i '\|^/swapfile |d' /etc/fstab
            ok "Swap removida."
        fi
        return
    fi
    read -rp "Tamanho da swap em GB (ex: 2): " gb
    [[ $gb =~ ^[1-9][0-9]*$ ]] || { err "Valor inválido."; return; }
    info "Criando swap de ${gb}G..."
    if ! fallocate -l "${gb}G" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=$((gb * 1024)) status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null && swapon /swapfile || { err "Falha ao criar a swap."; rm -f /swapfile; return; }
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap de ${gb}G ativada (persistente)."
}

sys_energia() {
    echo " 1) Reiniciar"
    echo " 2) Desligar"
    echo " 0) Cancelar"
    read -rp "Opção: " op
    case $op in
        1) confirm "Reiniciar agora?" && reboot ;;
        2) confirm "Desligar agora?" && poweroff ;;
    esac
}

menu_sistema() {
    while true; do
        header "Menu Sistema"
        echo " 1) Atualizar pacotes (apt)"
        echo " 2) Informações e uso de recursos"
        echo " 3) Mudar hostname"
        echo " 4) Mudar fuso horário"
        echo " 5) Criar / remover swap"
        echo " 6) Reiniciar / desligar"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) sys_atualizar; pause ;;
            2) sys_info; pause ;;
            3) sys_hostname; pause ;;
            4) sys_timezone; pause ;;
            5) sys_swap; pause ;;
            6) sys_energia ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Usuários
# ==============================================================
usr_listar() {
    header "Usuários > Listar"
    echo "Usuários normais:"
    awk -F: '$3>=1000 && $3<65534 {print "  " $1}' /etc/passwd
    echo
    echo "Membros do grupo sudo:"
    getent group sudo | cut -d: -f4 | tr ',' '\n' | sed 's/^/  /'
}

usr_criar() {
    read -rp "Nome do novo usuário: " u
    [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "Nome inválido (use minúsculas, números, _ e -)."; return; }
    id "$u" >/dev/null 2>&1 && { err "O usuário já existe."; return; }
    adduser --gecos "" "$u" || { err "Falha ao criar o usuário."; return; }
    if confirm "Dar permissão de administrador (sudo) a $u?"; then
        usermod -aG sudo "$u" && ok "$u agora está no grupo sudo."
    fi
}

usr_senha() {
    read -rp "Usuário: " u
    id "$u" >/dev/null 2>&1 || { err "Usuário não encontrado."; return; }
    passwd "$u"
}

usr_sudo() {
    read -rp "Usuário: " u
    id "$u" >/dev/null 2>&1 || { err "Usuário não encontrado."; return; }
    echo " 1) Dar sudo   2) Remover sudo"
    read -rp "Opção: " op
    case $op in
        1) usermod -aG sudo "$u" && ok "sudo concedido a $u." ;;
        2) gpasswd -d "$u" sudo && ok "sudo removido de $u." ;;
        *) invalid ;;
    esac
}

usr_deletar() {
    read -rp "Usuário a deletar: " u
    [[ $u == root ]] && { err "Não é permitido deletar o root."; return; }
    id "$u" >/dev/null 2>&1 || { err "Usuário não encontrado."; return; }
    confirm "Deletar o usuário $u?" || return
    if confirm "Apagar também a pasta home de $u?"; then
        deluser --remove-home "$u"
    else
        deluser "$u"
    fi
}

menu_usuarios() {
    while true; do
        header "Menu Usuários"
        echo " 1) Listar usuários"
        echo " 2) Criar usuário"
        echo " 3) Trocar senha"
        echo " 4) Dar / remover sudo"
        echo " 5) Deletar usuário"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) usr_listar; pause ;;
            2) usr_criar; pause ;;
            3) usr_senha; pause ;;
            4) usr_sudo; pause ;;
            5) usr_deletar; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Docker
# ==============================================================
docker_instalar() {
    if command -v docker >/dev/null 2>&1; then
        ok "Docker já instalado: $(docker --version)"
        return
    fi
    need_pkg curl curl
    info "Instalando Docker (script oficial get.docker.com)..."
    curl -fsSL https://get.docker.com | sh || { err "Falha na instalação."; return; }
    systemctl enable --now docker >/dev/null 2>&1
    ok "Docker instalado."
}

menu_docker() {
    while true; do
        header "Menu Docker"
        echo " 1) Instalar Docker"
        echo " 2) Status do serviço"
        echo " 3) Listar containers"
        echo " 4) Uso de disco do Docker"
        echo " 5) Limpar recursos não usados (prune)"
        echo " 6) Reiniciar o Docker"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) docker_instalar; pause ;;
            2) systemctl status docker --no-pager 2>&1 | head -15; pause ;;
            3) command -v docker >/dev/null && docker ps -a || err "Docker não instalado."; pause ;;
            4) command -v docker >/dev/null && docker system df || err "Docker não instalado."; pause ;;
            5)
                if command -v docker >/dev/null; then
                    warn "Remove containers parados, redes e imagens sem uso."
                    confirm "Continuar?" && docker system prune -a
                else err "Docker não instalado."; fi
                pause ;;
            6) systemctl restart docker && ok "Docker reiniciado."; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Fail2ban
# ==============================================================
menu_fail2ban() {
    while true; do
        header "Menu Fail2ban (proteção contra força bruta)"
        echo " 1) Instalar e ativar"
        echo " 2) Status e IPs banidos (sshd)"
        echo " 3) Desbanir um IP"
        echo " 4) Banir um IP manualmente"
        echo " 5) Desativar"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1)
                need_pkg fail2ban-client fail2ban || { pause; continue; }
                systemctl enable --now fail2ban >/dev/null 2>&1
                systemctl is-active --quiet fail2ban && ok "Fail2ban ativo (jail sshd padrão)." || err "Falha ao ativar."
                pause ;;
            2)
                command -v fail2ban-client >/dev/null || { err "Fail2ban não instalado."; pause; continue; }
                fail2ban-client status sshd 2>&1
                pause ;;
            3)
                command -v fail2ban-client >/dev/null || { err "Fail2ban não instalado."; pause; continue; }
                read -rp "IP a desbanir: " ip
                valid_ip "$ip" || { err "IP inválido."; pause; continue; }
                fail2ban-client set sshd unbanip "$ip"
                pause ;;
            4)
                command -v fail2ban-client >/dev/null || { err "Fail2ban não instalado."; pause; continue; }
                read -rp "IP a banir: " ip
                valid_ip "$ip" || { err "IP inválido."; pause; continue; }
                fail2ban-client set sshd banip "$ip"
                pause ;;
            5)
                confirm "Desativar o Fail2ban?" && systemctl disable --now fail2ban && ok "Fail2ban desativado."
                pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Serviços e logs
# ==============================================================
menu_servicos() {
    while true; do
        header "Menu Serviços e Logs"
        echo " 1) Serviços em execução"
        echo " 2) Serviços com falha"
        echo " 3) Status de um serviço"
        echo " 4) Iniciar / parar / reiniciar um serviço"
        echo " 5) Ver logs de um serviço"
        echo " 6) Ver últimos logins"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) systemctl list-units --type=service --state=running --no-pager | less -FRX ;;
            2) systemctl --failed --no-pager; pause ;;
            3)
                read -rp "Nome do serviço (ex: docker, ssh, wings): " s
                [[ -n $s ]] && systemctl status "$s" --no-pager 2>&1 | head -20
                pause ;;
            4)
                read -rp "Nome do serviço: " s
                [[ -n $s ]] || continue
                echo " 1) Iniciar  2) Parar  3) Reiniciar"
                read -rp "Ação: " a
                case $a in
                    1) systemctl start "$s" && ok "Iniciado." ;;
                    2) systemctl stop "$s" && ok "Parado." ;;
                    3) systemctl restart "$s" && ok "Reiniciado." ;;
                    *) invalid ;;
                esac
                pause ;;
            5)
                read -rp "Nome do serviço: " s
                read -rp "Quantas linhas [50]: " l
                l=${l:-50}
                [[ $l =~ ^[0-9]+$ && -n $s ]] && journalctl -u "$s" -n "$l" --no-pager | less -FRX
                ;;
            6) last -n 15; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  DDNS (ddclient)
# ==============================================================
DDCONF=/etc/ddclient.conf

ddns_instalar() {
    if command -v ddclient >/dev/null 2>&1; then
        ok "ddclient já instalado ($(dpkg-query -W -f='${Version}' ddclient 2>/dev/null))."
        return 0
    fi
    info "Instalando ddclient..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y ddclient >/dev/null 2>&1 || { err "Falha ao instalar o ddclient."; return 1; }
    ok "ddclient instalado."
}

ddns_configurar() {
    header "DDNS > Configurar ddclient"
    if ! command -v ddclient >/dev/null 2>&1; then
        warn "ddclient não está instalado."
        confirm "Instalar agora?" && ddns_instalar || return
    fi

    echo " 1) Cloudflare (token de API)"
    echo " 2) DuckDNS"
    echo " 3) No-IP"
    echo " 0) Cancelar"
    echo
    read -rp "Provedor: " p
    [[ $p =~ ^[123]$ ]] || return

    local ver ipcfg
    ver=$(dpkg-query -W -f='${Version}' ddclient 2>/dev/null)
    if dpkg --compare-versions "${ver:-0}" ge 3.10.0; then
        ipcfg=$'usev4=webv4\nwebv4=https://api.ipify.org'
    else
        ipcfg=$'use=web\nweb=https://api.ipify.org'
    fi

    local zone host user pass body
    case $p in
        1)
            read -rp "Zona/domínio raiz no Cloudflare (ex: exemplo.com): " zone
            read -rp "Hostname(s) a atualizar, separados por vírgula (ex: smb.exemplo.com): " host
            read -rsp "Token de API do Cloudflare (permissão Zone:DNS:Edit): " pass; echo
            [[ -n $zone && -n $host && -n $pass ]] || { err "Campos obrigatórios vazios."; return; }
            [[ $pass == *\'* ]] && { err "O token não pode conter aspas simples."; return; }
            body="protocol=cloudflare
zone=$zone
login=token
password='$pass'
$host" ;;
        2)
            read -rp "Subdomínio(s) DuckDNS, separados por vírgula (sem .duckdns.org): " host
            read -rsp "Token do DuckDNS: " pass; echo
            [[ -n $host && -n $pass ]] || { err "Campos obrigatórios vazios."; return; }
            [[ $pass == *\'* ]] && { err "O token não pode conter aspas simples."; return; }
            body="protocol=duckdns
server=www.duckdns.org
password='$pass'
$host" ;;
        3)
            read -rp "Usuário No-IP: " user
            read -rsp "Senha No-IP: " pass; echo
            read -rp "Hostname(s), separados por vírgula: " host
            [[ -n $user && -n $pass && -n $host ]] || { err "Campos obrigatórios vazios."; return; }
            [[ $pass == *\'* ]] && { err "A senha não pode conter aspas simples."; return; }
            body="protocol=noip
login=$user
password='$pass'
$host" ;;
    esac

    [[ -f $DDCONF ]] && cp -a "$DDCONF" "${DDCONF}.bak.$(date +%Y%m%d-%H%M%S)"
    {
        echo "# Gerado pelo MenuServidor"
        echo "daemon=300"
        echo "syslog=yes"
        echo "pid=/var/run/ddclient.pid"
        echo "ssl=yes"
        echo "$ipcfg"
        echo "$body"
    } > "$DDCONF"
    chmod 600 "$DDCONF"
    ok "Configuração salva em $DDCONF (atualiza a cada 5 minutos)."

    systemctl enable ddclient >/dev/null 2>&1
    systemctl restart ddclient
    echo
    info "Testando uma atualização agora..."
    ddclient -daemon=0 -verbose -noquiet -force 2>&1 | tail -15
}

ddns_status() {
    header "DDNS > Status"
    if systemctl is-active --quiet ddclient; then
        echo -e "Serviço: ${G}ATIVO${N}"
    else
        echo -e "Serviço: ${R}INATIVO${N}"
    fi
    echo
    systemctl status ddclient --no-pager 2>&1 | head -12
    echo
    echo "IP público atual: $(curl -s -m 6 https://api.ipify.org || echo 'indisponível')"
}

menu_ddns() {
    while true; do
        header "Menu DDNS (ddclient)"
        echo " 1) Instalar ddclient"
        echo " 2) Configurar (Cloudflare / DuckDNS / No-IP)"
        echo " 3) Ver status e IP público"
        echo " 4) Forçar atualização agora"
        echo " 5) Ver logs"
        echo " 6) Editar configuração manualmente (nano)"
        echo " 7) Parar e desativar"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) ddns_instalar; pause ;;
            2) ddns_configurar; pause ;;
            3) need_pkg curl curl; ddns_status; pause ;;
            4)
                command -v ddclient >/dev/null || { err "ddclient não instalado."; pause; continue; }
                ddclient -daemon=0 -verbose -noquiet -force 2>&1 | tail -20
                pause ;;
            5) journalctl -u ddclient -n 50 --no-pager | less -FRX ;;
            6)
                [[ -f $DDCONF ]] || { err "Ainda não existe $DDCONF."; pause; continue; }
                nano "$DDCONF" && systemctl restart ddclient 2>/dev/null ;;
            7) systemctl disable --now ddclient && ok "ddclient desativado."; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Túneis / VPN (Cloudflared e Tailscale)
# ==============================================================
cf_instalar() {
    if command -v cloudflared >/dev/null 2>&1; then
        ok "cloudflared já instalado ($(cloudflared --version 2>&1 | head -1))."
        return
    fi
    need_pkg curl curl
    info "Adicionando o repositório oficial da Cloudflare..."
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg || { err "Falha ao baixar a chave."; return; }
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y cloudflared >/dev/null 2>&1 && ok "cloudflared instalado." || err "Falha ao instalar."
}

cf_servico() {
    command -v cloudflared >/dev/null || { err "cloudflared não instalado."; return; }
    read -rsp "Token do túnel (Zero Trust > Networks > Tunnels): " tk; echo
    [[ -n $tk ]] || { err "Token vazio."; return; }
    cloudflared service install "$tk" && ok "Serviço do túnel instalado e iniciado."
}

ts_instalar() {
    if command -v tailscale >/dev/null 2>&1; then
        ok "Tailscale já instalado."
        return
    fi
    need_pkg curl curl
    info "Instalando Tailscale (script oficial)..."
    curl -fsSL https://tailscale.com/install.sh | sh || err "Falha na instalação."
}

menu_tuneis() {
    while true; do
        header "Menu Túneis / VPN"
        echo " 1) Cloudflared: instalar"
        echo " 2) Cloudflared: instalar serviço com token do túnel"
        echo " 3) Cloudflared: status"
        echo " 4) Cloudflared: remover serviço"
        echo " 5) Tailscale: instalar"
        echo " 6) Tailscale: conectar (tailscale up)"
        echo " 7) Tailscale: status"
        echo " 8) Tailscale: desconectar"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) cf_instalar; pause ;;
            2) cf_servico; pause ;;
            3) systemctl status cloudflared --no-pager 2>&1 | head -15; pause ;;
            4) command -v cloudflared >/dev/null && confirm "Remover o serviço do túnel?" && cloudflared service uninstall; pause ;;
            5) ts_instalar; pause ;;
            6) command -v tailscale >/dev/null && tailscale up || err "Tailscale não instalado."; pause ;;
            7) command -v tailscale >/dev/null && tailscale status || err "Tailscale não instalado."; pause ;;
            8) command -v tailscale >/dev/null && tailscale down && ok "Desconectado."; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Backup
# ==============================================================
bkp_criar() {
    read -rp "Pasta ou arquivo para backup (ex: /etc): " src
    src=${src%/}
    [[ -n $src && -e $src ]] || { err "Caminho não existe (ou é a raiz /)."; return; }
    read -rp "Pasta de destino [/root/backups]: " dst
    dst=${dst:-/root/backups}
    mkdir -p "$dst" || { err "Não foi possível criar $dst."; return; }
    local src_real dst_real parent rel
    local -a excl=()
    src_real=$(realpath "$src")
    dst_real=$(realpath "$dst")
    if [[ -d $src_real ]]; then
        if [[ $dst_real == "$src_real" ]]; then
            err "O destino não pode ser a própria pasta de origem."
            return
        fi
        if [[ $dst_real == "$src_real"/* ]]; then
            parent=$(dirname "$src_real")
            if [[ $parent == "/" ]]; then rel=${dst_real#/}; else rel=${dst_real#"$parent"/}; fi
            excl=(--exclude="$rel")
            info "O destino está dentro da origem: $dst_real será ignorado no backup."
        fi
    fi
    local nome="backup-$(basename "$src_real")-$(date +%Y%m%d-%H%M%S).tar.gz"
    info "Compactando..."
    if tar -czf "$dst/$nome" "${excl[@]}" -C "$(dirname "$src_real")" "$(basename "$src_real")" 2>/tmp/bkp.err; then
        ok "Criado: $dst/$nome ($(du -h "$dst/$nome" | cut -f1))"
    else
        err "Falha ao criar o backup:"
        cat /tmp/bkp.err
        rm -f "$dst/$nome"
    fi
}

bkp_listar() {
    read -rp "Pasta de backups [/root/backups]: " dst
    dst=${dst:-/root/backups}
    ls -lh "$dst"/*.tar.gz 2>/dev/null || warn "Nenhum backup .tar.gz em $dst."
}

bkp_restaurar() {
    read -rp "Arquivo de backup (.tar.gz): " f
    [[ -f $f ]] || { err "Arquivo não encontrado."; return; }
    echo "Conteúdo (primeiros itens):"
    tar -tzf "$f" | head -10 | sed 's/^/  /'
    read -rp "Restaurar em qual pasta? [/]: " d
    d=${d:-/}
    [[ -d $d ]] || { err "Pasta de destino não existe."; return; }
    warn "Arquivos existentes em $d com o mesmo nome serão sobrescritos."
    confirm "Restaurar?" || return
    tar -xzf "$f" -C "$d" && ok "Backup restaurado em $d."
}

bkp_limpar() {
    read -rp "Pasta de backups [/root/backups]: " dst
    dst=${dst:-/root/backups}
    read -rp "Apagar backups com mais de quantos dias? " dias
    [[ $dias =~ ^[0-9]+$ ]] || { err "Valor inválido."; return; }
    local lista
    lista=$(find "$dst" -maxdepth 1 -name 'backup-*.tar.gz' -mtime +"$dias" 2>/dev/null)
    [[ -n $lista ]] || { info "Nenhum backup com mais de $dias dias."; return; }
    echo "$lista" | sed 's/^/  /'
    confirm "Apagar esses arquivos?" || return
    find "$dst" -maxdepth 1 -name 'backup-*.tar.gz' -mtime +"$dias" -delete && ok "Backups antigos removidos."
}

bkp_configs() {
    header "Backup > Configurações do servidor"
    echo "Serão incluídos (somente o que existir):"
    echo "  SSH, chaves do root, netplan, sysctl, hosts, fstab, ddclient,"
    echo "  fail2ban, cloudflared, docker, cron, sudoers, regras do iptables"
    echo "  (estado atual) e o crontab do root."
    echo
    read -rp "Pasta de destino [/root/backups]: " dst
    dst=${dst:-/root/backups}
    mkdir -p "$dst" || { err "Não foi possível criar $dst."; return; }

    local stage nome item
    local -a itens=()
    stage=$(mktemp -d)
    mkdir -p "$stage/etc/menuservidor-extra"
    command -v iptables-save >/dev/null 2>&1 && iptables-save > "$stage/etc/menuservidor-extra/iptables-atual.rules" 2>/dev/null
    crontab -l > "$stage/etc/menuservidor-extra/crontab-root.txt" 2>/dev/null
    dpkg --get-selections > "$stage/etc/menuservidor-extra/pacotes-instalados.txt" 2>/dev/null

    for item in etc/ssh root/.ssh etc/netplan etc/sysctl.d etc/hosts etc/fstab \
                etc/ddclient.conf etc/fail2ban etc/cloudflared etc/docker \
                etc/cron.d var/spool/cron/crontabs etc/sudoers.d etc/iptables; do
        [[ -e /$item ]] && itens+=("$item")
    done

    nome="backup-configs-$(hostname)-$(date +%Y%m%d-%H%M%S).tar.gz"
    info "Compactando ${#itens[@]} itens..."
    if tar -czf "$dst/$nome" -C / "${itens[@]}" -C "$stage" etc/menuservidor-extra 2>/tmp/bkp.err; then
        chmod 600 "$dst/$nome"
        ok "Criado: $dst/$nome ($(du -h "$dst/$nome" | cut -f1))"
        warn "Esse arquivo contém chaves e tokens. Guarde-o em local seguro."
        info "Para restaurar, use 'Restaurar um backup' com destino /"
    else
        err "Falha ao criar o backup:"
        cat /tmp/bkp.err
        rm -f "$dst/$nome"
    fi
    rm -rf "$stage"
}

menu_backup() {
    while true; do
        header "Menu Backup"
        echo " 1) Criar backup (.tar.gz) de uma pasta"
        echo " 2) Listar backups"
        echo " 3) Restaurar um backup"
        echo " 4) Apagar backups antigos"
        echo " 5) Backup das configurações do servidor (SSH, rede, ddclient...)"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) bkp_criar; pause ;;
            2) bkp_listar; pause ;;
            3) bkp_restaurar; pause ;;
            4) bkp_limpar; pause ;;
            5) bkp_configs; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Cron (agendador de tarefas do root)
# ==============================================================
cron_listar() {
    if crontab -l >/dev/null 2>&1; then
        crontab -l | nl -ba | sed 's/^/  /'
    else
        warn "O root não tem tarefas agendadas."
    fi
}

cron_adicionar() {
    header "Cron > Adicionar tarefa"
    echo " 1) A cada hora"
    echo " 2) Diariamente"
    echo " 3) Semanalmente (domingo)"
    echo " 4) Ao iniciar o sistema"
    echo " 5) Personalizado (5 campos)"
    echo " 0) Cancelar"
    echo
    read -rp "Opção: " op
    local sched t h m
    case $op in
        1) sched="0 * * * *" ;;
        2|3)
            read -rp "Horário (HH:MM): " t
            [[ $t =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] || { err "Horário inválido."; return; }
            h=${t%%:*}; m=${t##*:}
            if [[ $op == 2 ]]; then sched="$((10#$m)) $((10#$h)) * * *"; else sched="$((10#$m)) $((10#$h)) * * 0"; fi ;;
        4) sched="@reboot" ;;
        5)
            read -rp "Agenda (ex: */15 * * * *): " sched
            [[ $(wc -w <<<"$sched") -eq 5 ]] || { err "Informe exatamente 5 campos."; return; } ;;
        *) return ;;
    esac
    read -rp "Comando a executar: " cmd
    [[ -n $cmd ]] || { err "Comando vazio."; return; }
    ( crontab -l 2>/dev/null; echo "$sched $cmd" ) | crontab - && ok "Tarefa adicionada: $sched $cmd"
}

cron_remover() {
    crontab -l >/dev/null 2>&1 || { warn "O root não tem tarefas agendadas."; return; }
    cron_listar
    echo
    read -rp "Número da linha a remover: " n
    [[ $n =~ ^[0-9]+$ ]] || { err "Número inválido."; return; }
    local novo
    novo=$(crontab -l | sed "${n}d")
    confirm "Remover a linha $n?" || return
    if [[ -z ${novo//[[:space:]]/} ]]; then
        crontab -r && ok "Linha removida (crontab ficou vazio)."
    else
        echo "$novo" | crontab - && ok "Linha removida."
    fi
}

menu_cron() {
    while true; do
        header "Menu Cron"
        echo " 1) Listar tarefas"
        echo " 2) Adicionar tarefa"
        echo " 3) Remover tarefa"
        echo " 4) Editar manualmente (crontab -e)"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) cron_listar; pause ;;
            2) cron_adicionar; pause ;;
            3) cron_remover; pause ;;
            4) crontab -e ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Chaves SSH
# ==============================================================
key_escolher_user() {
    read -rp "Usuário [root]: " KUSER
    KUSER=${KUSER:-root}
    KHOME=$(getent passwd "$KUSER" | cut -d: -f6)
    [[ -n $KHOME && -d $KHOME ]] || { err "Usuário ou pasta home não encontrados."; return 1; }
    KAK="$KHOME/.ssh/authorized_keys"
}

key_preparar() {
    mkdir -p "$KHOME/.ssh"
    touch "$KAK"
    chmod 700 "$KHOME/.ssh"
    chmod 600 "$KAK"
    chown -R "$KUSER": "$KHOME/.ssh"
}

key_listar() {
    key_escolher_user || return
    [[ -s $KAK ]] || { warn "Nenhuma chave autorizada para $KUSER."; return; }
    echo "Chaves autorizadas de $KUSER:"
    awk '{print "  " NR ") " $1 "  ..." substr($2, length($2)-9) "  " $3}' "$KAK"
}

key_adicionar() {
    key_escolher_user || return
    echo "Cole a chave pública (uma linha, ex: ssh-ed25519 AAAA... comentário):"
    read -r chave
    local tmp; tmp=$(mktemp)
    echo "$chave" > "$tmp"
    if ! ssh-keygen -lf "$tmp" >/dev/null 2>&1; then
        err "Chave pública inválida."; rm -f "$tmp"; return
    fi
    rm -f "$tmp"
    key_preparar
    if grep -qxF "$chave" "$KAK"; then
        warn "Essa chave já está autorizada."
    else
        echo "$chave" >> "$KAK" && ok "Chave adicionada para $KUSER."
    fi
}

key_remover() {
    key_listar || return
    [[ -s $KAK ]] || return
    echo
    read -rp "Número da chave a remover: " n
    [[ $n =~ ^[0-9]+$ ]] || { err "Número inválido."; return; }
    confirm "Remover a chave $n?" || return
    sed -i "${n}d" "$KAK" && ok "Chave removida."
}

key_gerar() {
    local dir=/root/chaves-ssh nome f
    mkdir -p -m 700 "$dir"
    read -rp "Nome da chave [servidor]: " nome
    nome=${nome:-servidor}
    [[ $nome =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Nome inválido."; return; }
    f="$dir/$nome"
    [[ -e $f ]] && { err "Já existe $f."; return; }
    ssh-keygen -t ed25519 -f "$f" -C "$nome@$(hostname)" || return
    ok "Par de chaves criado:"
    echo "  Privada: $f"
    echo "  Pública: $f.pub"
    warn "Copie a chave privada para o seu computador e depois apague-a do servidor."
    if confirm "Autorizar essa chave pública em um usuário deste servidor?"; then
        key_escolher_user || return
        key_preparar
        cat "$f.pub" >> "$KAK" && ok "Chave autorizada para $KUSER."
    fi
}

key_senha_ssh() {
    ssh_require || return
    echo " 1) Desativar login por senha (somente chave)"
    echo " 2) Ativar login por senha"
    read -rp "Opção: " op
    case $op in
        1)
            warn "Só faça isso se você JÁ testou o login com chave em outra janela."
            warn "Senão você pode ficar sem acesso ao servidor."
            confirm "Desativar o login por senha?" || return
            sshd_backup; sshd_set PasswordAuthentication no; sshd_apply ;;
        2)
            sshd_backup; sshd_set PasswordAuthentication yes; sshd_apply ;;
        *) invalid ;;
    esac
}

menu_chaves() {
    while true; do
        header "Menu Chaves SSH"
        echo " 1) Listar chaves autorizadas de um usuário"
        echo " 2) Adicionar chave pública"
        echo " 3) Remover chave autorizada"
        echo " 4) Gerar novo par de chaves (ed25519)"
        echo " 5) Ativar / desativar login por senha no SSH"
        echo " 0) Voltar"
        echo
        read -rp "Opção: " op
        case $op in
            1) key_listar; pause ;;
            2) key_adicionar; pause ;;
            3) key_remover; pause ;;
            4) key_gerar; pause ;;
            5) key_senha_ssh; pause ;;
            0) return ;;
            *) invalid ;;
        esac
    done
}

# ==============================================================
#  Menu principal
# ==============================================================
while true; do
    header "MenuServidor - ${PRETTY_NAME}"
    echo " 1) SSH"
    echo " 2) Instalar Pelican ou Wings"
    echo " 3) Rede"
    echo " 4) iptables"
    echo " 5) Sistema (atualizar, recursos, swap, hostname...)"
    echo " 6) Usuários"
    echo " 7) Docker"
    echo " 8) Fail2ban"
    echo " 9) Serviços e logs"
    echo "10) DDNS (ddclient)"
    echo "11) Túneis / VPN (Cloudflared, Tailscale)"
    echo "12) Backup"
    echo "13) Cron (tarefas agendadas)"
    echo "14) Chaves SSH"
    echo " 0) Sair"
    echo
    read -rp "Opção: " op
    case $op in
        1) menu_ssh ;;
        2) instalar_pelican ;;
        3) menu_rede ;;
        4) menu_iptables ;;
        5) menu_sistema ;;
        6) menu_usuarios ;;
        7) menu_docker ;;
        8) menu_fail2ban ;;
        9) menu_servicos ;;
        10) menu_ddns ;;
        11) menu_tuneis ;;
        12) menu_backup ;;
        13) menu_cron ;;
        14) menu_chaves ;;
        0) echo "Até mais!"; exit 0 ;;
        *) invalid ;;
    esac
done
