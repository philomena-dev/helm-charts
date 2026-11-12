-- Anonymized public dump of a Philomena database.
--
-- Runs in the throwaway PostgreSQL of the publicDump CronJob, which holds a
-- copy of the public schema's structure and the data of the tables listed in
-- publicDump.tables. Builds the published tables in the public_dump schema
-- from that copy, then drops the original schema and renames public_dump to
-- public, so the final pg_dump contains only the published tables.
--
-- What is left out: hidden images and their comments, anonymous authorship
-- (user_id becomes null), forums that are not "normal" and their topics and
-- posts, deleted topics, hidden posts and comments, unverified or private
-- artist links, and every user column except id and name.
--
-- psql variables, set by the CronJob from the environment:
--   image_url_root  IMAGE_URL_ROOT, prefix of the images' version_path
--   badge_url_root  BADGE_URL_ROOT, prefix of badge image URLs
--   work_mem        work_mem for this transaction (publicDump.workMem)

begin;
set local work_mem = :'work_mem';

alter table public.images add primary key(id);
alter table public.topics add primary key(id);
alter table public.forums add primary key(id);

create schema public_dump;

create unlogged table public_dump.badges (
  id          bigint   not null,
  title       text     not null,
  description text     not null,
  image_url   text     not null
);

create unlogged table public_dump.badge_awards (
  id         bigint    not null,
  user_id    bigint    not null,
  badge_id   bigint    not null,
  created_at timestamp not null,
  label      text
);

create unlogged table public_dump.comments (
  id         bigint    not null,
  image_id   bigint    not null,
  created_at timestamp not null,
  updated_at timestamp not null,
  user_id    bigint,
  body       text      not null
);

create unlogged table public_dump.duplicate_reports (
  id                    bigint    not null,
  image_id              bigint    not null,
  duplicate_of_image_id bigint    not null,
  created_at            timestamp not null,
  updated_at            timestamp not null,
  user_id               bigint,
  state                 text      not null,
  reason                text
);

create unlogged table public_dump.forums (
  id          bigint    not null,
  topic_count bigint    not null,
  post_count  bigint    not null,
  created_at  timestamp not null,
  updated_at  timestamp not null,
  name        text      not null,
  short_name  text      not null,
  description text      not null
);

create unlogged table public_dump.galleries (
  id              bigint    not null,
  thumbnail_id    bigint    not null,
  user_id         bigint,
  image_count     bigint    not null,
  created_at      timestamp not null,
  updated_at      timestamp not null,
  title           text      not null,
  spoiler_warning text      not null,
  description     text      not null
);

create unlogged table public_dump.gallery_interactions (
  image_id   bigint  not null,
  gallery_id bigint  not null,
  position   integer not null
);

create unlogged table public_dump.image_duplicates (
  image_id  bigint not null,
  target_id bigint not null
);

create unlogged table public_dump.image_faves (
  created_at timestamp not null,
  image_id   bigint    not null,
  user_id    bigint    not null
);

create unlogged table public_dump.image_features (
  image_id   bigint    not null,
  created_at timestamp not null
);

create unlogged table public_dump.image_hides (
  image_id bigint not null,
  reason text not null
);

create unlogged table public_dump.image_intensities (
  image_id      bigint not null,
  nw_intensity  float  not null,
  ne_intensity  float  not null,
  sw_intensity  float  not null,
  se_intensity  float  not null
);

create unlogged table public_dump.image_sources (
  image_id bigint not null,
  source   text   not null
);

create unlogged table public_dump.image_taggings (
  image_id bigint not null,
  tag_id   bigint not null
);

