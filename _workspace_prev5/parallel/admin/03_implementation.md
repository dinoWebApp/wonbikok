# 03_implementation.md — 관리자 A0·A1·A2·A3 (병렬 태스크 admin)

- 작성일: 2026-11-18
- 태스크: W4 병렬 배치 `admin` (f7·f8 동시 진행, 01_plan.md §1 소유권 준수)
- 레퍼런스: PRD 11.3(환불)·12장 A0~A3·15장·22장(ADM-001/002, TEN-001/003) / 01_plan §2(Subscription 고정 가정)
- **테스트 실행은 3-S 이후**(마이그레이션·routes·ko.yml·f8 Subscription 병합 전제) — 본 태스크는 작성·정적 검증만

## 1. 생성 파일 목록 (소유권 화이트리스트 내 전부)

| 레이어 | 파일 |
|---|---|
| 모델 | `app/models/admin_user.rb` · `app/models/audit_log.rb` |
| 서비스 | `app/services/admin/otp_service.rb` · `tenant_search_service.rb` · `timeline_service.rb` · `refund_policy_service.rb` |
| 컨트롤러 | `app/controllers/admin/base_controller.rb` · `sessions_controller.rb` · `dashboards_controller.rb` · `tenants_controller.rb` · `tenant_actions_controller.rb` · `subscription_payments_controller.rb` |
| 뷰 | `app/views/layouts/admin.html.erb` · `app/views/admin/sessions/{new,otp}.html.erb` · `app/views/admin/dashboards/show.html.erb` · `app/views/admin/tenants/{index,show,_timeline}.html.erb` · `app/views/admin/subscription_payments/{index,refund_new}.html.erb` |
| 테스트 | `test/models/admin_user_test.rb` · `test/services/admin/{otp,tenant_search,timeline,refund_policy}_service_test.rb` · `test/controllers/admin/{sessions,dashboards,tenants,tenant_actions,subscription_payments}_controller_test.rb` |

## 2. 구현 범위 요약

