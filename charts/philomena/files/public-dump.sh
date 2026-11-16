#!/bin/sh
# Builds the anonymized public dump of a Philomena database, and the page
# that describes it.
#
# Runs in the PostgreSQL image, next to a scratch PostgreSQL server that
# nothing else uses and that is thrown away afterwards. It
#
#   1. copies the structure of the public schema, and the data of the tables
#      in TABLES, from the source database into the scratch one;
#   2. builds the published tables there with public-dump.sql, which drops
#      everything else;
#   3. writes into $WORK_DIR/out:
#
#        <NAME_PREFIX>_<YYYY_MM_DD>.pgdump  the dump, in pg_dump's custom format
#        latest.json                        its name, size, SHA-256 and date
#        index.html                         the page that describes and links it
#
# Publishing the three files is left to the caller (public-dump-upload.sh
# does it with rclone). They belong next to each other: the page links the
# dump by its name alone.
#
# Settings, read from the environment:
#
#   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
#                   the source database (the variables of libpq)
#   SOURCE_HOST     host to read from instead of PGHOST, such as a replica
#   SCRATCH_HOST SCRATCH_PORT SCRATCH_USER SCRATCH_DB
#                   the scratch database: empty, owned by a superuser, and
#                   open without a password (127.0.0.1, 5432, philomena,
#                   philomena)
#   IMAGE_URL_ROOT  prefix of the images' version_path (required)
#   BADGE_URL_ROOT  prefix of the badge image URLs (required)
#   NAME_PREFIX     start of the dump's file name (philomena_public_dump)
#   TABLES          tables whose data is copied; nothing else is read
#   PARALLEL_JOBS   pg_dump and pg_restore jobs of the copy (4)
#   WORK_MEM        work_mem while the published tables are built (1GB)
#   WORK_DIR        directory to work in, on a volume with room for the
#                   copied data and the dump (/scratch)
#   SQL_FILE        /config/public-dump.sql
#   PAGE_TEMPLATE   /config/index.html.tmpl; empty for no page
#   SITE_NAME       name of the site on the page (Philomena)
#   SITE_URL        address of the site, which the page links to (APP_ORIGIN
#                   of Philomena's own settings, when that is set)

set -eu

: "${IMAGE_URL_ROOT:?IMAGE_URL_ROOT must be set}"
: "${BADGE_URL_ROOT:?BADGE_URL_ROOT must be set}"

name_prefix=${NAME_PREFIX:-philomena_public_dump}
tables=${TABLES:-artist_links badge_awards badges comments duplicate_reports forums galleries gallery_interactions image_faves image_features image_intensities image_sources image_taggings images posts source_changes tag_change_tags tag_changes tags tags_implied_tags topics users}
jobs=${PARALLEL_JOBS:-4}
work_mem=${WORK_MEM:-1GB}
work_dir=${WORK_DIR:-/scratch}
sql_file=${SQL_FILE:-/config/public-dump.sql}
page_template=${PAGE_TEMPLATE-/config/index.html.tmpl}
site_name=${SITE_NAME:-Philomena}
site_url=${SITE_URL:-${APP_ORIGIN:-}}

source_host=${SOURCE_HOST:-${PGHOST:?PGHOST or SOURCE_HOST must be set}}
scratch_db=${SCRATCH_DB:-philomena}
scratch="-h ${SCRATCH_HOST:-127.0.0.1} -p ${SCRATCH_PORT:-5432} -U ${SCRATCH_USER:-philomena}"

# The name ends up in a file name, in latest.json and on the page.
case "$name_prefix" in
  '' | *[!A-Za-z0-9._-]*)
    echo "NAME_PREFIX may only contain letters, digits, dots, dashes and underscores" >&2
    exit 1
    ;;
esac

# Found out now rather than after the copy.
for required in "$sql_file" "$page_template"; do
  if [ -n "$required" ] && [ ! -r "$required" ]; then
    echo "$required is missing" >&2
    exit 1
  fi
done

src=$work_dir/source
out=$work_dir/out
file="${name_prefix}_$(date -u +%Y_%m_%d).pgdump"

# Bytes as a size with a unit, in the powers of 1024 that pg_size_pretty and
# `du -h` count in.
human_size() {
  awk -v bytes="$1" 'BEGIN {
    split("bytes KB MB GB TB PB", unit, " ")
    for (i = 1; bytes >= 1024 && i < 6; i++) bytes /= 1024
    format = i == 1 ? "%d %s" : "%.1f %s"
    printf format, bytes, unit[i]
  }'
}

