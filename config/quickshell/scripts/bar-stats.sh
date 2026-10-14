#!/usr/bin/env bash
# bar-stats.sh — long-running feed for the Quickshell bar.
# Prints one JSON line every 2 s: cpu %, memory, cpu temp, Predator mode,
# screen brightness, (every 10 s) the active network, and apps using the camera.

find_hwmon() {
    local h
    for h in /sys/class/hwmon/hwmon*; do
        [[ $(<"$h/name") == "$1" ]] 2>/dev/null && { echo "$h"; return; }
    done
}
find_profile() {
    local p
    for p in /sys/class/platform-profile/*/; do
        [[ $(<"$p/name") == acer-wmi ]] 2>/dev/null && { echo "$p/profile"; return; }
    done
}
json_str() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

coretemp=$(find_hwmon coretemp)
backlight=$(ls -d /sys/class/backlight/* 2>/dev/null | head -1)
read -r _ u n s idle iow irq sirq _ < /proc/stat
prev_total=$((u + n + s + idle + iow + irq + sirq)); prev_idle=$((idle + iow))
net_type="none" net_name="" net_signal=0 tick=0
# VPN details: exit IP + location are looked up once per (re)connect
vpn_prev="" vpn_since=0 vpn_ip="" vpn_loc="" vpn_lookup=0 vpn_tries=0
jget() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" <<<"$2" | head -1; }

while :; do
    sleep 2
    read -r _ u n s idle iow irq sirq _ < /proc/stat
    total=$((u + n + s + idle + iow + irq + sirq)); idl=$((idle + iow))
    dt=$((total - prev_total)); di=$((idl - prev_idle))
    cpu=0; (( dt > 0 )) && cpu=$(( (100 * (dt - di)) / dt ))
    prev_total=$total; prev_idle=$idl

    while read -r k v _; do
        case $k in MemTotal:) mt=$v ;; MemAvailable:) ma=$v ;; esac
    done < /proc/meminfo
    mem_used=$(( (mt - ma) / 1024 )); mem_total=$(( mt / 1024 ))

    temp=0; [[ -n $coretemp ]] && temp=$(( $(<"$coretemp/temp1_input") / 1000 ))
    prof_file=$(find_profile); prof=""
    [[ -n $prof_file ]] && prof=$(<"$prof_file") 2>/dev/null
    bri=-1
    [[ -n $backlight ]] && bri=$(( 100 * $(<"$backlight/brightness") / $(<"$backlight/max_brightness") ))

    if (( tick % 5 == 0 )); then
        net_type="none" net_name="" net_signal=0
        while IFS=: read -r type state conn; do
            [[ $state == connected ]] || continue
            case $type in
                wifi)     net_type=wifi; net_name=$conn; break ;;
                ethernet) net_type=ethernet; net_name=$conn ;;
            esac
        done < <(nmcli -t -f TYPE,STATE,CONNECTION device 2>/dev/null)
        if [[ $net_type == wifi ]]; then
            net_signal=$(nmcli -t -f IN-USE,SIGNAL device wifi list --rescan no 2>/dev/null \
                | awk -F: '$1=="*"{print $2; exit}')
            net_signal=${net_signal:-0}
        fi
    fi
    tick=$((tick + 1))

    # active VPN (NetworkManager): Proton names its connections "ProtonVPN <server>"
    vpn_provider="" vpn_server=""
    while IFS=: read -r type name; do
        case $type in vpn|wireguard) ;; *) continue ;; esac
        name=${name//\\:/:}
        if [[ $name == ProtonVPN* ]]; then
            vpn_provider="Proton VPN"; vpn_server=${name#ProtonVPN}; vpn_server=${vpn_server# }
        else
            vpn_provider=$name
        fi
        break
    done < <(nmcli -t -f TYPE,NAME connection show --active 2>/dev/null)

    # new connection / server change: reset details and schedule the exit-IP lookup
    if [[ "$vpn_provider|$vpn_server" != "$vpn_prev" ]]; then
        vpn_prev="$vpn_provider|$vpn_server"
        vpn_ip="" vpn_loc="" vpn_tries=0
        if [[ -n $vpn_provider ]]; then
            vpn_since=$(date +%s); vpn_lookup=2    # give the tunnel ~4 s to settle
        else
            vpn_since=0; vpn_lookup=0
        fi
    fi
    if (( vpn_lookup > 0 )) && (( --vpn_lookup == 0 )); then
        info=$(curl -s -m 4 https://ipinfo.io/json 2>/dev/null)
        vpn_ip=$(jget ip "$info")
        city=$(jget city "$info"); country=$(jget country "$info")
        vpn_loc=${city:+$city, }$country
        # retry a few times if the lookup failed (tunnel still coming up)
        if [[ -z $vpn_ip ]] && (( ++vpn_tries < 4 )); then vpn_lookup=5; fi
    fi

    # privacy: processes that have a camera (/dev/video*) open
    cam=""
    while read -r fdp; do
        pid=${fdp#/proc/}; pid=${pid%%/*}
        read -r comm 2>/dev/null < "/proc/$pid/comm" || continue
        [[ $comm == wireplumber ]] && continue
        [[ ",$cam," == *",$comm,"* ]] || cam=${cam:+$cam,}$comm
    done < <(find /proc/[0-9]*/fd -maxdepth 1 -lname '/dev/video*' 2>/dev/null)

    printf '{"cpu":%d,"memUsed":%d,"memTotal":%d,"temp":%d,"profile":%s,"brightness":%d,"netType":"%s","netName":%s,"netSignal":%d,"vpnProvider":%s,"vpnServer":%s,"vpnSince":%d,"vpnIp":%s,"vpnLocation":%s,"cam":%s}\n' \
        "$cpu" "$mem_used" "$mem_total" "$temp" "$(json_str "$prof")" "$bri" \
        "$net_type" "$(json_str "$net_name")" "$net_signal" \
        "$(json_str "$vpn_provider")" "$(json_str "$vpn_server")" \
        "$vpn_since" "$(json_str "$vpn_ip")" "$(json_str "$vpn_loc")" "$(json_str "$cam")"
done
