#!/bin/bash
# ===========================================================================
# 客户端初始化
#
# 只做两件事：
#   1. 预置一条 hosts 记录（默认注释掉），把桶的访问域名指向接口型终端节点。
#      放开这一行就切到路径二，注释回去就走回路径一 —— 两条路径的切换只差
#      一行 hosts，这正是本实践想说明的事。
#   2. 落一个 obs-check 命令，免得每次手敲请求。
#
# 本脚本是静态文件，不含任何模板占位符。桶名、区域、终端节点地址由 Terraform
# 在 user-data 前缀里写入 /etc/obs-demo/env，本脚本只负责读取。
# ===========================================================================
set -euo pipefail

. /etc/obs-demo/env

# ---------------------------------------------------------------------------
# 路径二的域名指向。默认注释掉：先验证网关型路径，再手动放开做对比。
# ---------------------------------------------------------------------------
if [ "$INTERFACE_PATH_ENABLED" = "true" ] && ! grep -q "obs-demo-interface-path" /etc/hosts; then
  {
    echo "# obs-demo-interface-path: 去掉下一行行首的 # 即切换到接口型终端节点路径"
    echo "#$ENDPOINT_IP $BUCKET_HOST $OBS_DOMAIN"
  } >> /etc/hosts
fi

# ---------------------------------------------------------------------------
# 验证命令
# ---------------------------------------------------------------------------
cat > /usr/local/bin/obs-check <<'CHECK'
#!/bin/bash
# 显示当前生效的访问路径，并实际取一次对象。
set -uo pipefail
. /etc/obs-demo/env

resolved=$(getent ahostsv4 "$BUCKET_HOST" | awk '{print $1; exit}')

echo "桶域名        : $BUCKET_HOST"
echo "当前解析地址  : ${resolved:-解析失败}"
if [ "$resolved" = "$ENDPOINT_IP" ]; then
  echo "生效路径      : 路径二 · 接口型终端节点（经转发节点中转）"
else
  echo "生效路径      : 路径一 · 网关型终端节点（路由注入，直达）"
fi

echo
echo "--- 实例委托 ---"
meta=$(curl -s -m 5 http://169.254.169.254/openstack/latest/securitykey || true)
if [ -z "$meta" ]; then
  echo "临时凭据获取  : 失败，确认云服务器已绑定委托"
  echo "（以下取对象步骤会因无签名而 403，属预期）"
else
  echo "临时凭据获取  : 成功（由委托下发，有效期内自动轮换）"
fi

echo
echo "--- 取一次对象（用委托临时凭据做 SigV4 签名）---"
if [ -n "$meta" ]; then
  # 从元数据取临时凭据
  AK=$(echo "$meta"  | sed -n 's/.*"access"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  SK=$(echo "$meta"  | sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  TK=$(echo "$meta"  | sed -n 's/.*"securitytoken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  OBJECT_KEY="hello.txt"
  CANON_URI="/${OBJECT_KEY}"
  amzdate=$(date -u +%Y%m%dT%H%M%SZ)
  datestamp=$(date -u +%Y%m%d)
  payload_hash=$(printf '' | openssl dgst -sha256 | sed 's/^.*= //')

  canon_headers="host:${BUCKET_HOST}
x-amz-content-sha256:${payload_hash}
x-amz-date:${amzdate}
x-amz-security-token:${TK}
"
  signed_headers="host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
  canon_request="GET
${CANON_URI}

${canon_headers}
${signed_headers}
${payload_hash}"

  creq_hash=$(printf '%s' "$canon_request" | openssl dgst -sha256 | sed 's/^.*= //')
  scope="${datestamp}/${REGION}/obs/aws4_request"
  string_to_sign="AWS4-HMAC-SHA256
${amzdate}
${scope}
${creq_hash}"

  # SigV4 派生签名密钥：每一层都是 HMAC(上一层密钥, 下一层分量)
  #   kDate    = HMAC("AWS4"+SK, 日期)
  #   kRegion  = HMAC(kDate, 区域)
  #   kService = HMAC(kRegion, "obs")
  #   kSigning = HMAC(kService, "aws4_request")
  kDate=$(printf '%s' "$datestamp" | openssl dgst -sha256 -hmac "AWS4${SK}" | sed 's/^.*= //')
  kRegion=$(printf '%s' "$REGION" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$kDate" -binary | od -An -tx1 | tr -d ' \n')
  kService=$(printf '%s' "obs" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$kRegion" -binary | od -An -tx1 | tr -d ' \n')
  kSigning=$(printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$kService" -binary | od -An -tx1 | tr -d ' \n')
  signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$kSigning" | sed 's/^.*= //')

  authz="AWS4-HMAC-SHA256 Credential=${AK}/${scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

  curl -sS -o /tmp/hello.txt \
    -w "HTTP 状态码   : %{http_code}\n对端地址      : %{remote_ip}\n耗时          : %{time_total}s\n" \
    -H "host: ${BUCKET_HOST}" \
    -H "x-amz-content-sha256: ${payload_hash}" \
    -H "x-amz-date: ${amzdate}" \
    -H "x-amz-security-token: ${TK}" \
    -H "Authorization: ${authz}" \
    "https://${BUCKET_HOST}/${OBJECT_KEY}" || true
  echo "--- 对象内容 ---"
  cat /tmp/hello.txt 2>/dev/null || true
else
  echo "（跳过：未取到临时凭据）"
fi

echo
echo "--- 确认没有公网出口 ---"
if curl -s -m 5 -o /dev/null https://www.example.com 2>/dev/null; then
  echo "警告：公网可达。本实践的私有前提被破坏了，检查是否误挂了弹性公网 IP 或 NAT 网关。"
else
  echo "公网不可达，符合预期。"
fi
CHECK
chmod 0755 /usr/local/bin/obs-check

logger -t obs-demo -- "client initialization finished"
