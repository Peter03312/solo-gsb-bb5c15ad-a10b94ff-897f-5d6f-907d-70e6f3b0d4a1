#!/usr/bin/env bash
# 受控申请“提交 vs 批准”同一快照并发：统一锁序（版本行/申请行 → 清单行 → 快照行），
# 交错并发不再数据库死锁，原本合法的双方操作都成功；错误路径与鉴权/公开读取约定不变。
#   先产生同版本快照并备好另一份待审申请
#   -> 后台交错发起「新提交」与「既有待审申请的批准」
#   -> 两者均成功（201 / 200），无 5xx；批准令牌可立即公开读取，新申请保持待审
#   -> 未完整遮蔽短语：提交 422（只回命中码点），无申请/快照/令牌
#   -> 版本原文销毁后：提交 409，无申请残留；已在审申请批准 409、仍可驳回
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator（申请人）
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer（复核人）
CAROL_PW="${CAROL_PW:-carol-pw}"   # operator + reviewer
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "0. 健康检查"
curl -sS "${BASE_URL}/healthz" | jq .

step "1. 创建受控记录（版本 1；停用短语核验以便专注锁序）"
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" -d '{"phrases": []}' >/dev/null
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800138000。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
echo "${CREATE}" | jq .
RID=$(echo "${CREATE}" | jq -r .record_id)
curl -sS -X PUT "${BASE_URL}/records/${RID}/controlled" "${AUTH[@]}" | jq .

step "2. 先批准 PR0 产生同版本快照 S（死锁环的前提是快照行已存在）"
PR0=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1}')
PR0_ID=$(echo "${PR0}" | jq -r .request_id)
APPR0=$(curl -sS -X POST "${BASE_URL}/publish-requests/${PR0_ID}/approve" -u "bob:${BOB_PW}")
echo "${APPR0}" | jq '{request_id, status, snapshot_id, token}'
# 同版本再留一份待审申请 PR1，供下面与 carol 的新提交并发批准
PR1=$(curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1, "max_reads": 5}')
PR1_ID=$(echo "${PR1}" | jq -r .request_id)
echo "待审 PR1: ${PR1_ID}"

step "3. 并发交错：carol 新提交 PR2 与 bob 批准 PR1 —— 旧实现此处会数据库死锁(5xx)"
TMP=$(mktemp -d)
# 新提交（carol，operator；与批准人 bob 不同）
( curl -sS -o "${TMP}/submit.out" -w '%{http_code}' -X POST \
    "${BASE_URL}/records/${RID}/publish-requests" \
    -u "carol:${CAROL_PW}" -H "Content-Type: application/json" \
    -d '{"version": 1}' > "${TMP}/submit.code" ) &
SUBMIT_PID=$!
# 让提交先进入事务再发起批准，形成“同一已存在快照上提交与批准同时持锁”的交错
sleep 0.2
( curl -sS -o "${TMP}/approve.out" -w '%{http_code}' -X POST \
    "${BASE_URL}/publish-requests/${PR1_ID}/approve" -u "bob:${BOB_PW}" \
    > "${TMP}/approve.code" ) &
APPROVE_PID=$!
wait "${SUBMIT_PID}" "${APPROVE_PID}"
printf '提交 HTTP %s；批准 HTTP %s（两者都必须成功，无死锁 5xx）\n' \
  "$(cat "${TMP}/submit.code")" "$(cat "${TMP}/approve.code")"
test "$(cat "${TMP}/submit.code")" = "201"
test "$(cat "${TMP}/approve.code")" = "200"
echo "提交响应:"; cat "${TMP}/submit.out" | jq -c '{request_id,status,version}'
echo "批准响应:"; cat "${TMP}/approve.out" | jq -c '{request_id,status,snapshot_id,token,max_reads}'
SID=$(cat "${TMP}/approve.out" | jq -r .snapshot_id)
TOKEN=$(cat "${TMP}/approve.out" | jq -r .token)
PR2_ID=$(cat "${TMP}/submit.out" | jq -r .request_id)
rm -rf "${TMP}"

