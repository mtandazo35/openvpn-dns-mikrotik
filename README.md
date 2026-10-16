# openvpn-dns-mikrotik

Instalador para un VPS que da DNS a los abonados de hasta 10 MikroTik (RouterOS v6 y v7)
por OpenVPN, **sin NAT**: el resolver ve la IP real de cada abonado.

## Cómo funciona

```
abonado 192.168.1.10 ──► MikroTik N ──(túnel N, sin NAT)──► VPS 100.64.N.1 (Unbound)
                                    ◄──────── respuesta por el mismo túnel ────────
```

- **Un OpenVPN por MikroTik.** El MikroTik N conecta a `1194+N/tcp` (1195 a 1204) y usa el
  túnel `100.64.N.0/24`: el VPS es `.1` y el MikroTik `.2`.
- **DNS de los abonados:** `100.64.N.1`. El MikroTik lo entrega por DHCP o PPPoE y lo rutea por
  el túnel sin enmascarar.
- **Las redes de los abonados pueden repetirse entre MikroTik.** Cada túnel tiene su tabla de
  ruteo (`ip rule from 100.64.N.1 lookup 1000+N`), así que lo que Unbound responde desde
  `100.64.N.1` vuelve por el túnel N aunque otro MikroTik tenga la misma red. Por eso cada
  instancia acepta cualquier origen (`iroute` 0/1 y 128/1): tiene un solo cliente.
- **Unbound** escucha desde la instalación en `100.64.1.1` … `100.64.10.1` (`ip-freebind`):
  agregar un MikroTik no obliga a tocar Unbound.
- **Credenciales:** usuario y clave por MikroTik, verificados contra un hash SHA-512 en
  `/etc/openvpn/mt/usuarios`. No son cuentas del sistema (no sirven para SSH) y cada usuario
  solo vale en su propia instancia. La clave se muestra una sola vez.
- **Compatibilidad RouterOS v6:** TCP, AES-256-CBC, SHA1, sin tls-crypt ni tls-auth, sin
  certificado de cliente.

## Uso

```bash
bash openvpn_dns.sh              # menú
bash openvpn_dns.sh instalar     # instala y agrega el primer MikroTik
bash openvpn_dns.sh agregar      # agrega otro MikroTik
```

Al agregar un MikroTik el script imprime los comandos para pegar en RouterOS v7 o v6:
la interfaz `ovpn-client`, la ruta al DNS, la excepción de NAT y la regla de forward
(las dos al principio de su cadena), y cómo entregar el DNS a los abonados.

Antes de cada cambio deja un respaldo de `/etc/openvpn`, `/etc/unbound` y `/etc/ufw` en
`/root/backups/openvpn-dns-<fecha>.tar.gz`.

## Requisitos

- Debian 11+ o Ubuntu 22.04+ (OpenVPN 2.5 o superior), root, `/dev/net/tun`.
- El proveedor debe dejar pasar `1195-1204/tcp`. Si UFW está activo, el script abre el puerto
  de cada MikroTik y el 53 solo en su túnel; con otro firewall, abrirlos a mano.
- Si el VPS ya tiene un DNS que no instaló este script, no lo toca: avisa qué necesita
  (escuchar en `100.64.N.1` con `ip-freebind` o `interface-automatic`, y `access-control`
  para las redes de los abonados).

## Limitaciones

- Si dos ISP tienen la misma IP de abonado (p. ej. 192.168.1.10), en los logs y estadísticas
  de Unbound se ven como una sola.
- Si un ISP usa CGNAT dentro de `100.64.N.0/24` (la red de su propio túnel), choca con el
  túnel: cambiar `RED_BASE` antes de instalar.
- Para agregar redes de abonados que no sean privadas ni CGNAT, editar `REDES_ABONADOS`.