### A0 공통 기반
- **AdminUser**: email(유니크·정규화)·has_secure_password·otp_secret(평문 사전 공유 시크릿)·failed_attempts·locked_at. 실패 **5회(1·2단계 합산) 잠금**, 잠긴 계정은 카운트 미가산, 해제는 `AdminUser#unlock!` 콘솔 전용(UI 경로 없음 — A0 1인 운영).
- **Admin::OtpService**: RFC 6238(TOTP) 젬 없는 구현 — HMAC-SHA1·30초 스텝·6자리·Base32 직접 디코드, ±1스텝(90초) 시계 오차 허용, `secure_compare` 타이밍 방어. 시크릿: `otp_secret` 컬럼 우선 → 미설정 시 `credentials.dig(:admin, :otp_seed)`에서 계정별 파생(HMAC(seed, email)). **credentials 미설정 시 개발 폴백 고정값 + 경고 로그**(운영 배포 전 otp_seed 설정 필수 — 로그에 명시). `current_code`는 콘솔 확인용(화면·로그 노출 금지).
- **로그인 2단계**: 1단계 email+password → 세션 예비 키(`admin_pending_user_id`) → 2단계 OTP → 세션 `admin_user_id`(원장 앱 `session_id`·`user_id`와 별도 키, 인증 체계 분리 — `Admin::BaseController`는 `ActionController::Base` 직계로 Authentication concern 미포함). rate_limit 10회/3분(원장 세션 패턴 준용).
- **AuditLog**: admin_user(optional)·action·target_type/target_id·reason·detail(json)·created_at. `AuditLog.record!` 통합 진입점. **ADM-001 2차 방어**: 파괴적 조치 액션(plan_changed/trial_extended/tenant_suspended/tenant_resumed/refund_confirmed)은 reason 없이 생성 거부(1차 강제는 조치 컨트롤러). 로그인/실패/잠금/열람(logout 포함) 감사 기록.
- **BaseController**: `require_admin!`·마스킹 helper(ADM-002: 휴대폰 `010-****-1234`·사업자번호 `123-**-***90`·이메일·이름)·`prepare_tenant_show!`(show 데이터 조립 — Tenants#show와 조치 422 재렌더 공용)·`log_admin_action!`.
- **레이아웃**: `admin.html.erb` 데스크톱 우선(사이드바+넓은 표), 사이드바 **8항목(A1~A7·A9) 중 A1·A2·A3만 활성**, 나머지 비활성("준비 중") 표시. A8(공지·FAQ)은 항목에서 제외(9화면 중 8개 표시 — 3-S에서 조정 가능). 미인증 시 사이드바 숨김·중앙 카드. `noindex` 메타.

### A1 운영 대시보드 (`dashboards#show`)
- 오늘의 운영 상태(실시간): 최근 24h 발송 실패(MessageLog FAILED·updated_at 기준)·24h 발행 실패(CashReceipt failed)·처리중(processing)·취소 대기(cancel_pending).
- 지표 카드(**산식 화면 명시** — A1 수용조건): MAU 근사=최근 30일 세션 생성 수(distinct user) / 체험 만료 D-7=`subscription.trial_expiring?(days: 7)` / 유료 전환율=active/(trial+active) % / 월 해지=당월 cancelled(updated_at 근사 — 화면 산식 표기).
- 추이: 숫자 표(최근 7일 일별 발송·발행 생성 건수) — 차트 라이브러리 없음(01_plan §7 후속).
- 대응 대기 큐: past_due(테넌트 링크 최대 10건, A3 드릴다운)·발행 실패 방치(failed 24시간 경과 — A5 미구현 안내 표시).
- 외부 서비스 배너: 솔라피/포트원/바로빌 **SIMULATED(미확인) 고정** — 실핑 금지, 플레이스홀더 구조.

### A2 이용자 관리 (`tenants#index·#show` + `tenant_actions`)
- **TenantSearchService**: 통합 검색 상호·사업자번호 부분 일치 + ID 완전 일치(숫자 OR 결합), **LIKE 와일드카드 이스케이프 + `ESCAPE '\'`**(SQLite 기본 이스케이프 없음 — 러너 검증 완료).
- index: 마스킹 표시(ADM-002·TEN-003)·플랜/상태 배지·원생 수·가입일, 100건 제한.
- show: 기본 정보(마스킹)·플랜·체험 잔여일(f8 `trial_remain_days`)·원생 수/상한(f8 `students_limit` — 체험 중 스탠다드 개방 반영)·마지막 활동(로그인·발송·발행)·당월 요약·**TimelineService 전사정 타임라인**(가입/온보딩 상태/subscription_events/message_logs/cash_receipts/audit_logs 시간 역순 병합). **열람 자체 audit `personal_info_viewed`**(A0).
- **TenantActionsController(ADM-001 사유 필수 전부)**:
  - 플랜 수동 변경: **f8 도메인 서비스 경유**(`Subscriptions::PlanChangeService.change!` — 상향/체험 즉시 적용·하향 익월 대기 규약 준수, operated_by=관리자 이메일). 성공/대기(pending) 안내 구분 + audit. 허용값 외·동일 플랜·구독 부재 → 422(서비스 reject 키 매핑).
  - 체험 연장: 1~30일, **누적 60일 상한**(누적은 본 조치 audit detail.days 합산). `trial_ends_at` = max(현 trial_ends_at, 오늘)+days. `trial_extended` 이벤트(f8 enum 추가 필요 — §6.3) + audit. 대상 상태: trial/past_due/suspended.
  - 정지/해제: **v1.0 이력 기록만**(아래 축소 목록) — audit `tenant_suspended/tenant_resumed` + `suspended` 이벤트(detail JSON·operated_by — f8 장부 규약). f8 `RetryPolicyService#suspend!`는 past_due 전이 전용(SUB-002)이라 관리자 기록은 직접 생성(f8 서비스들과 동일 생성 패턴). 상세 화면에 "정지 기록" 배지.
- 실패 시 `admin/tenants/show` 422 재렌더(Turbo 규약) — flash.alert로 사유 안내.

### A3 구독·결제 관리 (`subscription_payments#index·refund_new·refund`)
- 결제 이력: subscription_events(manual_payment/payment_failed/retry/refund) **월 기간+유형 필터**, 최신순 200건, 테넌트 링크, 비고는 detail JSON에서 사유 추출.
- 실패 모니터링: past_due 목록 + **데이터 삭제 예정 D+30 카운트다운** — 산식은 **f8 `Subscriptions::RetryPolicyService.data_retention_deadline` 단일 경유**(최근 past_due 이벤트 + 30일; 이벤트 부재 시 subscription.updated_at 근사, 화면 명시).
- 환불: **RefundPolicyService 정책 분기 3종**(PRD 11.3) — 서비스 귀책 전액 / 이용자 귀책 월 결제 규정문구 고지(자동 산정 없음·기본 0, 보수적 운영) / 기간제 잔여 일할(`amount × 잔여일 ÷ 기간일`, 정수 절삭). 확정 시 `refund` 이벤트(f8이 "기록 타입만 정의"로 남긴 경로 — 직접 생성, detail JSON에 사유·분기·정책 근거, operated_by) + audit `refund_confirmed`. 기본 금액=최근 manual_payment 금액.
- 매출 집계: 최근 6개월 manual_payment 월별 합계(MRR 근사 — 산식 화면 명시).

## 3. 검증 결과 (자기 파일)

- `ruby -c` 전체 22개 Ruby 파일 통과.
- `bin/rubocop` 자기 파일(.rb 22개) **0 위반**(omakase). — 참고: .html.erb는 프로젝트 rubocop 대상 아님(기존 application.html.erb도 대상 외 확인).
- ERB 컴파일 검증: `ActionView` handler로 관리자 템플릿 9종 + 기존 application 레이아웃 기준선 **10종 전부 컴파일 성공**(nesting quote 오류 1건 발견→수정).
- 러너 스모크(개발 DB, 테이블 존재 범위 내):
  - TOTP **RFC 6238 부록 B 벡터 일치**(Time.at(59)→287082), ±1스텝 허용·2스텝 거부·잘못 코드 거부·Base32 파생 32자.
  - 환불 정책: 전액 300,000 / 일할 154,838(300,000×16/31 절삭) / 이용자 귀책 0 / 미정의 분기 ArgumentError.
  - 검색: 상호·사업자번호·ID 일치, `%%` 패턴 주입 미매칭, `%`·`_` 리터럴 매칭(ESCAPE '\' 수정 후).
  - 마스킹 출력 5종(테스트 기대값과 일치).
  - **문서화 예정 routes로 14개 헬퍼 생성 검증**(아래 §6 라우트 블록 그대로 isolated RouteSet에서 `new_admin_session_path`~`refund_admin_subscription_payments_path` 전부 확인).
- 발견→수정 버그: (1) HMAC 키가 바이트 배열로 전달(Ruby 4.0 OpenSSL TypeError)→`pack("C*")`, (2) 레이아웃 ERB 속성 내 이중 따옴표 충돌→단일 따옴표, (3) SQLite LIKE 이스케이프 무시→`ESCAPE '\'`.
- **f8 실구현 정렬 후 재검증 완료**: 작업 종료 시점에 f8 모델·서비스가 병합되어 §6.3 표 대로 admin 파일을
  실 시그니처에 맞춰 수정 → `ruby -c` 전체·`bin/rubocop` 0(22파일)·ERB 컴파일 9종 재통과.

## 4. v1.0 축소·후속 목록 (명시 — 01_plan §7·PRD 대조)

1. **휴대폰번호 검색 미지원**: users.phone_number encrypts 저장(부분 일치 불가) + phone_last4 보조 컬럼 부재 → 상호·사업자번호·ID만. 후속: 검색용 인덱스 컬럼.
2. **계정 정지 실차단 없음**: tenant.status·users 차단 플래그 부재 → 정지/해제는 audit+이벤트 기록만. A2 수용조건의 "원장 안내문 전달·로그인 차단"은 후속.
3. **환불 실이체 없음**: 기록(이벤트+audit)까지. 이체·구독 상태 즉시 반영·확인 알림톡(PRD 11.3/A3 수용조건) 후속.
4. **A1 외부 서비스 상태**: SIMULATED 고정(실핑 금지) — 실측 배너·장애 감지 후속.
5. **A1 추이 그래프**: 숫자 표 대체(계획된 축소) / MAU 외 활성화 깔때기·MRR 카드 미포함(지표 산식 데이터 부족 — 후속).
6. **체험 만료 D-7 알림 발송 여부 표시(A2)**: 이벤트 타입 미확정으로 미표시 — 후속.
7. **A2 데이터 내보내기**: 미구현(계획된 후속).
8. **월 해지 산식**: 전환 시점 미기록 → updated_at 근사(화면 명시).
9. **온보딩 완료 시점**: 미기록 → 가입 시점 앵커 "현재 상태" 항목.
10. 사이드바 8항목: A8(공지·FAQ) 미표시.

## 5. ko.yml 키 (3-S에서 `ko:` 하위 `admin:` 블록 병합 — 코드에서 사용한 전체)

```yaml
  admin:
    layout:
      title: "원비콕 운영 콘솔"
      subtitle: "운영자 전용"
      nav_aria: "관리자 메뉴"
    nav:
      dashboard: "운영 대시보드"
      tenants: "이용자 관리"
      subscription_payments: "구독·결제"
      messages: "알림톡 발송 관리"
      cash_receipts: "현금영수증 발행 관리"
      batches: "배치 작업 제어"
      support: "CS 문의 관리"
      settings: "운영 설정"
      coming_soon: "준비 중"
    sessions:
      title: "관리자 로그인"
      subtitle: "1단계: 이메일·비밀번호 확인"
      email: "이메일"
      password: "비밀번호"
      next_step: "다음(OTP 단계)"
      lock_hint: "로그인 5회 실패 시 계정이 잠깁니다. 해제는 서버 콘솔에서만 가능합니다."
      otp_title: "2단계 인증"
      otp_description: "%{email} 계정의 인증 앱에서 현재 6자리 코드를 입력해 주세요."
      otp_code: "인증 코드(6자리)"
      sign_in: "로그인"
      back_to_step1: "1단계로 돌아가기"
      invalid_credentials: "이메일 또는 비밀번호가 올바르지 않습니다."
      invalid_otp: "인증 코드가 올바르지 않습니다."
      locked_notice: "실패 횟수 초과로 계정이 잠겼습니다. 콘솔에서 해제 후 다시 시도해 주세요."
      session_expired: "인증 단계가 만료되었습니다. 다시 로그인해 주세요."
      login_required: "관리자 로그인이 필요합니다."
      signed_in: "로그인되었습니다."
      signed_out: "로그아웃되었습니다."
      sign_out: "로그아웃"
    dashboard:
      title: "운영 대시보드"
      services_label: "외부 서비스 상태"
      view_list: "목록 보기"
      ops_status:
        title: "오늘의 운영 상태(최근 24시간 — 실시간)"
        message_failed_24h: "발송 실패(24시간)"
        receipt_failed_24h: "발행 실패(24시간)"
        receipt_processing: "발행 처리중"
        receipt_cancel_pending: "발행 취소 대기"
      metrics:
        title: "핵심 지표"
        mau: "MAU(근사)"
        trial_d7: "체험 만료 D-7 예정"
        paid_conversion: "유료 전환율"
        monthly_cancellations: "월 해지"
      formulas:
        mau: "산식: 최근 30일 세션 생성 수(로그인 세션 기준)"
        trial_d7: "산식: 체험 중 구독 중 trial_ends_at이 7일 이내 도래"
        paid_conversion: "산식: active ÷ (trial + active), 소수점 반올림 %"
        monthly_cancellations: "산식: 당월 내 cancelled 상태로 관측된 구독 수(전환 시점 미기록 — updated_at 근사)"
        past_due: "산식: 현재 past_due 상태 구독 수"
        stale_receipt_failures: "산식: failed 상태로 24시간 이상 경과한 현금영수증 건수"
      trend:
        title: "발송·발행 추이(최근 7일 — 생성 건수)"
        date: "날짜"
        messages: "발송"
        receipts: "발행"
      queues:
        title: "대응 대기 큐"
        past_due: "결제 실패 방치(past_due)"
        stale_receipt_failures: "발행 실패 방치"
        go_a3: "구독·결제 관리에서 보기(A3)"
        a5_not_ready: "A5(현금영수증 발행 관리)는 미구현 — 후속 화면에서 처리"
      services:
        solapi: "솔라피"
        portone: "포트원"
        barobill: "바로빌"
      service_states:
        simulated: "SIMULATED(미확인)"
    tenants:
      index:
        title: "이용자(원장) 관리"
        search_scope: "검색 대상: 상호 · 사업자등록번호 · 교습소 ID (휴대폰번호 검색은 후속)"
        search_placeholder: "상호 / 사업자번호 / ID"
        search: "검색"
        no_results: "'%{query}' 검색 결과가 없습니다."
        empty: "등록된 이용자가 없습니다."
        col_id: "ID"
        col_name: "상호"
        col_owner: "원장명"
        col_business_number: "사업자번호"
        col_phone: "휴대폰번호"
        col_plan: "플랜·상태"
        col_students: "원생 수"
        col_joined: "가입일"
        no_subscription: "구독 없음"
        mask_notice: "개인정보는 기본 마스킹되어 표시됩니다(ADM-002)."
      show:
        title: "%{name}"
        tenant_id: "교습소 ID %{id}"
        suspension_recorded: "정지 기록"
        back_to_index: "목록으로"
        basic_info: "기본 정보"
        owner_name: "원장명"
        owner_phone: "휴대폰번호"
        business_number: "사업자번호"
        business_email: "사업자 이메일"
        joined_at: "가입일시"
        onboarding: "온보딩"
        onboarding_done: "완료"
        onboarding_step: "%{step}/%{final} 단계 진행중"
        subscription: "플랜·구독"
        plan: "플랜"
        subscription_status: "구독 상태"
        trial_remain: "체험 잔여일"
        trial_days: "%{days}일"
        students_limit: "원생 수 / 상한"
        period: "현재 기간"
        no_subscription: "구독 레코드가 없습니다."
        activity: "마지막 활동·당월 요약"
        last_login: "마지막 앱 접속"
        last_message: "마지막 발송"
        last_receipt: "마지막 발행"
        month_summary: "당월 요약"
        month_messages: "발송 %{count}건"
        month_receipts: "발행 %{count}건"
        month_formula: "산식: 당월(초일 이후) 발송 성공·대체·연습 기록 합계 / issued 상태 발행 합계"
        actions:
          title: "조치(사유 필수 — 모든 조치는 감사 로그에 영구 보존)"
          change_plan: "플랜 수동 변경"
          extend_trial: "체험 연장"
          extend_trial_hint: "1회 최대 30일 · 누적 60일"
          suspend: "정지 기록"
          suspend_hint: "v1.0은 이력 기록만(실제 로그인 차단은 후속)"
          resume: "정지 해제 기록"
    actions:
      reason_placeholder: "조치 사유를 입력해 주세요(필수)"
      notices:
        plan_changed: "플랜을 %{plan}(으)로 변경했습니다."
        plan_change_scheduled: "플랜 하향이 다음 결제 기간부터 적용 예정입니다(익월 적용 규칙)."
        trial_extended: "체험을 %{days}일 연장했습니다."
        suspend_recorded: "정지 조치를 기록했습니다."
        resume_recorded: "정지 해제를 기록했습니다."
      errors:
        reason_required: "조치 사유는 필수입니다."
        invalid_plan: "플랜 값이 올바르지 않거나 구독 상태가 변경 불가입니다."
        no_subscription: "구독 레코드가 없는 이용자입니다."
        invalid_days: "연장 일수는 1~30일이어야 합니다."
        not_extendable: "체험 연장 대상 상태가 아닙니다(trial·past_due·suspended만 가능)."
        extension_cap: "누적 연장 한도 초과입니다(사용 %{used}일 / 한도 %{cap}일)."
    subscription_statuses:
      plan:
        light: "라이트"
        standard: "스탠다드"
      status:
        trial: "체험"
        active: "활성"
        past_due: "결제 유예"
        suspended: "일시정지"
        cancelled: "해지"
    subscription_payments:
      index:
        title: "구독·결제 관리"
        history_title: "결제 이력"
        no_events: "해당 조건의 결제 이력이 없습니다."
        col_at: "일시"
        col_tenant: "이용자"
        col_plan: "플랜"
        col_status: "구독 상태"
        col_type: "구분"
        col_amount: "금액"
        col_note: "비고"
        past_due_title: "결제 실패 모니터링(일시정지 도달 이용자)"
        past_due_formula: "데이터 삭제 예정 = 최근 past_due 전환 시점 + %{days}일(이벤트 부재 시 갱신시각 근사)"
        no_past_due: "결제 유예 이용자가 없습니다."
        days_left: "삭제 예정 D-%{days}"
        deadline: "삭제 예정일: %{date}"
        revenue_title: "매출 집계(월별)"
        revenue_formula: "산식: 월별 manual_payment 이벤트 합계(수동 결제 기록 기준 — MRR 근사, 실결제 연동 전)"
        col_month: "월"
        col_revenue: "매출"
      filter:
        all: "전체"
        apply: "조회"
      event_types:
        manual_payment: "수동 결제"
        payment_failed: "결제 실패"
        retry: "재시도"
        refund: "환불"
      refund:
        title: "환불 접수"
        target: "대상: %{name}"
        back_to_index: "목록으로"
        branch: "정책 분기"
        amount: "환불 금액(원)"
        amount_hint: "기본값은 최근 수동 결제 금액입니다. 운영자 확정값을 입력해 주세요."
        reason: "환불 사유(필수)"
        confirm: "환불 확정(기록)"
        external_notice: "실제 이체는 외부 처리 대상입니다 — 본 화면은 기록만 남깁니다(v1.0)."
        history_title: "환불 이력(최근 10건)"
        no_history: "환불 이력이 없습니다."
      notices:
        refund_recorded: "환불을 기록했습니다. 실제 이체는 별도 처리 대상입니다."
      errors:
        no_subscription: "구독 레코드가 없는 이용자입니다."
        invalid_branch: "정책 분기 값이 올바르지 않습니다."
        invalid_amount: "환불 금액은 0 이상이어야 합니다."
    refund:
      branches:
        service_fault: "서비스 귀책(전액)"
        user_fault_monthly: "이용자 귀책(월 결제)"
        annual_proration: "기간제 결제(잔여 일할)"
      policies:
        service_fault: "서비스 귀책(결제 오류·발행 불능 등) — 결제 금액 전액 환불(PRD 11.3)."
        user_fault_monthly: "이용자 귀책 월 결제 — 당월 내 환불 규정을 문구로 고지 후 확정(법률 검토 전 보수적 운영: 자동 산정 없음, 기본 0원)."
        annual_proration: "기간제 결제 — 잔여 기간 일할 환불. 금액 = 결제금 × 잔여일 ÷ 기간일(정수 절삭)."
      prorated_detail: "기간 %{period_days}일 중 잔여 %{remaining_days}일 기준"
    timeline:
      title: "이벤트 타임라인(전사정 — 최신순)"
      empty: "표시할 이벤트가 없습니다."
      privacy_notice: "개인정보는 마스킹·식별자 수준만 표시합니다(ADM-002). 온보딩 완료 시점은 미기록으로 가입 시점 항목에 현재 상태 병기(v1.0)."
      kinds:
        tenant_created: "가입"
        onboarding_state: "온보딩 현재 상태"
      subscription_events:
        trial_started: "체험 시작"
        manual_payment: "수동 결제"
        payment_failed: "결제 실패"
        retry: "결제 재시도"
        past_due: "결제 유예 전환"
        suspended: "서비스 일시정지"
        plan_changed: "플랜 변경(관리자)"
        refund: "환불 기록"
        trial_extended: "체험 연장(관리자)"
      message_templates:
        invoice_notice: "납부 안내 발송"
        reminder_d3: "리마인더 D-3 발송"
        reminder_d7: "리마인더 D-7 발송"
        reminder_month_end: "월말 리마인더 발송"
        cash_receipt_issued: "현금영수증 발행 안내 발송"
        cash_receipt_failed: "현금영수증 실패 알림 발송"
      cash_receipt_states:
        needs_info: "현금영수증 정보 미비"
        pending: "현금영수증 발행 대기"
        processing: "현금영수증 발행 처리중"
        issued: "현금영수증 발행 완료"
        failed: "현금영수증 발행 실패"
        cancel_pending: "현금영수증 취소 요청중"
        cancelled: "현금영수증 취소 완료"
    audit:
      actions:
        login: "관리자 로그인"
        logout: "관리자 로그아웃"
        login_failure: "관리자 로그인 실패"
        account_locked: "관리자 계정 잠금"
        personal_info_viewed: "이용자 정보 열람"
        plan_changed: "플랜 수동 변경"
        trial_extended: "체험 연장"
        tenant_suspended: "계정 정지 기록"
        tenant_resumed: "계정 정지 해제 기록"
        refund_confirmed: "환불 확정 기록"
```

## 6. 3-S 전달 사항

### 6.1 마이그레이션 (integ가 1회 생성 — 스펙)

```ruby
# db/migrate/xxxx_create_admin_users_and_audit_logs.rb (예시 — integ에서 작성)
class CreateAdminUsersAndAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_users do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :otp_secret            # 사전 공유 TOTP 시크릿(평문 — 화면·로그 노출 금지, ADM-002)
      t.integer :failed_attempts, default: 0, null: false
      t.datetime :locked_at
      t.timestamps
    end
    add_index :admin_users, :email, unique: true

    create_table :audit_logs do |t|
      t.references :admin_user, null: true # 로그인 실패 등 계정 미확인 기록 허용
      t.string :action, null: false
      t.string :target_type
      t.integer :target_id
      t.text :reason
      t.json :detail                       # SQLite json(Hash 저장 — days·branch·amount 등)
      t.timestamps
    end
    add_index :audit_logs, [ :target_type, :target_id ]
    add_index :audit_logs, [ :action, :created_at ]
  end
end
```
(subscriptions·subscription_events는 f8/기존 계획대로 — 아래 6.3 대조)

### 6.2 routes (`config/routes.rb` 결선 — 그대로 붙여도 동작 검증 완료)

```ruby
  # 관리자 콘솔 (W4 A1~A3 — 별도 인증 체계, 운영 배포 시 서브도메인 격리 가능 구조)
  namespace :admin do
    root to: "dashboards#show"
    get "dashboard", to: "dashboards#show", as: :dashboard
    resource :session, only: %i[new create destroy]
    post "session/otp", to: "sessions#create_otp", as: :session_otp
    resources :tenants, only: %i[index show]
    post "tenants/:tenant_id/change_plan", to: "tenant_actions#change_plan", as: :tenant_change_plan
    post "tenants/:tenant_id/extend_trial", to: "tenant_actions#extend_trial", as: :tenant_extend_trial
    post "tenants/:tenant_id/suspend", to: "tenant_actions#suspend", as: :tenant_suspend
    post "tenants/:tenant_id/resume", to: "tenant_actions#resume", as: :tenant_resume
    resources :subscription_payments, only: :index do
      collection do
        get :refund_new
        post :refund
      end
    end
  end
```
(헬퍼 14종 생성 isolated 검증 완료: `new_admin_session_path` · `admin_session_otp_path` · `admin_dashboard_path` · `admin_tenants_path` · `admin_tenant_path` · `admin_tenant_{change_plan,extend_trial,suspend,resume}_path` · `admin_subscription_payments_path` · `refund_{new_}admin_subscription_payments_path` · `admin_root_path`)

### 6.3 Subscription 대조 결과 (작업 중 f8 실구현 확인·정렬 완료 — 2026-11-18)

01_plan §2 가정으로 작성한 뒤 f8이 생성한 `app/models/subscription.rb`·`subscription_event.rb`·
`app/services/subscriptions/*` **실구현과 대조했고, admin 측 파일을 실 시그니처에 맞춰 정렬했다**:

| 접점 | §2 가정 → f8 실구현 | admin 정렬 결과 |
|---|---|---|
| 상한 메서드 | `plan_limit(:students)` → **`students_limit`**(effective_plan — 체험 중 스탠다드 개방) | base_controller 수정 ✅ |
| 체험 만료 판정 | `trial_expiring?(days:)` → **`trial_expiring?(within: 7.days)`** | dashboards_controller 수정 ✅ |
| 체험 잔여일 | `trial_remain_days` 동일(기본 인자 호환) | 수정 불필요 ✅ |
| 플랜 변경 | 컬럼 직접 갱신 → **`Subscriptions::PlanChangeService.change!(plan:, operated_by:, reason:)`**(하향 익월 대기 규약) | tenant_actions_controller 수정 ✅ |
| 이벤트 장부 | `note` 컬럼 가정 → **`detail`(JSON 문자열)·`operated_by`(마스킹 setter)·created_at 전용** | 이벤트 생성·조회 전부 detail JSON으로 수정 ✅ |
| 데이터 삭제 예정일 | 자체 산식 → **`Subscriptions::RetryPolicyService.data_retention_deadline` 단일 경유**(이벤트 부재 시 updated_at 근사 폴백 유지) | subscription_payments_controller 수정 ✅ |
| 이벤트 생성 방식 | 직접 create! → 유지(f8 서비스들도 서비스 내 직접 create! 패턴; refund는 f8이 "기록 타입만 정의"로 후속 명시) | 유지 ✅ |

- **⚠ 3-S 결선 필수 1건**: f8 `SubscriptionEvent` enum에 **`trial_extended`** 타입 없음(validate: true라
  admin 체험 연장 이벤트 생성 시 ArgumentError). 태스크 명세가 "extension 이벤트"를 요구하므로
  f8 enum에 `trial_extended: "trial_extended"` 한 줄 추가 권장(admin 측 파일 수정 불필요).
- `plan_changed` 이벤트는 f8 규약 detail(direction/from/to/reason/status)을 PlanChangeService가 생성 —
  admin은 서비스 호출로 일관 유지(pending_downgrade 판정과 충돌 없음).
- 관리자 `suspended` 이벤트는 f8 `suspend!`(past_due 전용)와 구분되는 관리자 기록 — detail에
  `"note": "관리자 정지 기록(v1.0 — 실차단 후속)"` 포함.
- admin 이메일은 `operated_by=` 마스킹 setter를 통과(휴대폰 패턴 불일치 → 그대로 기록).

### 6.4 시드·credentials

```ruby
# db/seeds.rb (integ에서 병합) — 운영자 1계정(A0)
admin = AdminUser.find_or_create_by!(email: ENV.fetch("ADMIN_EMAIL", "ops@wonbikok.local")) do |u|
  u.password = ENV.fetch("ADMIN_PASSWORD") { SecureRandom.hex(12) } # 콘솔 출력 후 안전 보관
end
# TOTP: otp_secret 미설정 시 credentials otp_seed에서 파생(아래). 사전 공유 방식을 원하면:
# admin.update!(otp_secret: "<Base32 32자>")
```
- **credentials 필수 설정(운영 배포 전)**: `rails credentials:edit` → `admin: otp_seed: "<랜덤 문자열>"` — 미설정 시 경고 로그와 함께 개발 폴백 시크릿 사용(코드에 명시).
- 개발 확인: `bin/rails runner 'puts Admin::OtpService.current_code(AdminUser.find_by!(email: "ops@wonbikok.local"))'`

### 6.5 기타
- `admin_audit` fixture 불필요(테스트는 모델 API 생성 — encrypts 컬럼 없음).
- 레이아웃에서 `render "shared/flash"` 재사용(기존 partial 수정 없음).
- 원장 앱 파일 수정 0건, routes/마이그레이션/ko.yml/recurring.yml 수정 0건(화이트리스트 준수).

## 7. 테스트 매핑 (3-S 이후 실행 — 현재는 미실행: routes·테이블 미병합)

| 파일 | 커버 | 시나리오 |
|---|---|---|
| `test/models/admin_user_test.rb` | A0 | 생성·이메일 유니크/정규화/형식·비밀번호 길이·**5회 잠금**·잠금 후 카운트 불가·성공 리셋·unlock! |
| `test/services/admin/otp_service_test.rb` | A0 | **RFC 6238 벡터(287082)**·유효 코드·±1 스텝·2스텝 거부·잘못/빈 코드·공백 정규화·시드 파생 결정성·otp_secret 우선 |
| `test/services/admin/tenant_search_service_test.rb` | A2/TEN | 빈쿼리 전체·상호·사업자번호·ID·OR 결합·**LIKE 주입 이스케이프**·전화 검색 미지원(축소 명시) |
| `test/services/admin/timeline_service_test.rb` | A2 | 가입·온보딩 상태·발송·발행·audit 병합 최신순·subscription_events 병합(가정)·limit |
| `test/services/admin/refund_policy_service_test.rb` | A3/11.3 | 분기 3종(전액/0원/일할 154,838)·기간 이탈 0원·시작 전 전체 기간·미정의 분기·음수 거부 |
| `test/controllers/admin/sessions_controller_test.rb` | A0 | 미인증 차단·1단계 성공→OTP 폼·1단계 실패 422·열거 방지 동일 문구·**2단계 성공+login audit**·OTP 실패 422+audit·**5회 합산 잠금+account_locked audit**·2단계 만료 복귀·로그아웃 |
| `test/controllers/admin/dashboards_controller_test.rb` | A1 | 미인증 차단·24h 실패 카운트·**산식 명시**·MAU 세션 기간·trial_expiring? 결합(가정)·past_due 큐+링크·SIMULATED 배너·추이 표 |
| `test/controllers/admin/tenants_controller_test.rb` | A2/ADM-002 | 마스킹 렌더(원문 미포함: 사업자번호·휴대폰)·검색 3종·빈 결과·**personal_info_viewed audit**·상세 지표·타임라인 |
| `test/controllers/admin/tenant_actions_controller_test.rb` | ADM-001 | **사유 없는 4조치 전부 422·무기록**·플랜 변경(f8 PlanChangeService 경유 — plan 갱신·detail.reason·audit)·허용값 외/동일 플랜 거부(서비스 reject)·연장 성공(detail.days)·1~30일 경계·**누적 60 상한(30+31 거부/30+30 허용)**·상태 가드·구독 부재 422·정지/해제 기록·미인증 차단 |
| `test/controllers/admin/subscription_payments_controller_test.rb` | A3 | 이력 표시·**유형 필터**·past_due **D+30 카운트다운**(f8 RetryPolicyService 경유 — 20일)·이벤트 부재 근사·매출 월별 합계(58,900)·환불 분기 3종 렌더·기본 금액=최근 결제·**환불 확정(refund 이벤트 detail.reason/branch + audit)**·사유/분기/음수 422·구독 부재 안내·미인증 차단 |

- Subscription 결합부는 각 테스트 파일 로컬 헬퍼(`Subscription.create!`/`SubscriptionEvent.create!`)로 격리 — §2 가정 빌더이며 3-S에서 실제 모델 검증으로 대체.
- month 경계 안정화: 이력 필터 테스트는 `beginning_of_month + N days` 기준 생성.

## 8. 자체 체크리스트

- [x] 소유권 화이트리스트 내 파일만 생성(공유 파일 수정 0)
- [x] Subscription은 §2 가정으로 작성 후 **f8 실구현과 대조·정렬 완료**(§6.3 — 잔여 결선: trial_extended enum 1줄)
- [x] ADM-001: 사유 없는 파괴적 조치 1차(컨트롤러)+2차(AuditLog 검증) 강제
- [x] ADM-002/TEN-003: 마스킹 helper 단일 경유, 개인정보 원문 미렌더(테스트 검증)
- [x] A0: 관리자 세션 키 분리·5회 잠금·콘솔 해제·감사 로그(login/failure/locked/logout/열람)
- [x] 연습 모드·SIMULATED 원칙: 외부 호출 없음(관리자 콘솔은 외부 API 호출부 자체가 없음 — 상태 배너 SIMULATED)
- [x] Turbo 규약: 실패 422 재렌더 / 성공 redirect 303
- [x] i18n 전 키 ko.yml 스니펫 제공(§5)·하드코딩 없음
- [x] rubocop 0(자기 .rb 22파일)·ERB 컴파일 10종·러너 스모크(TOTP RFC 벡터·환불 계산·검색·마스킹·route 14 헬퍼)
- [x] 문서(PRD·AGENTS)·다른 태스크 파일(f7/f8) 미수정