create unlogged table public_dump.images (
  id                     bigint    not null,
  created_at             timestamp not null,
  updated_at             timestamp not null,
  image_width            integer   not null,
  image_height           integer   not null,
  image_size             integer   not null,
  comment_count          integer   not null,
  score                  integer   not null,
  favorites              integer   not null,
  upvotes                integer   not null,
  downvotes              integer   not null,
  hides                  integer   not null,
  image_aspect_ratio     float     not null,
  user_id                bigint,
  hidden_from_users      boolean   not null,
  image_mime_type        text      not null,
  image_format           text      not null,
  image_name             text      not null,
  version_path           text      not null,
  image_sha512_hash      text,
  image_orig_sha512_hash text,
  description            text
);

create unlogged table public_dump.posts (
  id          bigint    not null,
  topic_id    bigint    not null,
  created_at  timestamp not null,
  updated_at  timestamp not null,
  user_id     bigint,
  body        text      not null
);

create unlogged table public_dump.source_changes (
  id         bigint    not null,
  image_id   bigint    not null,
  created_at timestamp not null,
  updated_at timestamp not null,
  user_id    bigint,
  new_value  text      not null
);

create unlogged table public_dump.tag_aliases (
  tag_id        bigint not null,
  target_tag_id bigint not null
);

create unlogged table public_dump.tag_changes (
  id             bigint    not null,
  image_id       bigint    not null,
  created_at     timestamp not null,
  user_id        bigint
);

create unlogged table public_dump.tag_change_tags (
  tag_change_id bigint  not null,
  tag_id        bigint  not null,
  added         boolean not null
);

create unlogged table public_dump.tag_implications (
  tag_id        bigint not null,
  target_tag_id bigint not null
);

create unlogged table public_dump.tags (
  id                bigint not null,
  image_count       bigint not null,
  name              text   not null,
  slug              text   not null,
  category          text,
  description       text,
  short_description text
);

create unlogged table public_dump.topics (
  id         bigint    not null,
  forum_id   bigint    not null,
  post_count bigint    not null,
  view_count bigint    not null,
  created_at timestamp not null,
  updated_at timestamp not null,
  sticky     boolean   not null,
  locked     boolean   not null,
  title      text      not null,
  slug       text      not null
);

create unlogged table public_dump.artist_links (
  id      bigint not null,
  user_id bigint not null,
  tag_id  bigint,
  url     text
);

create unlogged table public_dump.users (
  id   bigint not null,
  name text   not null
);

