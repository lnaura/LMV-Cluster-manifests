#!/bin/bash

# ================= 설정 (환경 변수로 대체) =================
# ES_HOST, ES_USER, ES_PASS는 쿠버네티스 Secret을 통해 환경변수로 주입됩니다.
# REPO_NAME은 스냅샷 저장소 이름입니다.
REPO_NAME="s3-repository"
# ========================================================

echo "===================================================="
echo "Starting archive process for warm indices at $(date)"
echo "Target Elasticsearch: $ES_HOST"
echo "===================================================="

# 1. 지정된 모든 패턴의 인덱스 목록을 한 번에 가져오기
# -s: silent 모드, -k: 인증서 검증 스킵
INDEX_LIST=$(curl -s -k -u "$ES_USER:$ES_PASS" "$ES_HOST/_cat/indices/service-topic-*,system-auth-topic-*,system-kmsg-topic-*?h=index")

if [ -z "$INDEX_LIST" ]; then
  echo "✅ No 'service-log-*' indices found. Exiting."
  exit 0
fi

# 2. 각 인덱스를 순회하며 'warm' 단계인지 확인
for INDEX in $INDEX_LIST; do
  echo "🔍 Checking index: $INDEX"
  
  # jq를 사용하여 정확하게 phase 값을 추출
  PHASE=$(curl -s -k -u "$ES_USER:$ES_PASS" "$ES_HOST/$INDEX/_ilm/explain" | jq -r '.indices | .[].phase')
  
  # 3. 'warm' 단계가 아니면 건너뛰기
  if [ "$PHASE" != "warm" ]; then
    echo "  -> Phase is '$PHASE'. Skipping."
    continue
  fi
  
  echo "🔥 Found WARM index: $INDEX. Starting archival process..."
  
  # 날짜와 인덱스 이름을 포함한 스냅샷 이름 생성 (Kubernetes에서 pod 이름이 고유하므로 더 간단하게)
  SNAPSHOT_NAME="snapshot-$(date +%Y%m%d%H%M%S)-${INDEX}"
  
  # 4. 해당 인덱스만 포함하는 스냅샷 생성 (완료될 때까지 대기)
  echo "  -> 📦 Creating snapshot: $SNAPSHOT_NAME in repository '$REPO_NAME'..."
  HTTP_CODE=$(curl -s -k -w "%{http_code}" -o /dev/null -X PUT \
    -u "$ES_USER:$ES_PASS" \
    "$ES_HOST/_snapshot/$REPO_NAME/$SNAPSHOT_NAME?wait_for_completion=true" \
    -H 'Content-Type: application/json' -d"{\"indices\": \"$INDEX\"}")

  # 5. 스냅샷 생성 성공 여부(HTTP 200) 확인
  if [ "$HTTP_CODE" -eq 200 ]; then
    echo "  -> ✅ Snapshot '$SNAPSHOT_NAME' created successfully."
    
    # 6. 스냅샷 성공 시 원본 인덱스 삭제
    echo "  -> 🗑️ Deleting original index: $INDEX..."
    DELETE_RESPONSE=$(curl -s -k -X DELETE -u "$ES_USER:$ES_PASS" "$ES_HOST/$INDEX")
    echo "  -> ✅ Index deletion response: $DELETE_RESPONSE"
  else
    echo "  -> ❌ ERROR: Failed to create snapshot for index '$INDEX'. HTTP code: $HTTP_CODE"
  fi
  echo "----------------------------------------------------"
done

echo "🎉 Archive process finished at $(date)."