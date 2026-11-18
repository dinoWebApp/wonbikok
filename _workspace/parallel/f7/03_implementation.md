# 03_implementation.md — f7 마감 대시보드 (W4 병렬 배치, Phase 3-P)

- 작성일: 2026-11-18
- 작업자: wonbikok-developer (f7 태스크)
- 범위: PRD 7장 F7 마감 대시보드 & 리포트 (PDF 제외 — 후속 과제)

## 1. 생성/수정 파일

| 파일 | 구분 | 내용 |
|---|---|---|
| `app/services/dashboard/summary_service.rb` | 신규 | 대시보드·리포트 집계 전담(뷰 질의 금지 준수). 읽기 전용 |
| `app/controllers/dashboard_controller.rb` | 수정 | show 재작성(SummaryService·month 파라미터) + report 액션 신설 |
| `app/views/dashboard/show.html.erb` | 수정 | ①할 일 상단 ②미발행 잔여 경고(월말 강조) ③지표 4개(기준 라벨 병기) ④빠른 작업 ⑤마감 완료 + 빈 상태 온보딩 분기 |
| `app/views/dashboard/report.html.erb` | 신규 | 월간 마감 리포트(지표 요약·미납 명단·발행 요약 상태별 건수). PDF 후속 주석 명시 |
| `app/views/students/show.html.erb` | 수정 | 원생별 수납·발행 이력 섹션만 교체(최근 6개월 표) — 나머지 무변경 |
| `test/services/dashboard/summary_service_test.rb` | 신규 | 서비스 11개 케이스 |
| `test/controllers/dashboard_controller_test.rb` | 신규 | 컨트롤러 5개 케이스 |

소유권 화이트리스트 준수(초과·누락 없음). routes·ko.yml·마이그레이션·모델·shared 파셜 미수정.

## 2. 지표 산식 (Dashboard::SummaryService)

| 지표 | 산식 | 비고 |
|---|---|---|
| 청구액 | 당월 `billable`(CANCELLED 제외 — INV-003) `total_amount` 합계 | DRAFT 포함, `draft_count` 별도 제공(뷰가 "초안 N건 포함" 표기) |
| 수납액 | 당월 billable 청구의 `Payment.active` 합계(PAY-002 취소 이력 제외) | 취소 전환 청구의 수납도 제외(INV-003) |
| 미납액 | `max(청구액 - 수납액, 0)` | 음수 방지 |
| 납부율 | `(수납액/청구액*100).round` | 청구 0이면 nil(뷰 "-" 표시) |
| 미확인 입금 | 상태 5종(READY/SENT/UNPAID/OVERDUE/PARTIALLY_PAID) & 잔액>0 | **PaymentsController#unpaid_rows와 동일 기준** — 링크 화면과 수 일치 |
| 발행 실패 | 당월 청구의 cash_receipts `state=failed` 건수 | |
| 다가오는 리마인더 | `Invoice.remindable` 재사용(기존 스코프 — MSG-004 배제 포함), 기한 임박(due_on asc) 순 상위 5건 스냅샷 + 전체 건수 | stage는 `Reminders::Scheduler.due_stage_for`(읽기 전용) |
| 미발행 잔여 | PAID 청구 중 **issued 영수증이 없는** 청구(CR-001 — needs_info/failed/cancelled 보유도 미발행) | |
| 월말 플래그 | 말일 - today ≤ 7일 → `month_end_near?`(가산세 문구·danger 강조) | |
| 마감 완료 | `month_elapsed?`(월 경과) **또는** 청구>0 & 미납 0(수납 100%) | F7 수용조건 정의 준수 |
| 빈 상태 | 원생 0 → `:no_students` / 원생 있고 당월 청구 0 → `:no_invoices` / 아니면 nil | 온보딩 CTA 분기 |
| 미납 명단(report) | billable & 잔액>0 — 원생명·총액·수납·잔액 | |
| 발행 요약(report) | 당월 영수증 상태별 건수(7종 전체, 0 포함) | |