insert into public_dump.badges (id, title, description, image_url) select id, title, description, concat(:'badge_url_root', '/', image) from public.badges;
insert into public_dump.badge_awards (id, user_id, badge_id, created_at, label) select id, user_id, badge_id, created_at, label from public.badge_awards;
insert into public_dump.comments (id, image_id, created_at, updated_at, user_id, body) select id, image_id, created_at, updated_at, (case when anonymous then null else user_id end), body from public.comments where image_id is not null and hidden_from_users = false and not exists (select 1 from public.images where images.id = comments.image_id and images.hidden_from_users = true);
insert into public_dump.duplicate_reports (id, image_id, user_id, duplicate_of_image_id, created_at, updated_at, state, reason) select id, image_id, user_id, duplicate_of_image_id, created_at, updated_at, state, reason from public.duplicate_reports;
insert into public_dump.forums (id, topic_count, post_count, created_at, updated_at, name, short_name, description) select id, topic_count, post_count, created_at, updated_at, name, short_name, description from public.forums where access_level = 'normal';
insert into public_dump.galleries (id, thumbnail_id, user_id, image_count, created_at, updated_at, title, spoiler_warning, description) select id, thumbnail_id, (case when anonymous then null else user_id end), image_count, created_at, updated_at, title, spoiler_warning, description from public.galleries;
insert into public_dump.gallery_interactions (image_id, gallery_id, position) select image_id, gallery_id, min(position) from public.gallery_interactions group by image_id, gallery_id;
insert into public_dump.image_duplicates (image_id, target_id) select id, duplicate_id from public.images where duplicate_id is not null;
insert into public_dump.image_faves (image_id, user_id, created_at) select image_id, user_id, created_at from public.image_faves;
insert into public_dump.image_features (image_id, created_at) select image_id, created_at from public.image_features;
insert into public_dump.image_hides (image_id, reason) select id, coalesce(deletion_reason, '') from public.images where hidden_from_users = true;
insert into public_dump.image_intensities (image_id, nw_intensity, ne_intensity, sw_intensity, se_intensity) select image_id, nw, ne, sw, se from public.image_intensities;
insert into public_dump.image_sources (image_id, source) select image_id, source from public.image_sources;
insert into public_dump.image_taggings (image_id, tag_id) select image_id, tag_id from public.image_taggings;
insert into public_dump.images (id, created_at, updated_at, image_width, image_height, image_size, comment_count, score, favorites, upvotes, downvotes, hides, image_aspect_ratio, user_id, hidden_from_users, image_sha512_hash, image_orig_sha512_hash, image_mime_type, image_format, image_name, version_path, description) select id, created_at, updated_at, coalesce(image_width, 0), coalesce(image_height, 0), coalesce(image_size, 0), comments_count, score, faves_count, upvotes_count, downvotes_count, hides_count, coalesce(image_aspect_ratio, 0), (case when anonymous then null else user_id end), hidden_from_users, image_sha512_hash, image_orig_sha512_hash, image_mime_type, coalesce(image_format, ''), coalesce(image_name, ''), concat(:'image_url_root', '/', to_char(images.created_at, 'YYYY/fmMM/fmDD/'), id, '/'), images.description from public.images;
insert into public_dump.posts (id, topic_id, created_at, updated_at, user_id, body) select id, topic_id, created_at, updated_at, (case when anonymous then null else user_id end), body from public.posts where hidden_from_users is false and not exists (select 1 from public.topics inner join public.forums on topics.forum_id = forums.id where posts.topic_id = topics.id and (forums.access_level <> 'normal' or topics.deleted_by_id is not null));
insert into public_dump.source_changes (id, image_id, created_at, updated_at, user_id, new_value) select sc.id, sc.image_id, sc.created_at, sc.updated_at, (case when i.user_id = sc.user_id and i.anonymous then null else sc.user_id end), sc.value from public.source_changes sc inner join public.images i on sc.image_id = i.id;
insert into public_dump.tag_aliases (tag_id, target_tag_id) select id, aliased_tag_id from public.tags where aliased_tag_id is not null;
insert into public_dump.tag_changes (id, image_id, created_at, user_id) select tc.id, tc.image_id, tc.created_at, (case when i.user_id = tc.user_id and i.anonymous then null else tc.user_id end) from public.tag_changes tc inner join public.images i on tc.image_id = i.id;
insert into public_dump.tag_change_tags (tag_change_id, tag_id, added) select tag_change_id, tag_id, added from public.tag_change_tags;
insert into public_dump.tag_implications (tag_id, target_tag_id) select tag_id, implied_tag_id from public.tags_implied_tags;
insert into public_dump.tags (id, image_count, name, slug, category, description, short_description) select id, images_count, name, slug, category, description, short_description from public.tags;
insert into public_dump.topics (id, forum_id, post_count, view_count, created_at, updated_at, sticky, locked, title, slug) select id, forum_id, post_count, view_count, created_at, updated_at, sticky, (case when locked_at is null then false else true end), title, slug from public.topics where deleted_by_id is null and not exists (select 1 from public.forums where topics.forum_id = forums.id and forums.access_level <> 'normal');
insert into public_dump.artist_links (id, user_id, tag_id, url) select id, user_id, tag_id, uri from public.artist_links where public=true and aasm_state = 'verified';
insert into public_dump.users (id, name) select id, name from public.users;

create index index_badge_awards_on_user_id_and_badge_id on public_dump.badge_awards (user_id, badge_id);
create index index_badge_awards_on_badge_id             on public_dump.badge_awards (badge_id);

create index index_comments_on_image_id_and_created_at on public_dump.comments (image_id, created_at);
create index index_comments_on_user_id                 on public_dump.comments (user_id);

