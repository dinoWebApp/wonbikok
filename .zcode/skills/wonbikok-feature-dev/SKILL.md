---
name: wonbikok-feature-dev
description: 원비콕 기능 개발 가이드 스킬. Rails 8.1 + ERB/Hotwire + SQLite 스택의 레이어별 구현 순서, 코드 패턴, 포트원·솔라피 연동 구현 규칙을 제공한다. 원비콕 기능 구현, 마이그레이션 작성, 컨트롤러·뷰·잡 구현 시 참조한다.
---

# 원비콕 기능 개발 가이드

## 이 스킬의 목적

원비콕 기능 구현의 표준 경로를 제공한다. **아키텍처 상세는 ARCHITECTURE_CONVENTION.md(v1.1.0)이 우선 기준**이며, 본 스킬은 원비콕 도메인에 적용한 실무 가이드다.

## 구현 레이어 순서 (백엔드 풀스택)

```text
1. 마이그레이션   — db/migrate, 유니크 인덱스 포함, schema.rb 커밋
2. 모델          — 검증/연관/scope/도메인 메서드/상태(enum) + 전이 가드
3. Form/Service  — 복잡한 입력(다중 모델·CSV 업로드)과 다단계 로직·외부 API만
4. 컨트롤러      — before_action(인증·테넌시), params.expect, 얇은 액션
5. 뷰(ERB)       — 파셜(_form/_item), Turbo Frame/Stream, i18n
6. Job           — 외부 API 호출·일괄 발송·배치 (Solid Queue)
7. 라우팅        — resources 우선, 도메인별 주석 블록
```

## 도메인 패턴

**Tenant 격리 (TEN-001)**: 모든 원장 소유 데이터 조회는 현재 Tenant 스코프 경유(`Current.tenant`). 컨트롤러 `before_action :set_tenant_scoped` 패턴, 모델 `belongs_to :tenant` + 스코프. 관리자 콘솔(`Admin::`)은 별도 인계.

**월간 청구 (INV)**: `Invoice`는 확정 시점의 금액·기한·원생 이름 스냅샷을 보유(TEN-004). 원비 변경이 과거 청구에 영향 없음. 유니크 인덱스 `[student_id, target_month]`(INV-001).

**현금영수증 (CR)**: `CashReceipt`은 내부 고유 ID(idempotency key)로 포트원 발급 요청, 공급자 관리 키·승인번호 저장. 발행 서비스는 `IssueCashReceiptService` — 입금확인(Payment) 트리거에서만 호출(CR-002), 응답 최종 상태 확인 후 ISSUED 전이(CR-003).

**알림톡 (MSG)**: `SendAlimtalkJob` — 솔라피 Messages v4 전용 클라이언트(app/services/solapi/) 경유, 대체발송(SMS) 설정 활성화(MSG-002). 발송 유일성: `[invoice_id, template_type]` + '다시 보내기' 플래그(MSG-001/006).

**학부모 공개 페이지 (LNK)**: 토큰은 `SecureRandom.urlsafe_base64(24)` 이상, 라우트 `/b/:token`. 컨트롤러에서 화이트리스트 속성만 뷰에 전달(LNK-002). noindex, 로그인 불요, 캐시 비활성.

**관리자 (ADM)**: `Admin::` 네임스페이스 + 별도 레이아웃, 조치 액션은 사유 폼 수반 + AuditLog 생성(ADM-001).

## 외부 API 연동 규칙

- 호출은 전용 Service(app/services/portone/, app/services/solapi/)에서만. 컨트롤러·모델·뷰에서 직접 HTTP 금지.
- 시크릿은 Rails credentials(config/credentials.yml.enc)만. 코드·로그·관리자 UI 노출 금지.
- 모든 발급·발송 요청에 멱등 키 전달. 타임아웃·재시도·실패 상태 코드 처리 필수.
- 웹훅(포트원) 수신 컨트롤러는 별도 라우트 + 서명/시크릿 검증.
- 원격 호출은 반드시 Job 래핑(요청-응답 동기 유지, 월 1일 피크 큐 처리).
- 연습 모드 플래그(`practice`)가 true인 Tenant는 외부 호출 스킵 + 로그만 기록.

## 코드 컨벤션 요약

- Ruby·ERB·JS 2칸 space 들여쓰기, 탭 금지 — `bin/rubocop`(omakase)이 단일 기준.
- 문구는 config/locales/ko.yml 또는 Template 관리 체계. 뷰/코드 하드코딩 금지.
- 금액은 integer(원 단위) 컬럼. 날짜·시간은 Timezone 명시(KST 운영 가정).
- 상태 컬럼: `string` + Rails 7+ enum(`status: { draft: "DRAFT", ... }`) — PRD 9장 상태값 그대로.

## 완료 전 자체 점검

- [ ] `bin/rubocop` 0 에러, `bin/brakeman` 0 경고
- [ ] 관련 Rule ID 각각에 대해 코드에서 강제 수단(검증/인덱스/가드)이 존재
- [ ] 마이그레이션·schema.rb 반영, fixtures/시드 필요 시 갱신
- [ ] `_workspace/03_implementation.md` 작성