step "4. 无冲突约定不变：批准令牌可立即公开读取；新申请保持 pending、可驳回"
curl -sS "${BASE_URL}/public/snapshots/${SID}?token=${TOKEN}" | jq .
curl -sS "${BASE_URL}/publish-requests/${PR2_ID}" -u "alice:${ALICE_PW}" \
  | jq '{request_id, status, snapshot_id}'
curl -sS -X POST "${BASE_URL}/publish-requests/${PR2_ID}/reject" \
  -u "bob:${BOB_PW}" -H "Content-Type: application/json" -d '{"reason":"已有同版本快照"}' \
  | jq '{request_id, status}'

step "5. 短语未完整遮蔽：提交沿用 422（只回未覆盖命中码点），不留申请/快照/令牌"
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" -d '{"phrases": ["患者"]}' >/dev/null
# “患者”命中码点 [0,2)，遮蔽区间从 [2,4) 起：未覆盖
curl -sS -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1}' | jq .
# 申请列表不含被拒绝的新申请
curl -sS "${BASE_URL}/records/${RID}/publish-requests" -u "alice:${ALICE_PW}" \
  | jq '[.requests[] | {request_id, status}]'
curl -sS -X PUT "${BASE_URL}/sensitive-phrases" "${AUTH[@]}" -d '{"phrases": []}' >/dev/null

step "6. 版本原文已销毁：提交 409 且不残留申请；冻结原文被清的待审申请批准 409、仍可驳回"
# 新记录（其快照尚未发布，便于展示销毁后提交/批准均拒绝）
CREATE2=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "待销毁版本的原文，含敏感内容。", "intervals": []
}')
RID2=$(echo "${CREATE2}" | jq -r .record_id)
curl -sS -X PUT "${BASE_URL}/records/${RID2}/controlled" "${AUTH[@]}" >/dev/null
PR3=$(curl -sS -X POST "${BASE_URL}/records/${RID2}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1}')
PR3_ID=$(echo "${PR3}" | jq -r .request_id)
curl -sS -X POST "${BASE_URL}/records/${RID2}/versions/1/destroy-original" "${AUTH[@]}" \
  -d '{"reason":"该历史版本原文不再留存"}' | jq .
printf '销毁后提交: HTTP %s\n' "$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${BASE_URL}/records/${RID2}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1}')"
printf '销毁后批准既有待审申请: HTTP %s（申请保持 pending）\n' "$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${BASE_URL}/publish-requests/${PR3_ID}/approve" -u "bob:${BOB_PW}")"
curl -sS -X POST "${BASE_URL}/publish-requests/${PR3_ID}/reject" \
  -u "bob:${BOB_PW}" -H "Content-Type: application/json" -d '{"reason":"原文已销毁"}' \
  | jq '{request_id, status}'

step "7. 已撤回快照：提交先结算到点计划再 409（以预定时刻与计划原因撤回，不产生申请）"
WHEN=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=2)).isoformat())")
PLAN=$(curl -sS -X POST "${BASE_URL}/snapshot-withdrawal-plans" "${AUTH[@]}" -d "{
  \"snapshot_id\": \"${SID}\", \"scheduled_at\": \"${WHEN}\", \"reason\": \"保留期届满\"
}")
echo "${PLAN}" | jq '{plan_id, status, scheduled_at}'
sleep 2.5  # 等计划到点（后台线程或下方提交的惰性结算都会结算）
printf '对已到点撤回快照提交申请: HTTP %s\n' "$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${BASE_URL}/records/${RID}/publish-requests" \
  -u "alice:${ALICE_PW}" -H "Content-Type: application/json" -d '{"version": 1}')"
curl -sS "${BASE_URL}/records/${RID}" "${AUTH[@]}" \
  | jq '.snapshots[] | {version, status, withdrawn_at, withdraw_reason}'

printf '\n\033[1m提交/批准锁序并发演示完成。\033[0m\n'