create index index_duplicate_reports_on_image_id              on public_dump.duplicate_reports (image_id);
create index index_duplicate_reports_on_duplicate_of_image_id on public_dump.duplicate_reports (duplicate_of_image_id);
create index index_duplicate_reports_on_user_id               on public_dump.duplicate_reports (user_id);

create unique index index_forums_on_short_name on public_dump.forums (short_name);

create index index_galleries_on_user_id      on public_dump.galleries (user_id);
create index index_galleries_on_thumbnail_id on public_dump.galleries (thumbnail_id);

create unique index index_gallery_interactions_on_image_id_and_gallery_id on public_dump.gallery_interactions (image_id, gallery_id);
create index index_gallery_interactions_on_gallery_id                     on public_dump.gallery_interactions (gallery_id);

create unique index index_image_duplicates_on_image_id_and_target_id on public_dump.image_duplicates (image_id, target_id);
create index index_image_duplicates_on_target_id                     on public_dump.image_duplicates (target_id);

create unique index index_image_faves_on_image_id_and_user_id on public_dump.image_faves (image_id, user_id);
create index index_image_faves_on_user_id                     on public_dump.image_faves (user_id);

create index index_image_features_on_image_id on public_dump.image_features (image_id);

create unique index index_image_intensities_on_image_id on public_dump.image_intensities (image_id);
create index intensities_index                          on public_dump.image_intensities (nw_intensity, ne_intensity, sw_intensity, se_intensity);

create index index_image_sources_on_image_id on public_dump.image_sources (image_id);

create unique index index_image_taggings_on_image_id_and_tag_id on public_dump.image_taggings (image_id, tag_id);
create index index_image_taggings_on_tag_id on public_dump.image_taggings (tag_id);

create index index_images_on_user_id on public_dump.images (user_id);

create index index_posts_on_user_id on public_dump.posts (user_id);

create index index_source_changes_on_image_id on public_dump.source_changes (image_id);
create index index_source_changes_on_user_id  on public_dump.source_changes (user_id);

create unique index index_tag_aliases_on_tag_id on public_dump.tag_aliases (tag_id);
create index index_tag_aliases_on_target_tag_id on public_dump.tag_aliases (target_tag_id);

create index tag_changes_image_id_index on public_dump.tag_changes (image_id);
create index tag_changes_user_id_index  on public_dump.tag_changes (user_id);

create unique index tag_change_tags_tag_change_id_tag_id_index on public_dump.tag_change_tags (tag_change_id, tag_id);
create index tag_change_tags_tag_id_index                      on public_dump.tag_change_tags (tag_id);

create unique index index_tag_implications_on_tag_id_and_target_tag_id on public_dump.tag_implications (tag_id, target_tag_id);
create index index_tag_implications_on_target_tag_id                   on public_dump.tag_implications (target_tag_id);

create unique index index_tags_on_name on public_dump.tags (name);
create unique index index_tags_on_slug on public_dump.tags (slug);

create index index_topics_on_forum_id on public_dump.topics (forum_id);
create index index_topics_on_slug     on public_dump.topics (slug);

create unique index index_users_on_name on public_dump.users (name);

delete from public_dump.image_taggings where not exists (select 1 from public_dump.tags where tags.id = image_taggings.tag_id);

alter table public_dump.users
  add primary key (id),
  set logged;

alter table public_dump.images
  add primary key (id),
  add constraint fk_images_users foreign key (user_id) references public_dump.users (id),
  set logged;

alter table public_dump.tags
  add primary key (id),
  set logged;

alter table public_dump.badges
  add primary key (id),
  set logged;

alter table public_dump.badge_awards
  add primary key (id),
  add constraint fk_badge_awards_badges foreign key (badge_id) references public_dump.badges (id),
  add constraint fk_badge_awards_users  foreign key (user_id)  references public_dump.users  (id),
  set logged;

