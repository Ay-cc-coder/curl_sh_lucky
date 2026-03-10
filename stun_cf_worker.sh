#!/bin/sh
# Cloudflare Worker + DNS 自动配置脚本（ImmortalWrt/OpenWrt 专属）
# 敏感参数（api_key/domain）由 Lucky 前置脚本传入，不在此脚本中硬编码

# ====================== ImmortalWrt 环境依赖安装 ======================
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 安装 curl
if ! command -v curl >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1
    opkg install curl --force-depends >/dev/null 2>&1
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl install failed" >&2
        exit 1
    fi
fi

# 安装 jq
if ! command -v jq >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1
    opkg install jq --force-depends >/dev/null 2>&1
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq install failed" >&2
        exit 1
    fi
fi

# ====================== 接收参数（由 Lucky 传入） ======================
NEW_IP=$1
NEW_PORT=$2
API_TOKEN=$3
DOMAIN=$4
RULE_NAME=${5:-ailg}
ACCOUNT_ID=${6:-""}

# 参数校验
if [ -z "$NEW_IP" ] || [ -z "$NEW_PORT" ] || [ -z "$API_TOKEN" ] || [ -z "$DOMAIN" ]; then
    echo "usage: $0 <NEW_IP> <NEW_PORT> <API_TOKEN> <DOMAIN> [RULE_NAME] [ACCOUNT_ID]" >&2
    exit 1
fi

# ====================== Cloudflare API 操作 ======================
# 自动获取 Account ID
if [ -z "$ACCOUNT_ID" ]; then
    ACCOUNTS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json")
    ACCOUNT_ID=$(echo "$ACCOUNTS_RESPONSE" | jq -r '.result[0].id')
    if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "null" ]; then
        echo "failed to get account id" >&2
        exit 1
    fi
fi

# 获取 Zone ID
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
    echo "failed to get zone id" >&2
    exit 1
fi

# 管理 KV 命名空间
KV_NAMESPACE_NAME="${RULE_NAME}-config"
KV_NAMESPACE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" | jq -r ".result[] | select(.title == \"${KV_NAMESPACE_NAME}\") | .id")
if [ -z "$KV_NAMESPACE_ID" ] || [ "$KV_NAMESPACE_ID" = "null" ]; then
    KV_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" --data "{\"title\":\"${KV_NAMESPACE_NAME}\"}")
    KV_NAMESPACE_ID=$(echo "$KV_RESPONSE" | jq -r '.result.id')
    if [ -z "$KV_NAMESPACE_ID" ] || [ "$KV_NAMESPACE_ID" = "null" ]; then
        echo "kv namespace create failed" >&2
        exit 1
    fi
fi

# 更新 KV 配置
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/ip" \
    -H "Authorization: Bearer ${API_TOKEN}" --data "$NEW_IP" >/dev/null
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/port" \
    -H "Authorization: Bearer ${API_TOKEN}" --data "$NEW_PORT" >/dev/null
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/domain" \
    -H "Authorization: Bearer ${API_TOKEN}" --data "$DOMAIN" >/dev/null

# 创建/更新 Worker
WORKER_NAME="${RULE_NAME}-redirect"
WORKER_CODE=$(cat <<'EOF'
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});
async function handleRequest(request) {
  const url = new URL(request.url);
  const pathSegments = url.pathname.split('/').filter(Boolean);
  if (pathSegments.length > 0) {
  const subdomain = pathSegments[0];
  if (typeof CONFIG === 'undefined') {
    return new Response("KV not bound", { status: 500 });
  }
  let targetDomain = await CONFIG.get('domain');
  let targetPort = await CONFIG.get('port');
  if (!targetDomain || !targetPort) {
    return new Response("config missing", { status: 500 });
  }
  const rest = pathSegments.slice(1).join('/');
  const restPath = rest ? '/' + rest : '';
  const search = url.search || '';
  const targetUrl = `https://${subdomain}.${targetDomain}:${targetPort}${restPath}${search}`;
  return Response.redirect(targetUrl, 302);
  }
  return new Response("specify path", { status: 404 });
}
EOF
)

# 临时文件（ImmortalWrt 兼容）
WORKER_CODE_FILE=$(mktemp -t worker.XXXXXX)
echo "$WORKER_CODE" > "$WORKER_CODE_FILE"

METADATA_JSON=$(jq -n -c --arg namespace_id "$KV_NAMESPACE_ID" '{
  "body_part":"script",
  "compatibility_date":"2024-01-01",
  "bindings":[{ "name":"CONFIG","namespace_id":$namespace_id,"type":"kv_namespace" }]
}')

WORKER_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -F "metadata=${METADATA_JSON};type=application/json" \
    -F "script=@${WORKER_CODE_FILE};type=application/javascript")
rm -f "$WORKER_CODE_FILE"

# 管理 Worker 路由
DNS_SUBDOMAIN="${RULE_NAME}.${DOMAIN}"
ROUTE_PATTERN="${DNS_SUBDOMAIN}/*"
EXISTING_ROUTE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/workers/routes" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" | jq -r ".result[] | select(.pattern == \"${ROUTE_PATTERN}\") | .id // empty")
if [ -n "$EXISTING_ROUTE" ] && [ "$EXISTING_ROUTE" != "null" ]; then
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/workers/routes/${EXISTING_ROUTE}" \
        -H "Authorization: Bearer ${API_TOKEN}" >/dev/null
fi
ROUTE_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/workers/routes" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
    --data "{\"pattern\":\"${ROUTE_PATTERN}\",\"script\":\"${WORKER_NAME}\"}")

# 管理 DNS 记录
EXISTING_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${RULE_NAME}.${DOMAIN}" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')
if [ -n "$EXISTING_RECORD" ] && [ "$EXISTING_RECORD" != "null" ]; then
    DNS_RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_RECORD}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${RULE_NAME}\",\"content\":\"8.8.8.8\",\"proxied\":true}")
else
    DNS_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${RULE_NAME}\",\"content\":\"8.8.8.8\",\"proxied\":true}")
fi

DNS_SUCCESS=$(echo "$DNS_RESPONSE" | jq -r '.success')
if [ "$DNS_SUCCESS" != "true" ]; then
    echo "dns update failed" >&2
    exit 1
fi

# 通配符 DNS
WILDCARD_RECORD=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=*.${DOMAIN}" \
    -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" | jq -r '.result[0].id')
if [ -n "$WILDCARD_RECORD" ] && [ "$WILDCARD_RECORD" != "null" ]; then
    WILDCARD_RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${WILDCARD_RECORD}" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"*\",\"content\":\"${NEW_IP}\",\"proxied\":false}")
else
    WILDCARD_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${API_TOKEN}" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"*\",\"content\":\"${NEW_IP}\",\"proxied\":false}")
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✅ 配置更新完成，豆包倾情演绎。访问地址：https://${RULE_NAME}.${DOMAIN}"
exit 0
