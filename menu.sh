#!/usr/bin/env bash
# ==============================================================
#  MenuServidor - Menu de administração para servidores Ubuntu
#  Repositório: https://github.com/DenanHK1/MenuServidor (main)
#
#  Uso:
#    sudo bash menu.sh
#    sudo bash <(curl -Ss https://raw.githubusercontent.com/DenanHK1/MenuServidor/main/menu.sh)
# ==============================================================

# ---------- Auto-sudo ----------
if [[ $EUID -ne 0 ]]; then
    if [[ -f "$0" ]]; then
        exec sudo bash "$0" "$@"
    else
        echo "Este script precisa de root. Execute assim:"
        echo "  sudo bash <(curl -Ss https://raw.githubusercontent.com/DenanHK1/MenuServidor/main/menu.sh)"
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
#  Menu principal
# ==============================================================
while true; do
    header "MenuServidor - ${PRETTY_NAME}"
    echo " 1) SSH"
    echo " 2) Instalar Pelican ou Wings"
    echo " 3) Rede"
    echo " 4) iptables"
    echo " 0) Sair"
    echo
    read -rp "Opção: " op
    case $op in
        1) menu_ssh ;;
        2) instalar_pelican ;;
        3) menu_rede ;;
        4) menu_iptables ;;
        0) echo "Até mais!"; exit 0 ;;
        *) invalid ;;
    esac
done