month 파라미터: `\A\d{4}-(0[1-9]|1[0-2])\z` 검증 수용, 무효·공백은 당월(invoices#set_month·payments#sanitized_month·C5 준용). 서비스 `on:` 파라미터로 테스트 가능한 날짜 판정.

## 3. ko.yml 키 목록 (3-S에서 정의 필요)

기존 재사용: `dashboard.title·todo_title·upcoming_reminders·amount_basis·ready·invoices_link·students_link·invoices_hint`, `invoices.won`, `invoices.summary.people`, `invoices.status.*`, `cash_receipts.state.*`, `common.back`, `students.show.history_title·history_empty`, `students.index.won`

신규 키(값 제안):

```yaml
dashboard:
  todo:
    unconfirmed_payments: "미확인 입금"
    failed_receipts: "발행 실패"
    unit_cases: 건
    overdue_days: "%{days}일 경과"
  unissued:
    title: "발행 대기 잔여"
    description: "입금 확인됐으나 현금영수증이 발행되지 않은 원생이 있습니다."
    more: "외 %{count}명"
    month_end_notice: "월말이 임박했습니다. 가산세 방지를 위해 이번 달 안에 발행을 마쳐 주세요."
    action: "발행 화면으로 이동"
  metrics:
    title: "%{month} 마감 현황"
    billed: 청구액
    paid: 수납액
    unpaid: 미납액
    rate: 납부율
    draft_note: "초안 %{count}건 포함"
    basis_label: "금액 기준:"
    basis_billed: "청구 = 확정 청구 합계(취소 제외)"
    basis_paid: "수납 = 실수납 기록 합계"
  quick:
    unpaid_list: "미납자 목록"
    failed_receipts: "발행 실패 확인"
    new_student: "원생 추가"
  closing:
    title: "이번 달 마감 완료"
    description: "수납 100% 또는 월 경과 조건에 도달했습니다. 수고하셨습니다."
  empty:
    no_students_title: "첫 원생을 등록해 보세요"
    no_students_description: "원생을 등록하면 이번 달 원비 현황과 오늘 할 일이 표시됩니다."
    no_students_cta: "첫 원생 등록하기"
    no_invoices_title: "첫 청구를 만들어 보세요"
    no_invoices_description: "이번 달 청구를 만들면 납부 안내와 입금 확인이 시작됩니다."
    no_invoices_cta: "첫 청구 만들기"
  report:
    title: "%{month} 마감 리포트"
    metrics_title: "지표 요약"
    unpaid_title: "미납 명단"
    unpaid_empty: "미납이 없습니다. 이번 달 수납이 모두 확인되었습니다."
    unpaid_row_note: "총 %{total} · 수납 %{paid}"
    unpaid_total: "미납 합계"
    receipt_title: "발행 요약"
    receipt_unit: 건
students:
  show:
    history:
      no_bill: "청구 없음"
      no_receipt: 미발행
```

값 갱신 제안: `students.show.history_title` — "이번 달 납부·발행 이력" → "수납·발행 이력(최근 6개월)"(표 범위와 일치).

미사용化 키(3-S 판단): `dashboard.unpaid_count`(구 todo 라벨), `dashboard.reminders_link`(버튼 → todo의 다가오는 리마인더 링크로 대체, reminders_path 링크는 유지).

## 4. 3-S 전달 사항

1. **routes.rb 결선(필수)**: 대시보드 블록에 `get "dashboard/report", to: "dashboard#report", as: :dashboard_report` 추가. f7 제약(기존 라우트만 사용)에 따라 show 뷰에는 리포트 링크를 넣지 않았음 — 라우트 추가 후 `dashboard_path` 헤더 또는 빠른 작업에 `dashboard_report_path(month: @month)` 링크 추가 권장.
2. **ko.yml 병합**: §3 키 목록. 테스트 환경은 `raise_on_missing_translations` off라 누락 시에도 "Translation missing" 렌더(테스트 실패 없음) — 그러나 병합 전 다른 테스트가 show를 렌더함(sessions·onboarding 테스트가 follow_redirect) — 키 병합은 3-S 필수.
3. **students/show 이력 데이터의 층위**: 컨트롤러(students_controller=f8 소유) 수정 불가로 뷰에서 `@student.invoices.index_by(&:target_month)` + `CashReceipt.where(invoice_id:)` 스코프 사용 — `invoices/index.html.erb`의 뷰 스코프 선례 준용(단일 원생·소규모 N). 3-S에서 (a) students_controller `before_action` 이관 또는 (b) `Invoice has_many :cash_receipts` 추가(현재 CashReceipt는 belongs_to만 — Invoice에 역참조 부재)로 정리 권장.
4. **PDF 저장**: 후속 과제(01_plan §0.2) — report.html.erb 상단 주석에 명시. 라우트만 결선되면 HTML 리포트 즉시 사용 가능.
5. **기존 show 요소 보존**: ready 문구·invoices_hint·amount_basis·invoices_link/students_link 버튼 유지. `dashboard.ready` 문구는 빠른 작업 카드 머리글로 유지.

## 5. 테스트 매핑 (Rule ID·수용조건)

| 테스트 | 검증 대상 |
|---|---|
| 지표 정산(취소 제외·부분납 반영·기준 라벨) | INV-003, PAY-002, F7 "금액 기준 화면 명시" |
| 취소 전환 청구 수납 제외(INV-003) | INV-003(이력 유지·정산 제외), 납부율 nil |
| 미확인 입금 — 미완납 확정만(초안·취소·완납·타월 제외) | F7 오늘 할 일, payments#index 수 일치 |
| 발행 실패 건수 + 상태별 발행 요약(7종) | CR(표시 정합), F7 리포트 발행 요약 |
| 다가오는 리마인더 — 기한 임박 순·제외 원생 배제 | MSG-004, F6 remindable 재사용 |
| 미발행 잔여 — PAID × issued 없음만 | CR-001, F7 미발행 경고 |
| 마감 완료 판정(수납 100% / 월 경과) | F7 수용조건 2항 |
| 월말 플래그(말일 7일 이내) | F7 가산세 방지 문구 플래그 |
| 빈 상태 구분(no_students/no_invoices/nil) | F7 빈 상태 온보딩 |
| 미납 명단(원생명·금액·잔액) | F7 리포트 미납 명단 |
| TEN-001 타 테넌트 데이터 미포함 | TEN-001 |
| 컨트롤러 — 비로그인 리다이렉트 | 인증 게이트(기존 패턴) |
| 컨트롤러 — 표시 요소·바로가기 링크 | F7 화면 구성 |
| 컨트롤러 — PAID 무발행 원생 노출 | F7 미발행 잔여 경고 |
| 컨트롤러 — month 유효/무효 파라미터 | C5 준용 |
| 컨트롤러 — report 액션 존재 | 라우트는 3-S 결선(액션·뷰만 선행 제공) |

## 6. 자체 검증 결과

- `bin/rubocop` (소유 Ruby 4파일): **0 offense**
- ERB 3종: Rails 8.1 실제 핸들러(ActionView::Template::Handlers::ERB::Erubi)와 동일 컴파일로 구문 검증 통과(Rails 부팅·DB 접근 없음)
- 전체 테스트·마이그레이션·서버 기동: 제약 준수로 미실행(3-S 이후 게이트에서 검증)
- 회귀 안전: 세션/온보딩/스모크 테스트의 dashboard 렌더 경로(빈 테넌트)는 빈 상태 분기로 200 렌더. students_controller_test는 이력 섹션의 빈 분기(기존 empty_state 유지)로 영향 없음
