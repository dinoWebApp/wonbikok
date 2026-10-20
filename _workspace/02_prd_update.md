# 02 — 문서 현행화 (Phase 2)

- 실행: 오케스트레이터 / 2026-10-20
- 범위: W1(F1·F2) 구현 전 문서 선행 갱신

## PRD.md (v2.0 → v2.1)

| 섹션 | 변경 |
|:---|:---|
| 문서 정보 | 버전 v2.1 (W1 구현 확정 반영) |
| 14장 데이터 모델 | W1 구현 확정 사항 신설 — 휴대폰번호+비밀번호(bcrypt) 인증, 포트원 본인인증은 W3+(오픈 이슈 8), Active Record Encryption + last4 보조 컬럼, 금액 원 단위 integer, 상태는 9장 문자열 값, Guardian 1:N 설계(MVP 대표 1명), Tenant practice·onboarding_step 필드 |
| 14장 표: Tenant/Academy | practice, onboarding_step 항목 추가 |
| 14장 표: User | 휴대폰번호(암호화)·password_digest·역할(owner/admin)로 확정 |
| 14장 표: Guardian | 휴대폰번호(암호화+last4), is_primary(1:N, MVP 대표 1명) |

## AGENTS.md

| 섹션 | 변경 |
|:---|:---|
| 기술 스택 | 인증 라인 추가: bcrypt(has_secure_password) + Rails 8 세션, 휴대폰번호 식별(AR Encryption) |
| 구현 진행 상황 | W1 ⬜ 미착수 → 🔄 진행 중 |

## 비고

- Rule ID 신규 추가 없음(기존 45건으로 W1 커버 — TEN-001/002/003, INV-004)
- 22장 규칙 본문 변경 없음
