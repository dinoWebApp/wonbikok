// 원비콕 디자인 토큰 — PRD 16.1 브랜드 비주얼 가이드
//
// 이 프로젝트는 tailwindcss-rails 4.x(Tailwind CSS v4 엔진)를 사용하며,
// 아래 v3 문법의 설정 파일을 app/assets/tailwind/application.css 의
// `@config` 지시문으로 로드한다. (v4 하위호환 경로)
//
// 색채 규율(PR D 16.0): 주색(brand) 1 + 경고(warning) 1 — 경고색은 조치 필요
// 상태에만 사용하고, 단순 미납은 중립·주의 상태로 표시한다.
module.exports = {
  content: [
    "./app/views/**/*.erb",
    "./app/helpers/**/*.rb",
    "./app/javascript/**/*.js",
  ],
  theme: {
    extend: {
      colors: {
        canvas: "#F7F9FC", // 기본 배경 — 앱 전체 밝고 차분하게
        surface: "#FFFFFF", // 기본 표면 — 카드·입력 영역
        ink: "#191F28", // 본문 텍스트 — 충분한 대비
        muted: "#667085", // 보조 텍스트 — 설명·시간·보조 정보
        line: "#E4E7EC", // 경계선·구분선
        brand: {
          // 브랜드 포인트(청색) — 주요 CTA·선택 상태 제한적 사용
          50: "#EEF4FF",
          100: "#DBE7FE",
          200: "#BDD3FD",
          500: "#3478F6", // PRD 16.1 브랜드 포인트
          600: "#2563EB", // CTA 배경·링크 (흰 글자 대비 AA)
          700: "#1D4ED8", // 링크 텍스트·hover
        },
        success: {
          // 완납·발행 성공 등 확정된 성공 상태
          50: "#ECFDF3",
          100: "#D1FADF",
          200: "#A6F4C5",
          500: "#12B76A",
          600: "#039855",
          700: "#027A48",
        },
        warning: {
          // 납부 예정·확인 필요 등 즉시 오류는 아닌 상태
          50: "#FFFAEB",
          100: "#FEF0C7",
          200: "#FEDF89",
          300: "#FDB022",
          500: "#F79009",
          600: "#DC6803",
          700: "#B54708",
        },
        danger: {
          // 발행 실패·발송 실패·차단 등 조치 필요 상태
          50: "#FEF3F2",
          100: "#FEE4E2",
          200: "#FECDCA",
          300: "#FDA29B",
          500: "#F04438",
          600: "#D92D20",
          700: "#B42318",
        },
        info: {
          // 발송 대기·안내 등 중립 정보(브랜드 청색 공용)
          50: "#EEF4FF",
          100: "#DBE7FE",
          200: "#BDD3FD",
          500: "#3478F6",
          600: "#2563EB",
          700: "#1D4ED8",
        },
      },
      fontFamily: {
        // Pretendard(CDN) + 시스템 폰트 폴백 — CDN 실패 대비
        sans: [
          "Pretendard",
          "-apple-system",
          "system-ui",
          "Apple SD Gothic Neo",
          "Malgun Gothic",
          "sans-serif",
        ],
      },
    },
  },
};