# Fills in the page template: the @@NAME@@ tokens with the values below, and
# the TABLES marker with the layout of the published tables as the scratch
# database has them.
render_page() {
  columns=$work_dir/columns.tsv

  # One line per column: table, column, type, whether it can be null. Types
  # are named as public-dump.sql declares them.
  # shellcheck disable=SC2086
  psql $scratch -d "$scratch_db" -X -q -tA -F "$(printf '\t')" -v ON_ERROR_STOP=1 > "$columns" << 'SQL'
select c.relname,
       a.attname,
       replace(replace(format_type(a.atttypid, a.atttypmod),
         'timestamp without time zone', 'timestamp'),
         'double precision', 'float'),
       case when a.attnotnull then '' else 'yes' end
from pg_attribute a
join pg_class c on c.oid = a.attrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and a.attnum > 0 and not a.attisdropped
order by c.relname, a.attnum;
SQL

  PAGE_SITE_NAME=$site_name \
    PAGE_SITE_URL=$site_url \
    PAGE_DATABASE=${name_prefix%_public_dump} \
    PAGE_FILE=$file \
    PAGE_SIZE=$(human_size "$size") \
    PAGE_SIZE_BYTES=$size \
    PAGE_SHA256=$sha \
    PAGE_CREATED="${created_at%T*} $(echo "${created_at#*T}" | cut -c1-5) UTC" \
    PAGE_CREATED_AT=$created_at \
    PAGE_DATABASE_SIZE=$(human_size "$database_size") \
    PAGE_POSTGRES_VERSION=$postgres_version \
    awk -v columns="$columns" '
      function escape(text) {
        gsub(/&/, "\\&amp;", text)
        gsub(/</, "\\&lt;", text)
        gsub(/>/, "\\&gt;", text)
        gsub(/"/, "\\&quot;", text)
        return text
      }

      # Replaces a token wherever it occurs, without reading anything into
      # the value the way sub() and gsub() do.
      function fill(line, token, value,    at, done) {
        done = ""
        while ((at = index(line, token)) > 0) {
          done = done substr(line, 1, at - 1) value
          line = substr(line, at + length(token))
        }
        return done line
      }

      function close_table() {
        print "              </tbody>"
        print "            </table>"
        print "          </div>"
        print "        </section>"
      }

      function print_tables(    row, field, current) {
        current = ""
        while ((getline row < columns) > 0) {
          split(row, field, "\t")
          if (field[1] != current) {
            if (current != "") close_table()
            current = field[1]
            print "        <section class=\"schema-table\" id=\"" escape(current) "\">"
            print "          <h3>public." escape(current) "</h3>"
            print "          <div class=\"table-wrap\">"
            print "            <table class=\"table striped\">"
            print "              <thead>"
            print "                <tr><th>Name</th><th>Type</th><th>Nullable?</th></tr>"
            print "              </thead>"
            print "              <tbody>"
          }
          print "                <tr><td>" escape(field[2]) "</td><td>" escape(field[3]) "</td><td>" (field[4] == "yes" ? "&#x2714;" : "") "</td></tr>"
        }
        if (current != "") close_table()
      }

      BEGIN {
        split("SITE_NAME SITE_URL DATABASE FILE SIZE SIZE_BYTES SHA256 CREATED CREATED_AT DATABASE_SIZE POSTGRES_VERSION", names, " ")
        for (i in names) values["@@" names[i] "@@"] = escape(ENVIRON["PAGE_" names[i]])
      }

      /<!-- TABLES -->/ {
        print_tables()
        next
      }

      {
        line = $0
        for (token in values) line = fill(line, token, values[token])
        print line
      }
    ' "$page_template" > "$out/index.html"

  rm -f "$columns"

  if grep -q '@@[A-Z0-9_]\{1,\}@@' "$out/index.html"; then
    echo "$page_template has a token this script does not know:" >&2
    grep -o '@@[A-Z0-9_]\{1,\}@@' "$out/index.html" | sort -u >&2
    exit 1
  fi
}

echo "Waiting for the scratch PostgreSQL..."
# shellcheck disable=SC2086
until pg_isready -q $scratch; do
  sleep 2
done

rm -rf "$src" "$out"
mkdir -p "$src" "$out"

echo "Copying the schema from $source_host..."
pg_dump -h "$source_host" -Fc --section=pre-data --no-owner --no-acl -f "$src/schema.pgdump"
# shellcheck disable=SC2086
pg_restore $scratch -d "$scratch_db" --no-owner --no-acl "$src/schema.pgdump"

# Unlogged tables load faster, and nothing here has to survive a crash.
# shellcheck disable=SC2086
psql $scratch -d "$scratch_db" -X -q -tA -c "SELECT format('ALTER TABLE public.%I SET UNLOGGED;', table_name)
  FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" |
  psql $scratch -d "$scratch_db" -X -q -v ON_ERROR_STOP=1

table_args=""
for table in $tables; do
  table_args="$table_args -t public.$table"
done

# shellcheck disable=SC2086
echo "Copying the data of $(echo $tables | wc -w | tr -d ' ') tables..."
# shellcheck disable=SC2086
pg_dump -h "$source_host" -Fd -j "$jobs" --section=data --no-owner --no-acl $table_args -f "$src/data"
# shellcheck disable=SC2086
pg_restore $scratch -d "$scratch_db" -j "$jobs" --no-owner --no-acl "$src/data"
rm -rf "$src"

echo "Building the public tables..."
# shellcheck disable=SC2086
PGOPTIONS='--client-min-messages=warning' psql $scratch -d "$scratch_db" -X -q -v ON_ERROR_STOP=1 \
  -v image_url_root="$IMAGE_URL_ROOT" -v badge_url_root="$BADGE_URL_ROOT" -v work_mem="$work_mem" \
  -f "$sql_file"

echo "Writing $file..."
# shellcheck disable=SC2086
pg_dump $scratch -d "$scratch_db" -Fc --no-owner --no-acl -f "$out/$file"

size=$(stat -c %s "$out/$file")
sha=$(sha256sum "$out/$file" | cut -c1-64)
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"file":"%s","size":%s,"sha256":"%s","created_at":"%s"}\n' \
  "$file" "$size" "$sha" "$created_at" > "$out/latest.json"

if [ -n "$page_template" ]; then
  echo "Writing index.html..."
  # What a restored dump takes up, and the version it was made with.
  # shellcheck disable=SC2086
  database_size=$(psql $scratch -d "$scratch_db" -X -q -tA -c "select pg_database_size(current_database())")
  # shellcheck disable=SC2086
  postgres_version=$(psql $scratch -d "$scratch_db" -X -q -tA -c "select current_setting('server_version_num')::int / 10000")
  render_page
fi

echo "Done: $file ($size bytes, sha256 $sha)"
