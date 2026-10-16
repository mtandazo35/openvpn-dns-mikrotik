# openvpn-dns-mikrotik

Instalador OpenVPN para hasta 10 MikroTik (RouterOS v6 y v7) que llegan a un VPS **sin NAT**:
lo que los abonados mandan al VPS por el túnel conserva su IP real.

> **Estado:** todavía sin probar en un VPS. No usar en producción hasta que esta nota desaparezca.

## Cómo funciona

```
abonado 192.168.1.10 ──► MikroTik N ──(túnel N, sin NAT)──► VPS 100.64.N.1
                                    ◄──────── respuesta por el mismo túnel ────────
```

- **Un OpenVPN por MikroTik.** El MikroTik N conecta a `1194+N/tcp` (1195 a 1204) y usa el
  túnel `100.64.N.0/24`: el VPS es `.1` y el MikroTik `.2`.
- **Las redes de los abonados pueden repetirse entre MikroTik.** Cada túnel tiene su tabla de
  ruteo (`ip rule from 100.64.N.1 lookup 1000+N`), así que lo que el VPS responde desde
  `100.64.N.1` vuelve por el túnel N aunque otro MikroTik tenga la misma red. Por eso cada
  instancia acepta cualquier origen (`iroute` 0/1 y 128/1): tiene un solo cliente.
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
la interfaz `ovpn-client`, la excepción de NAT y la regla de forward hacia `100.64.N.1`
(las dos al principio de su cadena).

Antes de cada cambio deja un respaldo de `/etc/openvpn` y `/etc/ufw` en
`/root/backups/openvpn-mt-<fecha>.tar.gz`.

## Requisitos

- Debian 11+ o Ubuntu 22.04+ (OpenVPN 2.5 o superior), root, `/dev/net/tun`.
- El proveedor debe dejar pasar `1195-1204/tcp`. Si UFW está activo, el script abre el puerto
  de cada MikroTik; con otro firewall, abrirlo a mano.
- El servicio del VPS que atienda a los abonados tiene que escuchar en `100.64.N.1` (o responder
  desde la dirección en la que recibió). Si escucha en `0.0.0.0` sin eso, sus respuestas UDP salen
  con la IP pública y no entran en la tabla del túnel.

## Limitaciones

- Si un ISP usa CGNAT dentro de `100.64.N.0/24` (la red de su propio túnel), choca con el
  túnel: cambiar `RED_BASE` antes de instalar.
