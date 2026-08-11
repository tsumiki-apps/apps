#!/usr/bin/env bash
# push_pages.sh — push して GitHub Pages の公開完了まで見届けるスクリプト。
#
# なぜ必要か：
#   GitHub Pages は「同時に1つしか公開作業ができない」。前の公開が走っている最中に
#   次を push すると、後発が deploy 段階で 400 エラーになる（in progress deployment）。
#   それが「その日の最後の push」だと、サイトが古いまま止まる。
#   このスクリプトは push 後に公開結果を見張り、衝突で落ちていたら自動で再実行する。
#
# 使い方：
#   ~/制作物/push_pages.sh                 # 現在のリポジトリで push して見届ける
#   ~/制作物/push_pages.sh origin main     # 引数はそのまま git push に渡る
#
# 環境変数：
#   MAX_RETRY (既定 3)   衝突リトライの上限
#   TIMEOUT   (既定 900) 1回の公開を待つ秒数

set -uo pipefail

MAX_RETRY=${MAX_RETRY:-3}
TIMEOUT=${TIMEOUT:-900}
POLL=5

die() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1"; }
ok() { printf '\033[32m✓ %s\033[0m\n' "$1"; }

command -v gh >/dev/null || die "gh コマンドが見つかりません"
git rev-parse --git-dir >/dev/null 2>&1 || die "git リポジトリの中で実行してください"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
  || die "gh がこのリポジトリを認識できません（gh auth status を確認）"

# --- 1. push -------------------------------------------------------------
info "push 先: ${REPO}"
git push "$@" || die "git push に失敗しました"
SHA=$(git rev-parse HEAD)
SHORT=${SHA:0:7}

# Pages が有効でなければ、ここで終わり（普通の push として成功）
PAGES_URL=$(gh api "repos/${REPO}/pages" --jq .html_url 2>/dev/null)
if [ -z "$PAGES_URL" ]; then
  ok "push 完了（${SHORT}）※このリポジトリは GitHub Pages ではないので見張りはしません"
  exit 0
fi

# --- 2. 自分の push の公開ジョブを探す -----------------------------------
run_field() { # $1=run_id $2=jq field
  gh run view "$1" -R "${REPO}" --json status,conclusion,headSha -q ".$2" 2>/dev/null
}

find_run() {
  gh run list -R "${REPO}" -w pages-build-deployment --limit 15 \
    --json databaseId,headSha -q \
    "[.[] | select(.headSha == \"${SHA}\")] | .[0].databaseId" 2>/dev/null
}

info "公開ジョブの開始を待っています…（${SHORT}）"
RUN_ID=""
for _ in $(seq 1 24); do   # 最大2分
  RUN_ID=$(find_run)
  [ -n "${RUN_ID}" ] && [ "${RUN_ID}" != "null" ] && break
  RUN_ID=""
  sleep $POLL
done

if [ -z "${RUN_ID}" ]; then
  ok "push 完了（${SHORT}）※公開ジョブが見つかりませんでした（変更なし push か、Pages が別経路）"
  info "公開URL: $PAGES_URL"
  exit 0
fi

# --- 3. 完了まで待つ／衝突なら再実行 -------------------------------------
wait_run() { # 完了まで待って conclusion を返す
  local waited=0
  while :; do
    local st; st=$(run_field "${RUN_ID}" status)
    [ "$st" = "completed" ] && { run_field "${RUN_ID}" conclusion; return 0; }
    waited=$((waited + POLL))
    [ $waited -ge "$TIMEOUT" ] && { echo "timeout"; return 0; }
    sleep $POLL
  done
}

for attempt in $(seq 0 "$MAX_RETRY"); do
  [ "$attempt" -gt 0 ] && info "再実行 $attempt 回目…"
  info "公開の完了を待っています…（run ${RUN_ID}）"
  RESULT=$(wait_run)

  if [ "$RESULT" = "success" ]; then
    ok "公開しました（${SHORT}）"
    info "公開URL: $PAGES_URL"
    exit 0
  fi

  if [ "$RESULT" = "timeout" ]; then
    die "公開が ${TIMEOUT}秒 で終わりませんでした → https://github.com/${REPO}/actions/runs/${RUN_ID}"
  fi

  # 失敗の理由を見る
  LOG=$(gh run view "${RUN_ID}" -R "${REPO}" --log-failed 2>/dev/null)
  if ! grep -q "in progress deployment" <<<"$LOG"; then
    printf '\033[31m✗ 公開に失敗（衝突ではない別の原因）\033[0m\n' >&2
    grep -o '##\[error\].*' <<<"$LOG" | head -5 >&2
    die "詳細 → https://github.com/${REPO}/actions/runs/${RUN_ID}"
  fi

  # 衝突。ただし後続 push が既に走っているなら、そちらが最新を配るのでリトライ不要
  LATEST_SHA=$(gh run list -R "${REPO}" -w pages-build-deployment --limit 1 \
    --json headSha -q '.[0].headSha' 2>/dev/null)
  if [ -n "${LATEST_SHA}" ] && [ "${LATEST_SHA}" != "${SHA}" ]; then
    ok "他の公開が後から走っています（${LATEST_SHA:0:7}）→ 古い版を配らないよう再実行はしません"
    exit 0
  fi

  if [ "$attempt" -ge "$MAX_RETRY" ]; then
    die "同時公開の衝突が $MAX_RETRY 回続きました → https://github.com/${REPO}/actions/runs/${RUN_ID}"
  fi

  info "同時公開の衝突で失敗。30秒あけて再実行します"
  sleep 30
  gh run rerun "${RUN_ID}" -R "${REPO}" --failed >/dev/null 2>&1 \
    || die "再実行に失敗しました → https://github.com/${REPO}/actions/runs/${RUN_ID}"
  sleep $POLL
done
