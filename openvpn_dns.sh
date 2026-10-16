#!/usr/bin/env bash
# openvpn_dns.sh — DNS por OpenVPN para MikroTik (RouterOS v6 y v7), sin NAT.
#
# Un OpenVPN por MikroTik: el MikroTik N conecta al puerto PUERTO_BASE+N/tcp y usa el
# túnel RED_BASE.N.0/24 (el VPS es .1 y el MikroTik .2). Sus abonados usan como DNS
# RED_BASE.N.1 y la consulta llega con la IP real del abonado.
#
# Las redes de los abonados pueden repetirse entre MikroTik: cada túnel tiene su propia
# tabla de ruteo, y lo que el VPS responde desde RED_BASE.N.1 vuelve por el túnel N,
# sea cual sea la IP del abonado.
#
# Requisitos: Debian 11+ o Ubuntu 22.04+ (OpenVPN 2.5 o superior), root y /dev/net/tun.
# Uso: bash openvpn_dns.sh              menú
#      bash openvpn_dns.sh instalar     instala y agrega el primer MikroTik
#      bash openvpn_dns.sh agregar      agrega un MikroTik

set -Eeuo pipefail
umask 077

###################### CONFIGURACIÓN ######################
PUERTO_BASE=1194        # el MikroTik N escucha en PUERTO_BASE+N/tcp (1195..1204)
MAX_MIKROTIK=10         # puertos abiertos en el proveedor: 1195 a 1204
RED_BASE="100.64"       # el MikroTik N usa RED_BASE.N.0/24
TABLA_BASE=1000         # tabla de ruteo del túnel N = TABLA_BASE+N
MIKROTIK_INTERFAZ="open-vpn"
# Redes de abonados a las que responde Unbound. Si algún ISP da IP públicas a sus
# abonados y las manda por el túnel, agréguelas aquí.
REDES_ABONADOS=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10")
# Compatibilidad RouterOS v6: AES-256-CBC y SHA1, sin tls-crypt ni tls-auth
# (el ovpn-client de MikroTik no los soporta).
CIPHER="AES-256-CBC"
AUTH="SHA1"
###########################################################

DIR_SERVER="/etc/openvpn/server"   # openvpn-server@mtN lee mtN.conf de aquí
DIR_MT="/etc/openvpn/mt"           # PKI, usuarios, CCD y scripts de este instalador
USUARIOS="${DIR_MT}/usuarios"      # usuario:N:hash SHA-512 (ninguna clave en texto plano)
SCRIPT_UP="${DIR_MT}/tunel-up.sh"
SCRIPT_AUTH="${DIR_MT}/verificar-usuario.sh"
CONF_UNBOUND="/etc/unbound/unbound.conf.d/openvpn-dns.conf"
DIR_BACKUP="/root/backups"

trap 'echo "ERROR: falló el script en la línea $LINENO. Revise el mensaje anterior." >&2' ERR

log()  { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[AVISO]\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Este script debe ejecutarse como root. Use: sudo bash $0"
}

check_os() {
  local version
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || die "No se pudo leer /etc/os-release."
  version="${VERSION_ID:-0}"
  version="${version%%.*}"
  case "${ID:-}" in
    debian) [[ "$version" -ge 11 ]] || die "Requiere Debian 11 o superior." ;;
    ubuntu) [[ "$version" -ge 22 ]] || die "Requiere Ubuntu 22.04 o superior (OpenVPN 2.5+)." ;;
    *) die "Distribución no soportada: ${ID:-desconocida}. Use Debian 11+ o Ubuntu 22.04+." ;;
  esac
}

check_tun() {
  [[ -e /dev/net/tun ]] || die "TUN no está disponible. Habilite /dev/net/tun en el VPS/contenedor."
  (exec 7<>/dev/net/tun) 2>/dev/null || die "TUN existe pero no se puede abrir. Revise permisos del VPS/contenedor."
}