alter table public_dump.comments
  add primary key (id),
  add constraint fk_comments_images foreign key (image_id) references public_dump.images (id),
  add constraint fk_comments_users  foreign key (user_id)  references public_dump.users  (id),
  set logged;

alter table public_dump.duplicate_reports
  add primary key (id),
  add constraint fk_duplicate_reports_image_source foreign key (image_id)              references public_dump.images (id),
  add constraint fk_duplicate_reports_image_target foreign key (duplicate_of_image_id) references public_dump.images (id),
  set logged;

alter table public_dump.forums
  add primary key (id),
  set logged;

alter table public_dump.galleries
  add primary key (id),
  add constraint fk_galleries_images foreign key (thumbnail_id) references public_dump.images (id),
  add constraint fk_galleries_users  foreign key (user_id)      references public_dump.users  (id),
  set logged;

alter table public_dump.gallery_interactions
  set logged;

alter table public_dump.image_duplicates
  add constraint fk_image_duplicates_image_source foreign key (image_id)  references public_dump.images (id),
  add constraint fk_image_duplicates_image_target foreign key (target_id) references public_dump.images (id),
  set logged;

alter table public_dump.image_faves
  add constraint fk_image_faves_images foreign key (image_id) references public_dump.images (id),
  add constraint fk_image_faves_users  foreign key (user_id)  references public_dump.users  (id),
  set logged;

alter table public_dump.image_features
  add constraint fk_image_features_images foreign key (image_id) references public_dump.images (id),
  set logged;

alter table public_dump.image_hides
  set logged;

alter table public_dump.image_intensities
  add constraint fk_image_intensities_images foreign key (image_id) references public_dump.images (id),
  set logged;

alter table public_dump.image_sources
  add constraint fk_image_sources_images foreign key (image_id) references public_dump.images (id),
  set logged;

alter table public_dump.image_taggings
  add constraint fk_image_taggings_images foreign key (image_id) references public_dump.images (id),
  add constraint fk_image_taggings_tags   foreign key (tag_id)   references public_dump.tags   (id),
  set logged;

alter table public_dump.posts
  add primary key (id),
  add constraint fk_posts_users foreign key (user_id) references public_dump.users (id),
  set logged;

alter table public_dump.source_changes
  add primary key (id),
  add constraint fk_source_changes_images foreign key (image_id) references public_dump.images (id),
  add constraint fk_source_changes_users  foreign key (user_id)  references public_dump.users  (id),
  set logged;

alter table public_dump.tag_aliases
  add constraint fk_tag_changes_tag_source foreign key (tag_id)        references public_dump.tags (id),
  add constraint fk_tag_changes_tag_target foreign key (target_tag_id) references public_dump.tags (id),
  set logged;

alter table public_dump.tag_changes
  add primary key (id),
  add constraint tag_changes_image_id_fkey foreign key (image_id) references public_dump.images (id),
  add constraint tag_changes_user_id_fkey  foreign key (user_id)  references public_dump.users  (id),
  set logged;

alter table public_dump.tag_change_tags
  add constraint tag_change_tags_tag_change_id_fkey foreign key (tag_change_id) references public_dump.tag_changes (id),
  add constraint tag_change_tags_tag_id_fkey        foreign key (tag_id)        references public_dump.tags        (id),
  set logged;

alter table public_dump.tag_implications
  add constraint fk_tag_changes_tag_source foreign key (tag_id)        references public_dump.tags (id),
  add constraint fk_tag_changes_tag_target foreign key (target_tag_id) references public_dump.tags (id),
  set logged;

alter table public_dump.topics
  add primary key (id),
  add constraint fk_topics_forums foreign key (forum_id) references public_dump.forums (id),
  set logged;

alter table public_dump.artist_links
  add primary key (id),
  add constraint fk_artist_links_users foreign key (user_id) references public_dump.users (id),
  add constraint fk_artist_links_tags  foreign key (tag_id)  references public_dump.tags  (id),
  set logged;

drop schema public cascade;
alter schema public_dump rename to public;
commit;
