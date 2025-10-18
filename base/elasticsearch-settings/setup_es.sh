#!/bin/sh
    set -ex

    # ❗️❗️ K8s 내부의 Elasticsearch Service 주소로 변경 ❗️❗️
    ES_HOST="https://elasticsearch-master.default.svc.cluster.local:9200"
    
    if [ -z "$ELASTIC_PASSWORD" ]; then
        echo "오류: ELASTIC_PASSWORD 환경 변수가 설정되지 않았습니다."
        exit 1
    fi
    
    AUTH_HEADER="elastic:$ELASTIC_PASSWORD"
    # -I (HEAD), -s(silent), -f(fail fast), -k(insecure)
    CURL_CMD="curl -s -f -k -u $AUTH_HEADER"

    # --- 1~3단계는 멱등성이 보장되므로 그대로 둡니다 (PUT) ---
    echo "=== [1/4] ILM 정책 생성 시작: ilm-policy ==="
    $CURL_CMD -X PUT "$ES_HOST/_ilm/policy/ilm-policy" -H 'Content-Type: application/json' -d'
    { "policy": {"phases": {"hot": {"min_age": "0ms", "actions": {"rollover": {"max_age": "1d"}}}, "warm": {"min_age": "3d", "actions": {}}}} }'
    
    echo "=== [2/4] Ingest Pipeline 생성 시작 ==="
    $CURL_CMD -X PUT "$ES_HOST/_ingest/pipeline/service_pipeline" -H 'Content-Type: application/json' -d'
    { "description": "서비스 로그 처리", "processors": [{"date": {"field": "timestamp", "formats": ["strict_date_optional_time"], "target_field": "@timestamp", "ignore_failure": true}}, {"convert": {"field": "result", "type": "integer", "ignore_missing": true, "ignore_failure": true}}, {"convert": {"field": "sourceIP", "type": "ip", "ignore_missing": true, "ignore_failure": true}}, {"rename": {"field": "API", "target_field": "api", "ignore_missing": true, "ignore_failure": true}}, {"set": {"if": "ctx.result >= 500 && ctx.result < 600", "field": "is_error", "value": true}}] }'
    
    $CURL_CMD -X PUT "$ES_HOST/_ingest/pipeline/system_auth_pipeline" -H 'Content-Type: application/json' -d'
    { "processors": [{"date": {"field": "timestamp", "formats": ["yyyy-MM-dd HH:mm:ss.SSSSSSXXX"], "timezone": "Asia/Seoul", "target_field": "@timestamp", "ignore_failure": true}}, {"convert": {"field": "port", "type": "integer", "ignore_missing": true, "ignore_failure": true}}, {"convert": {"field": "pid", "type": "integer", "ignore_missing": true, "ignore_failure": true}}, {"remove": {"field": "timestamp", "ignore_failure": true}}, {"geoip": {"field": "ip", "target_field": "geoip", "ignore_failure": true}}] }'

    $CURL_CMD -X PUT "$ES_HOST/_ingest/pipeline/system_kmsg_pipeline" -H 'Content-Type: application/json' -d'
    { "description": "system-kmsg 로그 처리", "processors": [{"set": {"field": "@timestamp", "value": "{{_ingest.timestamp}}"}}, {"script": {"lang": "painless", "ignore_failure": true, "source": "if (ctx[\"@timestamp\"] != null) { def zdt = ZonedDateTime.parse(ctx[\"@timestamp\"].toString()); def kst = zdt.withZoneSameInstant(ZoneId.of(\"Asia/Seoul\")); ctx[\"@timestamp_kst\"] = kst.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME); }"}}, {"rename": {"field": "timestamp", "target_field": "kmsg_timestamp", "ignore_failure": true}}, {"convert": {"field": "priority", "type": "integer", "ignore_failure": true}}, {"convert": {"field": "facility", "type": "integer", "ignore_failure": true}}, {"convert": {"field": "seq", "type": "integer", "ignore_failure": true}}] }'
    
    echo "=== [3/4] 인덱스 템플릿 생성 시작 ==="
    $CURL_CMD -X PUT "$ES_HOST/_index_template/service_index_template" -H 'Content-Type: application/json' -d'
    { "index_patterns": ["service-topic*"], "template": {"settings": {"index.lifecycle.name": "ilm-policy", "index.lifecycle.rollover_alias": "service-topic", "index.default_pipeline": "service_pipeline"}} }'

    $CURL_CMD -X PUT "$ES_HOST/_index_template/system_auth_index_template" -H 'Content-Type: application/json' -d'
    { "index_patterns": ["system-auth-topic*"], "template": {"settings": {"index.lifecycle.name": "ilm-policy", "index.lifecycle.rollover_alias": "system-auth-topic", "index.default_pipeline": "system_auth_pipeline"}, "mappings": {"properties": {"geoip": {"properties": {"location": {"type": "geo_point"}}}}}} }'

    $CURL_CMD -X PUT "$ES_HOST/_index_template/system_kmsg_index_template" -H 'Content-Type: application/json' -d'
    { "index_patterns": ["system-kmsg-topic*"], "template": {"settings": {"index.lifecycle.name": "ilm-policy", "index.lifecycle.rollover_alias": "system-kmsg-topic", "index.default_pipeline": "system_kmsg_pipeline"}} }'

    echo "=== [4/4] 최초 인덱스 및 쓰기 별칭(Alias) 생성 (Idempotent Check) ==="
    
    # 1. service-topic: 별칭이 존재하지 않으면(-f 플래그가 404를 반환하면) 생성
    if ! $CURL_CMD -I "$ES_HOST/_alias/service-topic" > /dev/null 2>&1; then
      echo "  > 'service-topic' 별칭이 없으므로, 'service-topic-000001'을(를) 생성합니다..."
      $CURL_CMD -X PUT "$ES_HOST/service-topic-000001" -H 'Content-Type: application/json' -d'
      { "aliases": { "service-topic": { "is_write_index": true } } }
      '
    else
      echo "  > 'service-topic' 별칭이 이미 존재합니다. (Skip)"
    fi
    
    # 2. system-auth-topic
    if ! $CURL_CMD -I "$ES_HOST/_alias/system-auth-topic" > /dev/null 2>&1; then
      echo "  > 'system-auth-topic' 별칭이 없으므로, 'system-auth-topic-000001'을(를) 생성합니다..."
      $CURL_CMD -X PUT "$ES_HOST/system-auth-topic-000001" -H 'Content-Type: application/json' -d'
      { "aliases": { "system-auth-topic": { "is_write_index": true } } }
      '
    else
      echo "  > 'system-auth-topic' 별칭이 이미 존재합니다. (Skip)"
    fi

    # 3. system-kmsg-topic
    if ! $CURL_CMD -I "$ES_HOST/_alias/system-kmsg-topic" > /dev/null 2>&1; then
      echo "  > 'system-kmsg-topic' 별칭이 없으므로, 'system-kmsg-topic-000001'을(를) 생성합니다..."
      $CURL_CMD -X PUT "$ES_HOST/system-kmsg-topic-000001" -H 'Content-Type: application/json' -d'
      { "aliases": { "system-kmsg-topic": { "is_write_index": true } } }
      '
    else
      echo "  > 'system-kmsg-topic' 별칭이 이미 존재합니다. (Skip)"
    fi

    echo "=== [4/4] 최초 인덱스/별칭 작업 완료 ==="
    echo "🎉 Elasticsearch 초기 설정이 모두 완료되었습니다."