require "test_helper"

class LandingControllerTest < ActionDispatch::IntegrationTest
  # 랜딩(루트) 라우팅·인증 게이트 — 2026-11-04 root 변경("landing#show") + /dashboard 이동 검증

  test "비인증 루트 접근은 랜딩을 200으로 렌더한다" do
    get root_url

    assert_response :ok
    assert_select "main#landing_main" # 랜딩 전용 레이아웃(앱 셸과 분리)
  end

  test "랜딩 레이아웃에는 앱 셸 하단탭 내비게이션이 없다(리디자인 분리)" do
    get root_url

    assert_response :ok
    assert_select "nav[aria-label=?]", I18n.t("nav.aria_label"), count: 0
  end

  test "랜딩은 SEO 메타(title·description·OG)를 포함한다" do
    get root_url

    assert_response :ok
    assert_select "title", text: I18n.t("landing.meta.title")
    assert_select "meta[name=description][content=?]", I18n.t("landing.meta.description")
    assert_select "meta[property='og:title'][content=?]", I18n.t("landing.meta.og_title")
    assert_select "meta[property='og:description'][content=?]", I18n.t("landing.meta.og_description")
  end

  test "랜딩 10섹션의 전환 지점(히어로 CTA·베타 폼·FAQ)이 렌더된다" do
    get root_url

    assert_response :ok
    assert_select "a[data-event=cta_hero]" # 히어로 CTA(13.5 트래킹 지점)
    assert_select "form[data-event=form_start]" # 베타 신청 폼(13.6)
    assert_select "details summary" # FAQ 아코디언
  end

  test "인증 원장의 루트 접근은 /dashboard로 303 리다이렉트된다" do
    _tenant, user = create_owner_user(step: 6)
    log_in(user)

    get root_url

    assert_redirected_to dashboard_path
    assert_equal 303, response.status
  end

  test "온보딩 미완료 원장도 랜딩은 게이트 없이 /dashboard로 보낸다(랜딩 게이트 skip)" do
    # 랜딩은 인증·온보딩 게이트 모두 skip — 인증만 되어 있으면 앱 홈으로 위임
    tenant, user = create_owner_user(step: 2)
    log_in(user)

    get root_url

    assert_redirected_to dashboard_path
    assert_equal 303, response.status
    tenant.destroy
  end

  test "비인증 /dashboard 접근은 로그인으로 리다이렉트된다(기존 인증 게이트 유지)" do
    get dashboard_url

    assert_redirected_to new_session_path
  end
end
