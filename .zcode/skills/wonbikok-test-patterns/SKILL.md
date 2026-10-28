---
name: wonbikok-test-patterns
description: 원비콕 테스트 패턴 스킬. minitest + fixtures 기반 계층별 테스트 템플릿과 Rule ID별 필수 시나리오, 포트원·솔라피 스텁 원칙을 제공한다. 원비콕 테스트 작성·실행 시 사용한다.
---

# 원비콕 테스트 패턴

## 이 스킬의 목적

원비콕 테스트의 계층·패턴·필수 시나리오를 제공한다. 테스트는 **Rule ID 단위로 설계**한다 — 각 테스트 메서드에 `# Rule ID` 주석을 붙이고, 정상/경계/예외 3분기를 기본으로 한다.

## 계층 구조

```text
test/models/          — 검증, 상태 전이, 스코프, 도메인 메서드 (fixtures)
test/controllers/     — 통합: 인증·권한·파라미터·응답코드 (ActionDispatch::IntegrationTest)
test/jobs/            — Job 예약·재시도·멱등 (perform_enqueued_jobs)
test/system/          — 브라우저 E2E (필요 시만 — 원장 핵심 플로우)
```

실행: `bin/rails test` / 개별: `bin/rails test test/models/invoice_test.rb`

## 필수 시나리오 (Rule ID → 테스트)

| Rule ID | 필수 시나리오 |
|:---|:---|
| INV-001 | 같은 원생×같은 월 두 번 생성 → 두 번째 실패(검증 + DB 제약 양쪽) |
| INV-004 | 휴원 원생은 월간 청구 일괄 생성에서 제외됨 |
| PAY-001 | 완납 청구에 수납 재등록 → 차단 |
| PAY-002 | 수납 정정 시 이력 레코드 생성, 원본 보존 |
| CR-001 | 동일 원생×당월×유형 두 번째 발행 요청 → 멱등 키로 차단/스킵 |
| CR-002 | 입금 확인 없이 발행 트리거가 동작하지 않음 |
| CR-003 | 공급자 응답 지연(처리중) 상태에서 ISSUED 전이 없음; 최종 성공 응답 후에만 ISSUED |
| CR-004 | 재시도 전 상태 조회 호출 선행 확인(스텁 호출 순서) |
| CR-005 | 취소 요청이 원본 발행과 연결되어 생성됨 |
| MSG-001 | 같은 청구×템플릿 중복 발송 차단, '다시 보내기' 플래그 예외 허용 |
| MSG-002 | 알림톡 실패 응답 스텁 → SMS 대체 발송 1건 기록(채널 구분) |
| MSG-003 | 재시도 상한 도달 후 더 이상 발송 없음 |
| LNK-001~004 | 유효 토큰 200 / 무효·만료 토큰 404+안내 / 타 청구 정보 미노출(응답 본문 검증) |
| TEN-001 | Tenant A 컨텍스트에서 Tenant B 데이터 find → 접근 거부/Not Found |
| SUB-001 | 상한 초과 시 원생 신규 등록 차단, 기존 데이터 유지 |
| ADM-001 | 사유 없는 조치 요청 → 실패 + 감사 로그 미생성; 사유 있으면 로그 생성 |

## 외부 API 스텁 원칙 (실호출 금지)

- 포트원·솔라피 클라이언트는 **의존성 주입 가능한 얇은 래퍼**로 설계되어 있어야 하고, 테스트에서는 스텁 객체로 교체.
- WebMock 대신: Service 계층 테스트는 가짜 클라이언트(응답 해시 반환) 주입, Job/통합 테스트는 `ActiveSupport::TestCase`에서 스텁 메서드 정의.
- 실패 응답 픽스처 필수: 타임아웃 / 4xx(번호 오류) / 5xx(공급자 장애) / 처리중(비동기).
- 연습 모드: practice 테넌트로 외부 호출이 0회 발생함을 검증(스텁에 호출 카운터).

## 템플릿 (모델)

```ruby
# test/models/invoice_test.rb
class InvoiceTest < ActiveSupport::TestCase
  fixtures :tenants, :students, :invoices

  test "INV-001 같은 원생 같은 월 중복 생성 차단" do
    student = students(:one)
    assert_raises(ActiveRecord::RecordInvalid) do
      student.invoices.create!(target_month: "2026-11", amount: 250_000)
    end
  end
end
```

## 템플릿 (통합 — 공개 페이지)

```ruby
# test/controllers/public_invoices_controller_test.rb
class PublicInvoicesControllerTest < ActionDispatch::IntegrationTest
  test "LNK-004 만료 토큰은 정보 미표시" do
    invoice = invoices(:expired_link)
    get billing_url(token: invoice.public_token)
    assert_response :not_found
    assert_no_match(invoice.student_name, @response.body)
  end
end
```

## 완료 전 자체 점검 (Tester 책임)

- [ ] 전체 `bin/rails test` 통과 + 기존 테스트 미파괴
- [ ] 테스트 소스 미사용 변수/헬퍼 제거, Ruby 2칸 들여쓰기, `bin/rubocop` 통과
- [ ] 실패 시 원인 분류 명시: 코드 버그 vs 테스트 오류
- [ ] `_workspace/07_test_report.md` 작성 (통계 + 실패 상세 + Rule ID 커버리지)
