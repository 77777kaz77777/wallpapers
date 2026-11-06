#!/bin/sh
# Checks what Grafana's Zabbix account can see, panel by panel.
# Run from the stack folder on the Docker machine:
#   docker run --rm --network zabbix-grafana_default --env-file .env \
#     -v "$PWD/diag.sh:/diag.sh:ro" alpine:3.20 sh /diag.sh

API="http://zabbix-web:8080/api_jsonrpc.php"
apk add --no-cache curl jq >/dev/null 2>&1 || { echo "Could not install curl/jq"; exit 1; }
TOKEN=""
call() {
  body=$(jq -cn --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')
  if [ -n "$TOKEN" ]; then
    curl -s -m 30 -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $TOKEN" -d "$body" "$API"
  else
    curl -s -m 30 -H 'Content-Type: application/json-rpc' -d "$body" "$API"
  fi
}

echo "== 1. Zabbix API"
v=$(call apiinfo.version '[]' | jq -r '.result // empty')
[ -n "$v" ] && echo "   OK, version $v" || { echo "   NOT REACHABLE: zabbix-web is down. Check: docker compose logs zabbix-web"; exit 1; }

echo "== 2. Login as Grafana's account ($ZBX_GRAFANA_USER)"
out=$(call user.login "$(jq -cn --arg u "$ZBX_GRAFANA_USER" --arg p "$ZBX_GRAFANA_PASSWORD" '{username:$u,password:$p}')")
TOKEN=$(echo "$out" | jq -r '.result // empty')
[ -n "$TOKEN" ] && echo "   OK" || { echo "   FAILED: $(echo "$out" | jq -c '.error')"; echo "   Fix: docker compose run --rm zabbix-setup"; exit 1; }

echo "== 3. Host pve-cluster"
hid=$(call host.get '{"output":["hostid"],"filter":{"host":["pve-cluster"]}}' | jq -r '.result[0].hostid // empty')
[ -n "$hid" ] && echo "   OK, visible to Grafana" || { echo "   NOT VISIBLE: missing, or no read permission. Fix: docker compose run --rm zabbix-setup"; exit 1; }

items=$(call item.get "$(jq -cn --arg h "$hid" '{hostids:[$h],output:["name","lastclock","lastvalue","state"],selectTags:"extend"}')" | jq -c '.result')
now=$(date +%s)

echo "== 4. Items and freshness"
echo "$items" | jq -r --argjson now "$now" '
  "   total: \(length), working: \([.[]|select(.state=="0")]|length), not supported: \([.[]|select(.state=="1")]|length)",
  ( [.[] | .lastclock|tonumber] | max ) as $last
  | if $last == 0 then "   NO VALUES EVER COLLECTED"
    else "   newest value: \($now - $last) seconds ago\(if ($now - $last) > 300 then "   <-- STALE: Zabbix is not collecting" else "" end)" end,
  "   name prefixes: \([.[].name | (capture("^(?<p>[^\\[]+)\\[")? | .p)] | unique | join(", "))"'

echo "== 5. What each panel matches (tag + pattern, as in the dashboard)"
check() {  # title component-tag-value regex
  echo "$items" | jq -r --arg t "$1" --arg tv "$2" --arg re "$3" --argjson now "$now" '
    [ .[] | select( ($tv == "") or any(.tags[]; .tag=="component" and .value==$tv) )
          | select(.name | test($re; "i")) ] as $m
    | "   \($t): \($m|length) items",
      ( $m[0:2][] | "      e.g. \(.name) = \(.lastvalue)   (\(if (.lastclock|tonumber)==0 then "never" else "\($now - (.lastclock|tonumber))s ago" end))" )'
}
check "Node CPU"      cpu     '^Node'
check "Node memory"   memory  '^Node.*(used|usage)'
check "Node uptime"   system  '^Node.*uptime'
check "Storage used"  storage '^Storage.*used'
check "Guest CPU"     cpu     '^(VM|LXC) \['
check "Guest memory"  memory  '^(VM|LXC) \[.*(used|usage)'
check "Network in"    network '^(VM|LXC) \[.*(incoming|netin|received|inbound)'
check "Network out"   network '^(VM|LXC) \[.*(outgoing|netout|sent|outbound)'
check "Guest status"  ""      '^(VM|LXC) \[.*status'

call user.logout '[]' >/dev/null 2>&1
echo "== done"
