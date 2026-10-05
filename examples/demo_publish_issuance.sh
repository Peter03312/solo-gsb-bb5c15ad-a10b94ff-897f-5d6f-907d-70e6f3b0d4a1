#!/usr/bin/env bash
# 直接发布“签发时刻”端到端示例（仅用 HTTP API，不直连数据库）：
#   相对到期取锁后起算 -> 签出立即可读、响应与落库 expires_at 一致 ->
#   显式未来到期 -> 显式到期已过 422 且不留快照 -> 阅览截止已过 422 且不留快照 ->
#   短窗口首次发布后，再次签发省略时段沿用首次窗口；截止到达后 422、不签新令牌。
#
# 说明：在数据库行锁上等待并跨过到期/截止的确定性竞态，需要一个持有
# sensitive_phrase_settings / snapshots 行锁的并发事务，纯 curl 无法制造；
# 该竞态由集成测试 DirectPublishIssuanceTimeIntegrationTests（真实 PostgreSQL）
# 覆盖。本脚本演示其对外可观察的 API 约定与错误契约。
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v"$1" +%Y-%m-%dT%H:%M:%SZ; }
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }

step "0. 健康检查"
curl -sS "${BASE_URL}/readyz" | jq .

step "1. 维护端创建记录（版本 1）"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
echo "${CREATE}" | jq .
RID=$(echo "${CREATE}" | jq -r .record_id)

step "2. 相对到期 expires_in_seconds=3600：到期从签发时刻（取齐锁后）起算"
PUB=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d '{"version":1,"expires_in_seconds":3600,"max_reads":5}')
echo "${PUB}" | jq '{snapshot_id, version, status, token, expires_at, max_reads}'
SID=$(echo "${PUB}" | jq -r .snapshot_id)
TOKEN=$(echo "${PUB}" | jq -r .token)
EXP_FROM_PUBLISH=$(echo "${PUB}" | jq -r .expires_at)

step "3. 签出后首次公开读取立即可用（旧实现在锁等待耗尽寿命时此处即 403）"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${TOKEN}" \
  | jq '{record_id, version, status, redacted_text}'

step "4. 响应 expires_at 与令牌落库值一致（GET /tokens）"
EXP_FROM_TOKEN=$(curl -sS "${BASE_URL}/tokens/${TOKEN}" "${AUTH[@]}" | jq -r .expires_at)
echo "publish 响应 expires_at = ${EXP_FROM_PUBLISH}"
echo "落库(/tokens) expires_at = ${EXP_FROM_TOKEN}"
[ "${EXP_FROM_PUBLISH}" = "${EXP_FROM_TOKEN}" ] && echo "=> 一致 ✔"

step "5. 显式未来 expires_at：原样采用该绝对时刻"
FUTURE="$(iso '+2 hours')"
curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d "{\"version\":1,\"expires_at\":\"${FUTURE}\"}" \
  | jq '{snapshot_id, token, expires_at}'

step "6. 显式 expires_at 已在过去 -> 422（沿用既有错误，整次拒绝）"
printf 'HTTP %s ' "$(code -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d '{"version":1,"expires_at":"2000-01-01T00:00:00Z"}')"
curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d '{"version":1,"expires_at":"2000-01-01T00:00:00Z"}' | jq -c .

step "7. 阅览截止 window_close_at 已在过去 -> 422（整次拒绝，不留新快照）"
printf 'HTTP %s ' "$(code -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d '{"version":1,"window_open_at":"1999-01-01T00:00:00Z","window_close_at":"2000-01-01T00:00:00Z"}')"
curl -sS -X POST "${BASE_URL}/records/${RID}/publish" "${AUTH[@]}" \
  -d '{"version":1,"window_open_at":"1999-01-01T00:00:00Z","window_close_at":"2000-01-01T00:00:00Z"}' \
  | jq -c .

step "8. 短窗口快照：首次发布携带很快截止的窗口"
CREATE_S=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" \
  -d '{"text":"短窗口记录。","intervals":[]}')
RID_S=$(echo "${CREATE_S}" | jq -r .record_id)
PUB_S=$(curl -sS -X POST "${BASE_URL}/records/${RID_S}/publish" "${AUTH[@]}" -d "{
  \"version\":1,\"max_reads\":5,
  \"window_open_at\":\"$(iso '-10 seconds')\",
  \"window_close_at\":\"$(iso '+3 seconds')\"}")
SID_S=$(echo "${PUB_S}" | jq -r .snapshot_id)
TOKEN_S=$(echo "${PUB_S}" | jq -r .token)
echo "首次发布：$(echo "${PUB_S}" | jq -c '{snapshot_id,window_close_at}')"
printf '窗口内立即读取: HTTP %s\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID_S}?token=${TOKEN_S}")"
echo "等待窗口截止（约 4 秒）……"
sleep 4

step "9. 截止后再次签发（省略时段=沿用首次窗口）-> 422，且不签新令牌"
printf 'HTTP %s ' "$(code -X POST "${BASE_URL}/records/${RID_S}/publish" "${AUTH[@]}" \
  -d '{"version":1}')"
curl -sS -X POST "${BASE_URL}/records/${RID_S}/publish" "${AUTH[@]}" \
  -d '{"version":1}' | jq -c .
echo "该快照仍只有首次发布的一枚令牌（截止后整次拒绝，未签新令牌、未留新快照）："
curl -sS "${BASE_URL}/records/${RID_S}" "${AUTH[@]}" \
  | jq '.snapshots | length as $n | {snapshot_count:$n, window_close_at:.[0].window_close_at}'

step "10. 鉴权约定不变：缺服务密钥 -> 401"
printf 'HTTP %s\n' "$(code -X POST "${BASE_URL}/records/${RID}/publish" \
  -H "Content-Type: application/json" -d '{"version":1}')"

printf '\n\033[1m直接发布签发时刻演示完成。\033[0m\n'
