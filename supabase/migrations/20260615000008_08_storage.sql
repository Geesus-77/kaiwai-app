-- ============================================================
-- 08_storage.sql  —  OOTD 사진 저장용 'posts' 버킷
-- ============================================================
insert into storage.buckets (id, name, public)
values ('posts', 'posts', true)
on conflict (id) do nothing;

-- 공개 조회
create policy "게시물 이미지 공개 조회" on storage.objects
  for select using (bucket_id = 'posts');

-- 본인 폴더(uid/...)에만 업로드 허용
create policy "본인 폴더에만 업로드" on storage.objects
  for insert with check (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 본인 이미지만 수정/삭제
create policy "본인 이미지만 수정" on storage.objects
  for update using (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "본인 이미지만 삭제" on storage.objects
  for delete using (
    bucket_id = 'posts'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
