#!/bin/sh
# Cloudflare Worker 动态端口重定向脚本 (路径转子域名版)

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 安装依赖
for pkg in curl jq; do
    if ! command -v $pkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install $pkg --force-depends >/dev/null 2>&1
    fi
done

# 接收参数
NEW_IP=$1
NEW_PORT=$2
API_TOKEN=$3
DOMAIN=$4
RULE_NAME=${5:-my}
ACCOUNT_ID=${6:-""}

# 获取 Account ID 和 Zone ID
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "null" ]; then
    ACCOUNT_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" -H "Authorization: Bearer ${API_TOKEN}" | jq -r '.result[0].id')
fi
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" -H "Authorization: Bearer ${API_TOKEN}" | jq -r '.result[0].id')

# 管理 KV 空间
KV_NAMESPACE_NAME="${RULE_NAME}-config"
KV_NAMESPACE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces" -H "Authorization: Bearer ${API_TOKEN}" | jq -r ".result[] | select(.title == \"${KV_NAMESPACE_NAME}\") | .id")
if [ -z "$KV_NAMESPACE_ID" ] || [ "$KV_NAMESPACE_ID" = "null" ]; then
    KV_NAMESPACE_ID=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces" -H "Authorization: Bearer ${API_TOKEN}" --data "{\"title\":\"${KV_NAMESPACE_NAME}\"}" | jq -r '.result.id')
fi

# 写入当前 STUN 映射的端口和域名
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/port" -H "Authorization: Bearer ${API_TOKEN}" --data "$NEW_PORT"
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/domain" -H "Authorization: Bearer ${API_TOKEN}" --data "$DOMAIN"

# 生成 Worker 代码
# 逻辑：提取 path 第一段作为子域名，拼接 KV 里的动态端口
WORKER_CODE=$(cat <<'EOF'
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  const url = new URL(request.url);
  const pathSegments = url.pathname.split('/').filter(Boolean);
  
  if (pathSegments.length > 0) {
    const targetSubdomain = pathSegments[0]; // 提取 alist 或 fnos
    const targetDomain = await CONFIG.get('domain');
    const targetPort = await CONFIG.get('port');
    
    if (!targetDomain || !targetPort) {
      return new Response("Config missing in KV", { status: 500 });
    }

    // 拼接剩余路径和参数
    const restPath = pathSegments.slice(1).join('/');
    const finalUrl = `https://${targetSubdomain}.${targetDomain}:${targetPort}${restPath ? '/' + restPath : ''}${url.search}`;
    
    return Response.redirect(finalUrl, 302);
  }
  return new Response("Please use https://yourdomain.com/subdomain", { status: 404 });
}
EOF
)

# 推送脚本
echo "$WORKER_CODE" > /tmp/worker.js
METADATA="{\"body_part\":\"script\",\"bindings\":[{\"name\":\"CONFIG\",\"namespace_id\":\"$KV_NAMESPACE_ID\",\"type\":\"kv_namespace\"}]}"
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${RULE_NAME}-redirect" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -F "metadata=${METADATA};type=application/json" \
    -F "script=@/tmp/worker.js;type=application/javascript"

# 设置 DNS 引导记录 (my.liseng.fun)
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    --data "{\"type\":\"A\",\"name\":\"${RULE_NAME}\",\"content\":\"8.8.8.8\",\"proxied\":true}"

# 设置通配符 DNS 记录 (*.liseng.fun 指向当前公网IP，不走代理)
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    --data "{\"type\":\"A\",\"name\":\"*\",\"content\":\"$NEW_IP\",\"proxied\":false}"

log "✅ 智能重定向配置完成！请访问 https://${RULE_NAME}.${DOMAIN}/[子域名]"