respaldar() {
  local destino r rutas=()
  for r in etc/openvpn etc/unbound etc/ufw; do
    if [[ -e "/$r" ]]; then rutas+=("$r"); fi
  done
  if [[ ${#rutas[@]} -eq 0 ]]; then return 0; fi
  install -d -m 0700 "$DIR_BACKUP"
  destino="${DIR_BACKUP}/openvpn-dns-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -C / -czf "$destino" "${rutas[@]}"
  log "Respaldo: ${destino}"
}

ip_publica() {
  local ip url
  for url in https://api.ipify.org https://ifconfig.me/ip; do
    ip="$(curl -4fsS --max-time 8 "$url" 2>/dev/null || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo "CAMBIE_POR_IP_PUBLICA_DEL_VPS"
}

ufw_activo() {
  command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'
}

# ¿Hay en el VPS un DNS que no instaló este script? (el stub de systemd-resolved no cuenta)
dns_ajeno() {
  if [[ -f "$CONF_UNBOUND" ]]; then return 1; fi
  if dpkg -s unbound >/dev/null 2>&1; then return 0; fi
  ss -Hlnu 'sport = :53' 2>/dev/null | awk '{print $4}' | grep -qvE '^127\.0\.0\.5[34]'
}

crear_pki() {
  local era="${DIR_MT}/easy-rsa"
  if [[ -s "${DIR_MT}/server.crt" ]]; then
    log "La PKI ya existe: se reutiliza."
    return 0
  fi
  rm -rf "$era"
  install -d -m 0700 "$era"
  cp -a /usr/share/easy-rsa/. "$era/"
  (
    cd "$era"
    ./easyrsa --batch init-pki
    EASYRSA_CA_EXPIRE=3650 ./easyrsa --batch --req-cn="cn_$(openssl rand -hex 8)" build-ca nopass
    EASYRSA_CERT_EXPIRE=3650 ./easyrsa --batch build-server-full server nopass
  )
  openssl dhparam -out "${DIR_MT}/dh.pem" 2048
  chmod 0644 "${DIR_MT}/dh.pem"
  install -m 0644 "${era}/pki/ca.crt" "${DIR_MT}/ca.crt"
  install -m 0644 "${era}/pki/issued/server.crt" "${DIR_MT}/server.crt"
  install -m 0600 "${era}/pki/private/server.key" "${DIR_MT}/server.key"
}

escribir_scripts() {
  cat > "$SCRIPT_UP" <<EOF
#!/bin/sh
# 'up' de cada túnel (openvpn_dns.sh). Lo que el VPS responde desde la IP de este túnel
# (\$ifconfig_local = ${RED_BASE}.N.1) sale por este túnel: la respuesta a un abonado
# vuelve al MikroTik que preguntó aunque otro MikroTik tenga la misma red.
set -e
PATH=/usr/sbin:/usr/bin:/sbin:/bin
n=\$(echo "\$ifconfig_local" | cut -d. -f3)
tabla=\$(( ${TABLA_BASE} + n ))
ip route replace default dev "\$dev" table "\$tabla"
while ip rule del from "\$ifconfig_local" lookup "\$tabla" 2>/dev/null; do :; done
ip rule add from "\$ifconfig_local" lookup "\$tabla" priority "\$tabla"
EOF

  cat > "$SCRIPT_AUTH" <<EOF
#!/bin/sh
# auth-user-pass-verify via-file (openvpn_dns.sh).
# \$1 = número de MikroTik de la instancia, \$2 = archivo con usuario y clave.
# Cada usuario vale solo en su instancia; la clave se compara con su hash SHA-512.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
n="\$1"
usuario=\$(sed -n 1p "\$2")
clave=\$(sed -n 2p "\$2")
hash=\$(awk -F: -v u="\$usuario" -v n="\$n" '\$1 == u && \$2 == n { print \$3; exit }' "${USUARIOS}")
[ -n "\$hash" ] || exit 1
sal=\$(printf '%s' "\$hash" | cut -d'\$' -f3)
[ "\$(printf '%s\n' "\$clave" | openssl passwd -6 -salt "\$sal" -stdin)" = "\$hash" ]
EOF
  chmod 0700 "$SCRIPT_UP" "$SCRIPT_AUTH"
}

configurar_unbound() {
  local n r
  if dns_ajeno; then
    warn "Ya hay un DNS en este VPS que no instaló este script: no lo toco."
    warn "Para responder a los abonados por los túneles necesita:"
    warn "  interface: ${RED_BASE}.N.1 por cada MikroTik con ip-freebind: yes (o interface-automatic: yes),"
    warn "  para que la respuesta salga desde la IP del túnel y no desde la IP pública;"
    warn "  access-control: <redes de los abonados> allow."
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y unbound
  {
    echo "# Generado por openvpn_dns.sh: DNS para los abonados de los MikroTik por OpenVPN."
    echo "# Escucha desde ya en la IP de cada túnel (ip-freebind): agregar un MikroTik no"
    echo "# obliga a tocar Unbound, y la respuesta sale desde la IP por la que llegó la consulta."
    echo "server:"
    echo "    interface: 127.0.0.1"
    for ((n = 1; n <= MAX_MIKROTIK; n++)); do
      echo "    interface: ${RED_BASE}.${n}.1"
    done
    echo "    ip-freebind: yes"
    echo "    so-reuseport: yes"
    echo "    num-threads: $(nproc)"
    echo "    access-control: 127.0.0.0/8 allow"
    echo "    access-control: ${RED_BASE}.0.0/16 allow"
    for r in "${REDES_ABONADOS[@]}"; do
      echo "    access-control: ${r} allow"
    done
    echo "    hide-identity: yes"
    echo "    hide-version: yes"
    echo "    prefetch: yes"
  } > "$CONF_UNBOUND"
  chmod 0644 "$CONF_UNBOUND"
  if ! unbound-checkconf >/dev/null; then
    rm -f "$CONF_UNBOUND"
    die "unbound-checkconf rechazó la configuración; se quitó ${CONF_UNBOUND}."
  fi
  systemctl enable unbound >/dev/null 2>&1 || true
  systemctl restart unbound
  log "Unbound escucha en ${RED_BASE}.1.1 ... ${RED_BASE}.${MAX_MIKROTIK}.1"
}

instalar() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa openssl ca-certificates curl iproute2 dialog
  check_tun
  respaldar
  install -d -m 0755 "$DIR_SERVER"
  install -d -m 0700 "$DIR_MT"
  crear_pki
  escribir_scripts
  touch "$USUARIOS"
  chmod 0600 "$USUARIOS"

  if systemd-detect-virt -cq 2>/dev/null; then
    # En un contenedor root no está exento de LimitNPROC=10 y la verificación de usuario forkea.
    install -d -m 0755 /etc/systemd/system/openvpn-server@.service.d
    printf '[Service]\nLimitNPROC=infinity\n' > /etc/systemd/system/openvpn-server@.service.d/limitnproc.conf
    chmod 0644 /etc/systemd/system/openvpn-server@.service.d/limitnproc.conf
    systemctl daemon-reload
  fi

  ip_publica > "${DIR_MT}/ip_publica"
  configurar_unbound
  log "OpenVPN instalado (RouterOS v6/v7). Se agrega el primer MikroTik."
  agregar_mikrotik
}

mostrar_datos() {
  local n="$1" usuario="$2" clave="$3" puerto="$4" ip_dns="$5" ip_pub="$6"
  clear || true
  echo "###########################################################"
  echo -e "         \033[0;31mMIKROTIK ${n}\033[0m (guarde estos datos)"
  echo "###########################################################"
  echo -e "\033[0;31m     USUARIO: \e[38;5;198m${usuario}\033[0m"
  echo -e "\033[0;31m  CONTRASEÑA: \e[38;5;198m${clave}\033[0m"
  echo -e "\033[0;31m      PUERTO: \e[38;5;198m${puerto}/tcp\033[0m"
  echo -e "\033[0;31m  DNS ABONADOS: \e[38;5;198m${ip_dns}\033[0m"
  echo "La contraseña no se guarda en el VPS (solo su hash): cópiela ahora."
  echo ""
  echo "########## RouterOS v7 ##########"
  cat <<EOF
/interface ovpn-client
add name=${MIKROTIK_INTERFAZ} connect-to=${ip_pub} port=${puerto} mode=ip user=${usuario} password=${clave} cipher=aes256-cbc add-default-route=no disabled=no
EOF
  echo ""
  echo "########## RouterOS v6 ##########"
  cat <<EOF
/interface ovpn-client
add name=${MIKROTIK_INTERFAZ} connect-to=${ip_pub} port=${puerto} mode=ip user=${usuario} password=${clave} cipher=aes256 add-default-route=no disabled=no
EOF
  echo ""
  echo "########## v6 y v7: DNS por el túnel, sin NAT ##########"
  cat <<EOF
/ip route
add dst-address=${ip_dns}/32 gateway=${MIKROTIK_INTERFAZ} comment="DNS por OpenVPN"
/ip firewall nat
{:local p [find dynamic=no]; :if ([:len \$p] > 0) do={add chain=srcnat action=accept dst-address=${ip_dns} comment="DNS por OpenVPN sin NAT" place-before=[:pick \$p 0]} else={add chain=srcnat action=accept dst-address=${ip_dns} comment="DNS por OpenVPN sin NAT"}}
/ip firewall filter
{:local p [find dynamic=no]; :if ([:len \$p] > 0) do={add chain=forward action=accept dst-address=${ip_dns} out-interface=${MIKROTIK_INTERFAZ} comment="DNS por OpenVPN" place-before=[:pick \$p 0]} else={add chain=forward action=accept dst-address=${ip_dns} out-interface=${MIKROTIK_INTERFAZ} comment="DNS por OpenVPN"}}
# Entregue a los abonados el DNS ${ip_dns} (no la IP del MikroTik), por ejemplo:
#   DHCP:  /ip dhcp-server network set [find address=<red>] dns-server=${ip_dns}
#   PPPoE: /ppp profile set [find name=<perfil>] dns-server=${ip_dns}
EOF
  echo ""
}

agregar_mikrotik() {
  local n="" i usuario clave puerto ip_dns ip_pub
  [[ -s "${DIR_MT}/server.crt" ]] || die "OpenVPN no está instalado. Ejecute primero la opción 1."
  for ((i = 1; i <= MAX_MIKROTIK; i++)); do
    if [[ ! -e "${DIR_SERVER}/mt${i}.conf" ]]; then
      n="$i"
      break
    fi
  done
  [[ -n "$n" ]] || die "Ya hay ${MAX_MIKROTIK} MikroTik, el máximo (MAX_MIKROTIK)."
  respaldar

  puerto=$((PUERTO_BASE + n))
  ip_dns="${RED_BASE}.${n}.1"
  usuario="vpn$(openssl rand -hex 6)"
  clave="$(openssl rand -hex 16)"

  # Si el número N se usó antes, sus credenciales viejas dejan de valer.
  sed -i "/^[^:]*:${n}:/d" "$USUARIOS"
  echo "${usuario}:${n}:$(printf '%s\n' "$clave" | openssl passwd -6 -stdin)" >> "$USUARIOS"

  rm -rf "${DIR_MT}/ccd-${n}"
  install -d -m 0700 "${DIR_MT}/ccd-${n}"
  cat > "${DIR_MT}/ccd-${n}/${usuario}" <<EOF
ifconfig-push ${RED_BASE}.${n}.2 255.255.255.0
# Esta instancia tiene un solo cliente: todo lo que llega por el túnel es de este
# MikroTik, sea cual sea la red de sus abonados (repetida o no con otros MikroTik).
iroute 0.0.0.0 128.0.0.0
iroute 128.0.0.0 128.0.0.0
EOF

  cat > "${DIR_SERVER}/mt${n}.conf" <<EOF
# MikroTik ${n} (usuario ${usuario}), generado por openvpn_dns.sh el $(date '+%F %T')
port ${puerto}
proto tcp4
dev tun${n}
dev-type tun
ca ${DIR_MT}/ca.crt
cert ${DIR_MT}/server.crt
key ${DIR_MT}/server.key
dh ${DIR_MT}/dh.pem
auth ${AUTH}
cipher ${CIPHER}
data-ciphers ${CIPHER}
data-ciphers-fallback ${CIPHER}
tls-version-min 1.2
verify-client-cert none
username-as-common-name
script-security 2
auth-user-pass-verify "${SCRIPT_AUTH} ${n}" via-file
up ${SCRIPT_UP}
client-config-dir ${DIR_MT}/ccd-${n}
topology subnet
server ${RED_BASE}.${n}.0 255.255.255.0
keepalive 10 120
persist-key
persist-tun
verb 3
EOF
  chmod 0600 "${DIR_SERVER}/mt${n}.conf"

  if ufw_activo; then
    ufw allow "${puerto}/tcp" comment "openvpn-dns MikroTik ${n}" >/dev/null
    ufw allow in on "tun${n}" to "$ip_dns" port 53 comment "DNS MikroTik ${n}" >/dev/null
  fi

  systemctl enable --now "openvpn-server@mt${n}.service" || true
  sleep 2
  if ! systemctl is-active --quiet "openvpn-server@mt${n}.service"; then
    journalctl -u "openvpn-server@mt${n}" -n 20 --no-pager >&2 || true
    die "La instancia mt${n} no arrancó."
  fi

  ip_pub="$(cat "${DIR_MT}/ip_publica" 2>/dev/null || true)"
  [[ -n "$ip_pub" ]] || ip_pub="$(ip_publica)"
  mostrar_datos "$n" "$usuario" "$clave" "$puerto" "$ip_dns" "$ip_pub"
}

menu() {
  local opcion rc
  if ! command -v dialog >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y dialog
  fi
  set +e
  opcion=$(dialog --clear \
    --backtitle "OpenVPN DNS" \
    --title "DNS por OpenVPN para MikroTik" \
    --cancel-label "Salir" \
    --ok-label "Aceptar" \
    --menu "Seleccione una opción" \
    12 70 2 \
    1 "Instalar OpenVPN y Unbound" \
    2 "Agregar MikroTik (uno por cada ISP)" \
    2>&1 >/dev/tty)
  rc=$?
  set -e
  clear || true
  [[ "$rc" -eq 0 ]] || exit 0
  case "$opcion" in
    1) instalar ;;
    2) agregar_mikrotik ;;
  esac
}

need_root
check_os
case "${1:-}" in
  instalar) instalar ;;
  agregar) agregar_mikrotik ;;
  "") menu ;;
  *) die "Uso: bash $0 [instalar|agregar]" ;;
esac
