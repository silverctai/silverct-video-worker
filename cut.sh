#!/usr/bin/env bash
# Silver CT 视频工作室：直播按时间段剪辑程序（在 GitHub 免费机器上运行）
# 流程：领取任务 -> 向后台要视频来源 -> 只取指定时间段并剪出（不重新压缩）-> 上传 -> 放入「待审核」
# 本文件不含任何机密：专用密钥来自 GitHub 的加密机密 WORKER_KEY。
set -uo pipefail

SB="https://lxesjhbqntgomixxrwrn.supabase.co"
# 这是 Supabase 的公开「anon」密钥（本来就写在手机页面里，没有任何特权）
ANON="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx4ZXNqaGJxbnRnb21peHhyd3JuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU5NDc1NzIsImV4cCI6MjEwMTUyMzU3Mn0.bfdsObNaE8iwXEp6rTEs-F6CKfIpZSnXESexSIO0M4A"
KEY="${WORKER_KEY:?缺少 WORKER_KEY}"

rpc() { curl -sS --max-time 60 -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" -X POST "$SB/rest/v1/rpc/$1" -d "$2"; }
fn()  { curl -sS --max-time 120 -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json" -X POST "$SB/functions/v1/vs-fb-videos" -d "$1"; }

ensure_ffmpeg() {
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "安装 ffmpeg…"
    sudo apt-get update -y -qq && sudo apt-get install -y -qq ffmpeg
  fi
}

while true; do
  job=$(rpc vs_worker_claim "$(jq -n --arg k "$KEY" '{p_key:$k}')")
  if [ -z "$job" ] || [ "$job" = "null" ]; then echo "没有新任务"; break; fi
  if ! echo "$job" | jq -e .id >/dev/null 2>&1; then echo "领取任务出错：$job" | head -c 300; break; fi

  id=$(echo "$job" | jq -r .id)
  start=$(echo "$job" | jq -r .start_s)
  end=$(echo "$job" | jq -r .end_s)
  dur=$((end - start))
  echo "处理任务 $id：${start}s - ${end}s（共 ${dur} 秒）"

  fail() {
    echo "失败：$1"
    rpc vs_worker_fail "$(jq -n --arg k "$KEY" --arg j "$id" --arg e "$1" '{p_key:$k,p_job:$j,p_err:$e}')" >/dev/null
  }

  src=$(fn "$(jq -n --arg k "$KEY" --arg j "$id" '{action:"worker_source",worker_key:$k,job_id:$j}')")
  url=$(echo "$src" | jq -r '.source // empty' 2>/dev/null)
  if [ -z "$url" ]; then fail "取不到视频来源：$(echo "$src" | jq -r '.error // "未知原因"' 2>/dev/null | head -c 200)"; continue; fi
  echo "已取得视频来源（地址不显示）"

  ensure_ffmpeg
  rm -f out.mp4 thumb.jpg
  # -ss 放在 -i 前面：直接跳到指定位置，只下载需要的那一段；-c copy：不重新压缩，画质不变
  if ! ffmpeg -hide_banner -loglevel error -ss "$start" -i "$url" -t "$dur" -c copy -avoid_negative_ts make_zero -movflags +faststart out.mp4 2> ffmpeg.err; then
    emsg=$(tail -c 400 ffmpeg.err | tr -d '\r' | tr '\n' ' '); emsg=${emsg//"$url"/(来源地址)}
    fail "剪辑失败：${emsg:0:200}"; continue
  fi
  if [ ! -s out.mp4 ]; then fail "剪出来的文件是空的，请检查时间是否在视频长度内"; continue; fi
  size=$(stat -c %s out.mp4); echo "剪辑完成：$((size / 1048576)) MB"

  ffmpeg -hide_banner -loglevel error -ss 1 -i out.mp4 -frames:v 1 -vf scale=360:-2 thumb.jpg 2>/dev/null || ffmpeg -hide_banner -loglevel error -i out.mp4 -frames:v 1 -vf scale=360:-2 thumb.jpg 2>/dev/null || true

  up=$(fn "$(jq -n --arg k "$KEY" --arg j "$id" '{action:"worker_upload",worker_key:$k,job_id:$j,kind:"video"}')")
  su=$(echo "$up" | jq -r '.signedUrl // empty'); vpath=$(echo "$up" | jq -r '.path // empty')
  if [ -z "$su" ]; then fail "拿不到上传地址：$(echo "$up" | jq -r '.error // "未知"' | head -c 200)"; continue; fi
  if ! curl -sS -f --max-time 3000 -X PUT -H "Content-Type: video/mp4" -T out.mp4 "$su" -o up.out 2> up.err; then
    fail "上传失败：$(cat up.err up.out 2>/dev/null | head -c 200)"; continue
  fi

  tpath=""
  if [ -s thumb.jpg ]; then
    tp=$(fn "$(jq -n --arg k "$KEY" --arg j "$id" '{action:"worker_upload",worker_key:$k,job_id:$j,kind:"thumb"}')")
    tsu=$(echo "$tp" | jq -r '.signedUrl // empty'); tpath2=$(echo "$tp" | jq -r '.path // empty')
    if [ -n "$tsu" ] && curl -sS -f --max-time 120 -X PUT -H "Content-Type: image/jpeg" -T thumb.jpg "$tsu" -o /dev/null 2>/dev/null; then tpath="$tpath2"; fi
  fi

  res=$(rpc vs_worker_finish "$(jq -n --arg k "$KEY" --arg j "$id" --arg p "$vpath" --arg t "$tpath" '{p_key:$k,p_job:$j,p_path:$p,p_thumb:(if $t=="" then null else $t end)}')")
  echo "已放入待审核：$res"
done
