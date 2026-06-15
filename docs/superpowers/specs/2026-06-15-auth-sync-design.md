# KAIWAI 로그인 & 동기화 설계

**날짜:** 2026-06-15  
**범위:** 카카오/네이버/구글/이메일 로그인 + 즐겨찾기/피드 크로스 디바이스 동기화  
**백엔드:** Supabase (Auth + PostgreSQL + Storage)  
**앱 환경:** 정적 GitHub Pages (vanilla JS, 단일 index.html)

---

## 1. 전체 아키텍처

```
[GitHub Pages - index.html]
        │
        ├── Auth Layer
        │     ├── Email/PW   → supabase.auth.signInWithPassword()
        │     ├── Google     → supabase.auth.signInWithOAuth('google')
        │     ├── 카카오     → Kakao SDK → 이메일 추출 → signInWithPassword()
        │     └── 네이버     → Naver SDK → 이메일 추출 → signInWithPassword()
        │
        ├── Data Layer (Supabase)
        │     ├── profiles      닉네임, 아바타, 소셜 제공자
        │     ├── favorites     brand_id 즐겨찾기
        │     ├── feed_posts    OOTD 게시물
        │     └── feed_likes    게시물 좋아요
        │
        └── Storage
              └── feed-images 버킷 (OOTD 사진)
```

### 카카오/네이버 Shadow Account 방식

Supabase는 카카오/네이버를 네이티브 OAuth 제공자로 지원하지 않으므로 아래 방식으로 통합:

1. SDK로 로그인 → 유저 이메일 + 고유 ID 취득
2. 내부 이메일로 변환: `kakao_{id}@kaiwai.app` / `naver_{id}@kaiwai.app`
3. 첫 로그인: `supabase.auth.signUp({email, password: '{provider}_{id}_secret'})`
4. 이후 로그인: `supabase.auth.signInWithPassword({email, password})`
5. 유저에게는 노출되지 않음 — 소셜 버튼 클릭만으로 완결

---

## 2. 데이터베이스 스키마

```sql
-- 유저 프로필
CREATE TABLE profiles (
  id          uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nickname    text NOT NULL,
  avatar_url  text,
  provider    text NOT NULL,  -- 'email' | 'google' | 'kakao' | 'naver'
  created_at  timestamptz DEFAULT now()
);

-- 즐겨찾기
CREATE TABLE favorites (
  id         uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  brand_id   integer NOT NULL,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, brand_id)
);

-- 피드 게시물
CREATE TABLE feed_posts (
  id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id     uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  brand_id    integer,
  image_url   text NOT NULL,
  description text,
  likes_count integer DEFAULT 0,
  created_at  timestamptz DEFAULT now()
);

-- 피드 좋아요
CREATE TABLE feed_likes (
  id         uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  post_id    uuid REFERENCES feed_posts(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE(user_id, post_id)
);
```

### RLS 정책

| 테이블 | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| profiles | 본인만 | 본인만 | 본인만 | 본인만 |
| favorites | 본인만 | 본인만 | — | 본인만 |
| feed_posts | 전체 공개 | 본인만 | 본인만 | 본인만 |
| feed_likes | 전체 공개 | 본인만 | — | 본인만 |

### Storage

- 버킷명: `feed-images`
- 업로드: 인증된 유저만
- 읽기: 전체 공개
- 경로: `{user_id}/{uuid}.jpg`

---

## 3. 인증 흐름

### 공통 로그인 후처리

```
로그인 성공
  → profiles upsert (닉네임, provider 저장)
  → favorites 전체 조회 → localStorage 동기화
  → UI 업데이트 (authBtn → 프로필 표시)
```

### 로그아웃

```
supabase.auth.signOut()
  → localStorage favorites 초기화
  → authUser = null
  → UI 업데이트
```

### 세션 복원 (페이지 로드 시)

```javascript
const { data: { session } } = await supabase.auth.getSession()
if (session) {
  authUser = session.user
  // favorites 동기화, UI 업데이트
}
// OAuth 리다이렉트 콜백 자동 처리 (URL hash의 access_token 감지)
supabase.auth.onAuthStateChange((event, session) => { ... })
```

---

## 4. 즐겨찾기 동기화

```
하트 클릭
  ├── 로그인 O → Supabase INSERT/DELETE + localStorage 동시 업데이트
  └── 로그인 X → localStorage만 (기존 동작 유지)

앱 시작 + 로그인 상태
  → Supabase favorites 전체 조회 → localStorage 완전 덮어쓰기
```

---

## 5. 피드 기능

### 업로드 흐름

```
+ 업로드 버튼 클릭 → 로그인 체크 (비로그인 시 모달 오픈)
  → 사진 선택 (input[type=file], 이미지만, 최대 5MB)
  → 설명 + 브랜드 태그 입력
  → Supabase Storage 업로드 → public URL 취득
  → feed_posts INSERT
  → 피드 목록 새로고침
```

### 좋아요 흐름

```
하트 클릭
  ├── 로그인 O → feed_likes INSERT/DELETE + likes_count +1/-1
  └── 로그인 X → 로그인 모달 열기
```

### 피드 렌더링

- 앱 시작 시 Supabase에서 feed_posts 전체 조회 (최신순)
- 하드코딩된 12개 게시물은 제거
- 게시물 없을 때 빈 상태 메시지 표시

---

## 6. 구현 순서

1. Supabase 프로젝트 생성 + 환경변수 설정
2. DB 테이블 + RLS + Storage 버킷 생성
3. Supabase JS SDK 추가 (CDN)
4. 세션 복원 + 공통 로그인 후처리 함수
5. Email/PW 로그인 → Supabase 연동
6. Google OAuth 연동
7. 카카오 Shadow Account 연동
8. 네이버 Shadow Account 연동
9. 즐겨찾기 동기화 (하트 클릭 + 앱 시작)
10. 피드 업로드 + 좋아요 구현
11. 기존 하드코딩 피드 제거 + 실제 데이터 렌더링

---

## 7. 필요한 외부 설정 (구현 전 선행)

| 항목 | 위치 | 내용 |
|---|---|---|
| Supabase 프로젝트 | supabase.com | URL + anon key 발급 |
| Google OAuth | Google Cloud Console | OAuth 클라이언트 ID, 리다이렉트 URL 등록 |
| 카카오 앱 키 | developers.kakao.com | JavaScript 키 발급 |
| 네이버 클라이언트 ID | developers.naver.com | 클라이언트 ID + 콜백 URL 등록 |
| Supabase Google 설정 | Supabase Dashboard → Auth → Providers | Google client ID/secret 입력 |
