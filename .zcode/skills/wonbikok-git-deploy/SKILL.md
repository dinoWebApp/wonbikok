---
name: wonbikok-git-deploy
description: 원비콕 Git 배포 스킬. 변경 사항을 품질 게이트 통과 후 커밋하고 원격 저장소에 푸시한다. Kamal 프로덕션 배포 절차도 안내한다. "git 배포", "커밋", "푸시", "배포", "push", "커밋해줘", "배포해줘" 요청 시 사용한다.
---

# 원비콕 Git 배포

## 이 스킬의 목적

원비콕 변경 사항을 안전하게 커밋·푸시하고, 필요 시 Kamal 프로덕션 배포까지 절차화한다. 금전·개인정보를 다루는 서비스 특성상 품질 게이트와 민감 파일 검사를 우선한다.

## 커밋·푸시 절차

1. **상태 확인**
   ```bash
   git status --short && git branch --show-current
   ```
   main 브랜치 직접 커밋 시 사용자 확인. 기능 작업은 feature 브랜치 권장.

2. **민감 파일 검사 (차단 목록)** — 발견 시 커밋 중단 + 사용자 보고:
   - `config/master.key`, `config/credentials/*.key`, `.env*`
   - `*.p12`, `*.pem`, `*.jks`, 시크릿 포함 파일
   - `storage/*.sqlite3`, `log/`, `tmp/` (Git 경로 오류)
   - 단, `config/credentials.yml.enc`(암호화됨)은 커밋 허용

3. **품질 게이트 (전 구간 통과 필수)**
   ```bash
   bin/rubocop && bin/brakeman && bin/rails test
   ```
   실패 시 커밋 불가 — 오류 보고 후 중단.

4. **커밋 메시지** — Conventional Commits, 한국어 본문 허용:
   ```
   feat(invoice): 월간 청구 자동 생성 배치 구현

   - 매월 1일 청구 초안 생성 Job 추가 (INV-001, INV-004)
   - 휴원 원생 제외 스코프 (INV-004)
   ```

5. **푸시** — `git push origin {branch}`. PR 워크플로 사용 시 브랜치 푸시 후 PR 생성 안내.

## Kamal 프로덕션 배포 (별도 요청 시)

전제: 커밋·푸시 완료 + 작업 디렉토리 clean + 사용자 명시 승인.

1. 사전 확인: `bin/kamal app boot` 상태, `.kamal/secrets` 구성, 백업(스토리지 볼륨) 여부
2. `bin/kamal deploy` 실행 → 로그 모니터링
3. 배포 후: 헬스체크(루트/핵심 라우트 응답), `bin/kamal app logs -f`로 부트 로그 확인
4. 실패 시: `bin/kamal rollback` 후 사용자 보고

**배포는 되돌리기 어려운 작업** — 항상 사용자 승인 후 실행한다.

## 안전 장치 요약

- 게이트 미통과 → 커밋/배포 불가
- 민감 파일 → 무조건 차단
- main 직접 커밋·프로덕션 배포 → 사용자 확인 필수
- 커밋은 논리 단위로 분리(하네스 산출물과 소스를 한 커밋에 섞지 않음 — 필요시 분리)
